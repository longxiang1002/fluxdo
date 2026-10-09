import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inappwebview;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../constants.dart';
import '../../preloaded_data_service.dart';
import '../doh_proxy/cert_preference_service.dart';
import '../doh_proxy/doh_proxy_ffi.dart';
import '../doh_proxy/doh_proxy_service.dart';
import '../doh_proxy/per_device_cert_service.dart';
import '../doh_proxy/proxy_certificate.dart';
import '../doh_proxy/windows_cert_trust_service.dart';
import '../proxy/gateway_upstream.dart';
import '../proxy/proxy_settings_service.dart';
import '../rhttp/rhttp_settings_service.dart';
import '../system_proxy_service.dart';
import '../webview/webview_adapter_settings_service.dart';
import '../../windows_webview_environment_service.dart';
import 'doh_resolver.dart';
import 'doh_route_diagnostics.dart';
import 'webview_mitm_policy.dart';

class NetworkSettings {
  const NetworkSettings({
    required this.dohEnabled,
    required this.selectedServerUrl,
    this.echServerUrl,
    required this.customServers,
    required this.proxyPort,
    this.preferIPv6 = false,
    this.serverIp,
    this.gatewayEnabled = true,
    this.h2Mitm = false,
  });

  final bool dohEnabled;

  /// DNS 解析服务器（A/AAAA 查询）
  final String selectedServerUrl;

  /// ECH 配置服务器（HTTPS 记录查询），null = 与 DNS 相同
  final String? echServerUrl;
  final List<DohServer> customServers;

  /// 代理端口（Rust 代理统一处理 DOH + ECH）
  final int? proxyPort;

  /// 优先使用 IPv6
  final bool preferIPv6;

  /// 全局 server IP（指定后跳过 DNS 解析直接连接）
  final String? serverIp;

  /// Gateway（反向代理）模式开关，关闭时回退为 MITM
  final bool gatewayEnabled;

  /// WebView MITM 是否启用 HTTP/2 多路复用（实验性，默认关闭；需实测 CF 指纹）
  final bool h2Mitm;

  NetworkSettings copyWith({
    bool? dohEnabled,
    String? selectedServerUrl,
    String? Function()? echServerUrl,
    List<DohServer>? customServers,
    int? proxyPort,
    bool? preferIPv6,
    String? Function()? serverIp,
    bool? gatewayEnabled,
    bool? h2Mitm,
  }) {
    return NetworkSettings(
      dohEnabled: dohEnabled ?? this.dohEnabled,
      selectedServerUrl: selectedServerUrl ?? this.selectedServerUrl,
      echServerUrl: echServerUrl != null ? echServerUrl() : this.echServerUrl,
      customServers: customServers ?? this.customServers,
      proxyPort: proxyPort ?? this.proxyPort,
      preferIPv6: preferIPv6 ?? this.preferIPv6,
      gatewayEnabled: gatewayEnabled ?? this.gatewayEnabled,
      serverIp: serverIp != null ? serverIp() : this.serverIp,
      h2Mitm: h2Mitm ?? this.h2Mitm,
    );
  }
}

class DohServer {
  const DohServer({
    required this.name,
    required this.url,
    this.bootstrapIps = const [],
    this.isCustom = false,
  });

  final String name;
  final String url;

  /// Bootstrap IP 地址列表，用于直接连接 DOH 服务器（解决鸡蛋问题）
  /// Chrome 也是这样做的：预置 DOH 服务器的 IP，直接用 IP 连接
  final List<String> bootstrapIps;
  final bool isCustom;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    if (bootstrapIps.isNotEmpty) 'bootstrapIps': bootstrapIps,
  };

  static DohServer fromJson(Map<String, dynamic> json) {
    final ips = json['bootstrapIps'];
    return DohServer(
      name: json['name']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      bootstrapIps: ips is List ? ips.cast<String>() : const [],
      isCustom: true,
    );
  }
}

class ResolvedHostConfig {
  const ResolvedHostConfig({
    required this.dnsOverrides,
    this.preferredIp,
    this.echConfig,
  });

  const ResolvedHostConfig.empty()
    : dnsOverrides = const [],
      preferredIp = null,
      echConfig = null;

  final List<String> dnsOverrides;
  final String? preferredIp;
  final Uint8List? echConfig;
}

class _ResolvedHostEntry {
  _ResolvedHostEntry({
    required this.ips,
    required this.preferredIp,
    required this.echConfig,
    required this.ttl,
    required this.resolvedAt,
  }) : expiresAt = resolvedAt.add(ttl);

  final List<String> ips;
  final String? preferredIp;
  final Uint8List? echConfig;
  final Duration ttl;
  final DateTime resolvedAt;
  final DateTime expiresAt;

  bool get hasData => ips.isNotEmpty || (echConfig?.isNotEmpty ?? false);
  bool get isExpired => !expiresAt.isAfter(DateTime.now());

  Duration get remaining {
    final value = expiresAt.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  Duration get refreshLeadTime {
    final byRatio = Duration(milliseconds: (ttl.inMilliseconds / 5).round());
    if (byRatio < _minDnsRefreshLeadTime) {
      return _minDnsRefreshLeadTime;
    }
    if (byRatio > _maxDnsRefreshLeadTime) {
      return _maxDnsRefreshLeadTime;
    }
    return byRatio;
  }

  bool get shouldRefreshSoon => remaining <= refreshLeadTime;
}

const Duration _defaultDnsCacheTtl = Duration(minutes: 5);
const Duration _missDnsCacheTtl = Duration(minutes: 1);
const Duration _minDnsRefreshLeadTime = Duration(seconds: 30);
const Duration _maxDnsRefreshLeadTime = Duration(minutes: 2);
const Duration _failedHostIpPenaltyTtl = Duration(minutes: 2);

class NetworkSettingsService {
  NetworkSettingsService._internal() {
    _proxyService.notifier.addListener(_handleProxySettingsChanged);
    RhttpSettingsService.instance.notifier.addListener(
      _handleRhttpSettingsChanged,
    );
    WebViewAdapterSettingsService.instance.notifier.addListener(
      _handleWebViewAdapterSettingsChanged,
    );
    SystemProxyService.instance.version.addListener(_handleSystemProxyChanged);
  }

  static final NetworkSettingsService instance =
      NetworkSettingsService._internal();

  static const _dohEnabledKey = 'doh_enabled';
  static const _dohSelectedKey = 'doh_selected';
  static const _dohCustomKey = 'doh_custom';
  static const _proxyPortKey = 'doh_proxy_port';
  static const _preferIPv6Key = 'doh_prefer_ipv6';
  static const _serverIpKey = 'doh_server_ip';
  static const _echServerKey = 'doh_ech_server';
  static const _gatewayEnabledKey = 'doh_gateway_enabled';
  static const _h2MitmKey = 'doh_h2_mitm';

  final ValueNotifier<NetworkSettings> notifier = ValueNotifier(
    NetworkSettings(
      dohEnabled: false,
      selectedServerUrl: _defaultServers.first.url,
      customServers: const [],
      proxyPort: null,
    ),
  );

  /// Rust 代理服务（处理 DOH + ECH）
  final DohProxyService _rustProxyService = DohProxyService.instance;
  final ProxySettingsService _proxyService = ProxySettingsService.instance;
  final ValueNotifier<DohDnsCacheStats> dnsCacheStatsNotifier = ValueNotifier(
    const DohDnsCacheStats.empty(),
  );

  late DohResolver _resolver;
  SharedPreferences? _prefs;
  int _version = 0;
  int _applyDepth = 0;
  Timer? _applyDebounce;
  bool _lastStartFailed = false;
  bool _wasRunningBeforeApply = false;
  bool _pendingStart = false;
  final Map<String, _ResolvedHostEntry> _resolvedHostCache = {};
  final Map<String, Future<_ResolvedHostEntry?>> _hostLookupInflight = {};
  final Set<String> _backgroundRefreshingHosts = <String>{};
  final Map<String, Map<String, DateTime>> _hostIpPenaltyCache = {};
  String? _resolvedHostCacheSignature;

  final ValueNotifier<bool> isApplying = ValueNotifier(false);

  /// iOS < 17 上 `_applyWebViewProxy()` 是否**未被短路**（真的尝试过接管）。
  ///
  /// 与 [_webViewProxySet] 的区别：后者只有在调用成功后才是 true，而 iOS 14
  /// 上原生 MethodChannel 根本没注册（`MissingPluginException`），于是
  /// 「能力不支持」和「调用失败」在 `webViewProxyApplied == false` 里混成同一
  /// 个值。真机排查时无法区分「本来就不支持」和「支持但报错了」。
  /// 这里把「是否真的发起过调用」单独暴露，让诊断页能给出确定结论。
  bool _webViewProxyAttempted = false;

  /// iOS < 17 上 `_applyWebViewProxy()` 捕获到的具体失败原因（无异常原文以外的
  /// 用户数据；只保留类型名与是否为 MissingPluginException）。
  String? _lastWebViewProxyError;
  bool _lastWebViewProxyErrorWasMissingPlugin = false;

  int get version => _version;
  DohResolver get resolver => _resolver;
  bool get lastStartFailed => _lastStartFailed;
  bool get wasRunningBeforeApply => _wasRunningBeforeApply;
  bool get pendingStart => _pendingStart;
  int get dnsCacheEntryCount => dnsCacheStatsNotifier.value.visibleHostEntries;

  /// 仅报告代理设置实际完成，不把 DoH 偏好等同于 WebView 已接管。
  bool get webViewProxyApplied =>
      _webViewProxySet && _rustProxyService.isRunning && !_lastStartFailed;

  /// 是否真的对系统 WebView 发起过代理接管调用（而非被版本 guard 短路）。
  bool get webViewProxyAttempted => _webViewProxyAttempted;

  /// 最近一次 WebView 代理接管失败的原因摘要，成功或未尝试时为 null。
  String? get lastWebViewProxyError => _lastWebViewProxyError;

  /// 上述失败是否为 `MissingPluginException`（= 原生侧未注册，属能力缺失）。
  bool get lastWebViewProxyErrorWasMissingPlugin =>
      _lastWebViewProxyErrorWasMissingPlugin;

  /// 内部浏览器出口状态的一句话结论（用于诊断页与日志）。
  ///
  /// 取值刻意区分四态，避免把「未接管」误读成「已接管但没生效」：
  /// - `unsupported`  → 当前系统版本无接管 API（iOS < 17 / macOS < 14）
  /// - `not-running`  → 本地代理未运行或启动失败，无需/无法接管
  /// - `attempting`   → 已发起接管调用，但尚无成功/失败结论
  /// - `failed`       → 发起过调用但抛异常（含 MissingPluginException）
  /// - `applied`      → 接管调用成功
  String get webViewProxyState {
    if ((Platform.isIOS || Platform.isMacOS) &&
        !_supportsProxyOverrideForPlatform) {
      return 'unsupported';
    }
    if (_webViewProxySet && _rustProxyService.isRunning && !_lastStartFailed) {
      return 'applied';
    }
    if (_lastWebViewProxyError != null) {
      return 'failed';
    }
    if (_webViewProxyAttempted) {
      return 'attempting';
    }
    return 'not-running';
  }

  /// 获取代理服务（优先使用 Rust 代理）
  DohProxyService get proxyService => _rustProxyService;

  NetworkSettings get current => notifier.value;

  /// 当前是否使用 gateway（反向代理）模式
  /// Gateway 模式：DOH 开启 + 用户开关开启 + 代理运行中
  bool get isGatewayMode =>
      current.dohEnabled &&
      current.gatewayEnabled &&
      _rustProxyService.isRunning;

  String? get _effectiveEchServerUrl => current.dohEnabled
      ? (current.echServerUrl ?? current.selectedServerUrl)
      : null;

  // Rust 代理供 API 使用；WebView 能否接入还取决于系统代理 API（iOS17+）。
  // rhttp 只改变 Dio 用哪个适配器，不改变代理生命周期
  bool get shouldRunLocalProxy =>
      current.dohEnabled || _proxyService.current.isValid;

  List<DohServer> get servers => [
    ..._defaultServers,
    ...notifier.value.customServers,
  ];

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    final dohEnabled = prefs.getBool(_dohEnabledKey) ?? false;
    final selected =
        prefs.getString(_dohSelectedKey) ?? _defaultServers.first.url;
    final customRaw = prefs.getString(_dohCustomKey);
    final custom = _decodeServers(customRaw);
    final proxyPort = prefs.getInt(_proxyPortKey);
    await prefs.remove('doh_multi_ip');
    final preferIPv6 = prefs.getBool(_preferIPv6Key) ?? false;
    final serverIp = prefs.getString(_serverIpKey);
    final echServer = prefs.getString(_echServerKey);
    final gatewayEnabled = prefs.getBool(_gatewayEnabledKey) ?? true;
    final h2Mitm = prefs.getBool(_h2MitmKey) ?? false;
    final resolvedSelected = _resolveSelected(selected, custom);
    notifier.value = NetworkSettings(
      dohEnabled: dohEnabled,
      selectedServerUrl: resolvedSelected,
      echServerUrl: echServer,
      customServers: custom,
      proxyPort: proxyPort,
      preferIPv6: preferIPv6,
      serverIp: serverIp,
      gatewayEnabled: gatewayEnabled,
      h2Mitm: h2Mitm,
    );
    _resolver = DohResolver(
      serverUrl: notifier.value.selectedServerUrl,
      bootstrapIps: _getBootstrapIps(notifier.value.selectedServerUrl),
      preferIPv6: preferIPv6,
    );
    await _applyProxyState();
    await refreshDnsCacheStats();
    _touch();
  }

  Future<void> setDohEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    _beginApply(enabled: enabled || _proxyService.current.isValid);
    notifier.value = notifier.value.copyWith(dohEnabled: enabled);
    if (!enabled) {
      _clearResolvedHostCache();
    }
    if (!enabled && _lastStartFailed) {
      _setStartFailed(false);
    }
    await prefs.setBool(_dohEnabledKey, enabled);
    await _applyProxyState();
    _touch();
  }

  Future<void> setSelectedServer(String url) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(selectedServerUrl: url);
    _resolver.updateServer(url, bootstrapIps: _getBootstrapIps(url));
    if (current.dohEnabled) {
      _clearResolvedHostCache();
    }
    await prefs.setString(_dohSelectedKey, url);
    _scheduleApplyProxyState();
    _touch(); // 在代理状态更新完成后触发
  }

  Future<void> addCustomServer(DohServer server) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = [...notifier.value.customServers, server];
    notifier.value = notifier.value.copyWith(customServers: updated);
    await prefs.setString(
      _dohCustomKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    _touch();
  }

  Future<void> updateCustomServer(
    DohServer oldServer,
    DohServer newServer,
  ) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = notifier.value.customServers
        .map((s) => s.url == oldServer.url ? newServer : s)
        .toList();
    final selectedUrl = notifier.value.selectedServerUrl;
    final newSelected = selectedUrl == oldServer.url
        ? newServer.url
        : selectedUrl;
    notifier.value = notifier.value.copyWith(
      customServers: updated,
      selectedServerUrl: newSelected,
    );
    if (newSelected != selectedUrl) {
      _resolver.updateServer(
        newSelected,
        bootstrapIps: _getBootstrapIps(newSelected),
      );
      _clearResolvedHostCache();
      _scheduleApplyProxyState();
    }
    await prefs.setString(
      _dohCustomKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    if (newSelected != selectedUrl) {
      await prefs.setString(_dohSelectedKey, newSelected);
    }
    _touch();
  }

  Future<void> removeCustomServer(DohServer server) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = notifier.value.customServers
        .where((s) => s.url != server.url)
        .toList();
    final resolvedSelected = _resolveSelected(
      notifier.value.selectedServerUrl,
      updated,
    );
    notifier.value = notifier.value.copyWith(
      customServers: updated,
      selectedServerUrl: resolvedSelected,
    );
    _resolver.updateServer(
      resolvedSelected,
      bootstrapIps: _getBootstrapIps(resolvedSelected),
    );
    _clearResolvedHostCache();
    await prefs.setString(
      _dohCustomKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    _touch();
  }

  Future<void> resetDefaultServers() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final resolvedSelected = _resolveSelected(
      notifier.value.selectedServerUrl,
      const [],
    );
    notifier.value = notifier.value.copyWith(
      customServers: const [],
      selectedServerUrl: resolvedSelected,
    );
    _resolver.updateServer(
      resolvedSelected,
      bootstrapIps: _getBootstrapIps(resolvedSelected),
    );
    _clearResolvedHostCache();
    await prefs.setString(_dohCustomKey, jsonEncode([]));
    _touch();
  }

  Future<void> setPreferIPv6(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(preferIPv6: enabled);
    _resolver.preferIPv6 = enabled;
    _clearResolvedHostCache();
    await prefs.setBool(_preferIPv6Key, enabled);
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setServerIp(String? ip) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final trimmed = ip?.trim();
    final value = (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
    notifier.value = notifier.value.copyWith(serverIp: () => value);
    _clearResolvedHostCache();
    if (value != null) {
      await prefs.setString(_serverIpKey, value);
    } else {
      await prefs.remove(_serverIpKey);
    }
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setEchServer(String? url) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(echServerUrl: () => url);
    _clearResolvedHostCache();
    if (url != null) {
      await prefs.setString(_echServerKey, url);
    } else {
      await prefs.remove(_echServerKey);
    }
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setGatewayEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(gatewayEnabled: enabled);
    await prefs.setBool(_gatewayEnabledKey, enabled);
    _scheduleApplyProxyState();
    _touch();
  }

  /// 切换 WebView h2 MITM（实验性）。切换后重启代理生效，需实测 CF 指纹。
  Future<void> setH2Mitm(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(h2Mitm: enabled);
    await prefs.setBool(_h2MitmKey, enabled);
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> _applyProxyState() async {
    final startedAt = DateTime.now();
    _applyDepth++;
    if (_applyDepth == 1) {
      if (!isApplying.value) {
        _wasRunningBeforeApply = _rustProxyService.isRunning;
        isApplying.value = true;
      }
      // 给 UI 一帧时间渲染 Loading
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (!shouldRunLocalProxy) {
      try {
        await _stopLocalProxyUnlessRequiredByWebView();
        if (_pendingStart) {
          _setPendingStart(false);
        }
        final prefs = _prefs;
        if (current.proxyPort != null) {
          notifier.value = notifier.value.copyWith(proxyPort: null);
          if (prefs != null) {
            await prefs.remove(_proxyPortKey);
          }
          _touch();
        }
        if (_lastStartFailed) {
          _setStartFailed(false);
        }
      } finally {
        _applyDepth--;
        if (_applyDepth == 0) {
          final elapsed = DateTime.now().difference(startedAt);
          const minDuration = Duration(milliseconds: 400);
          if (elapsed < minDuration) {
            await Future<void>.delayed(minDuration - elapsed);
          }
          isApplying.value = false;
          await refreshDnsCacheStats();
        }
      }
      return;
    }

    try {
      final webViewAdapterEnabled =
          WebViewAdapterSettingsService.instance.enabled;
      final requiresWindowsCa = WebViewMitmPolicy.requiresTrustedCa(
        isWindows: Platform.isWindows,
        dohEnabled: current.dohEnabled,
        webViewAdapterEnabled: webViewAdapterEnabled,
      );
      // 历史配置可能绕过 UI 留下「WebView + DoH 但 CA 未安装」状态。
      // 不再静默篡改 DoH 偏好；只阻止 MITM 启动，避免证书失败重试风暴。
      if (requiresWindowsCa &&
          !await WindowsCertTrustService.instance.isInstalled()) {
        debugPrint('[DOH] Windows WebView MITM 缺少受信任 CA，跳过代理启动');
        _setStartFailed(true);
        _setPendingStart(false);
        await _clearWebViewProxy();
        return;
      }

      final upstream = GatewayUpstream.resolve(
        applicationProxy: _proxyService.current,
        systemProxyUrl: _systemProxyUrlForGateway(),
      );
      final effectiveEchServer = _effectiveEchServerUrl;
      final mitmConnect = WebViewMitmPolicy.useMitmConnect(
        isWindows: Platform.isWindows,
        webViewAdapterEnabled: webViewAdapterEnabled,
      );

      // ECH 场景：rhttp 按请求 host 查询 ECH；gateway 模式仅作为 WebView 后备。
      // Windows 高性能模式不使用 CA，公开 doh_proxy 的非 gateway CONNECT
      // 路径无法表达 mitm_connect=false；此时复用 gateway 的纯隧道分支，
      // 保持端到端 TLS，同时不改变 WebView MITM 模式的既有开关语义。
      final shouldTryEch = effectiveEchServer != null;
      final useGateway = WebViewMitmPolicy.useGatewayMode(
        isWindows: Platform.isWindows,
        dohEnabled: current.dohEnabled,
        gatewayEnabled: current.gatewayEnabled,
        webViewAdapterEnabled: webViewAdapterEnabled,
      );

      if (!shouldTryEch) {
        _clearResolvedHostCache();
      }

      // macOS: 启动前确保 CA 在钥匙串中被信任
      if (Platform.isMacOS && current.dohEnabled) {
        final trusted = await ProxyCertificate.ensureKeychainTrust();
        if (!trusted) {
          debugPrint('[DOH] macOS: CA 未被钥匙串信任，无法启动代理');
          _setStartFailed(true);
          _setPendingStart(false);
          return;
        }
      }

      // per-device CA: 读取证书传给代理（iOS/macOS 强制，其他平台可选）
      String? caCertPem;
      String? caKeyPem;
      if (mitmConnect && await CertPreferenceService.usePerDevice()) {
        final certService = PerDeviceCertService.instance;
        if (certService.isLoaded || await certService.ensureCaCert()) {
          caCertPem = certService.certPem;
          caKeyPem = certService.keyPem;
        }
      }

      // Rust 代理始终为 WebView 提供 DOH/代理支持，enableDoh 不受 rhttp 影响
      final success = await _rustProxyService.start(
        preferredPort:
            WindowsWebViewEnvironmentService.instance.activeLocalProxyPort ??
            _activeProxyPort ??
            current.proxyPort ??
            0,
        enableDoh: current.dohEnabled,
        gatewayMode: useGateway,
        preferIPv6: current.preferIPv6,
        dohServer: current.dohEnabled ? current.selectedServerUrl : null,
        dohServerEch: current.dohEnabled ? current.echServerUrl : null,
        serverIp: current.serverIp,
        upstreamProtocol: upstream?.protocol,
        upstreamHost: upstream?.host,
        upstreamPort: upstream?.port,
        upstreamUsername: upstream?.username,
        upstreamPassword: upstream?.password,
        upstreamCipher: upstream?.cipher,
        caCertPem: caCertPem,
        caKeyPem: caKeyPem,
        mitmConnect: mitmConnect,
        h2Mitm: current.h2Mitm,
      );

      if (!success) {
        debugPrint('[DOH] Failed to start Rust proxy');
        _setStartFailed(true);
        _setPendingStart(false);
        await _clearWebViewProxy();
        return;
      }

      // start 耗时较长(读证书/绑端口),期间设置可能已被改为无需本地代理
      // (如 VPN 自动压制关闭了 DoH 与上游代理)。此时并发的 stop 分支先于
      // start 完成,会留下"开关已关、代理仍在跑"的孤儿网关,这里必须复查。
      if (!shouldRunLocalProxy) {
        debugPrint('[DOH] 启动期间设置已变更为无需本地代理,重新核对 WebView 路由');
        await _stopLocalProxyUnlessRequiredByWebView();
        _setPendingStart(false);
        return;
      }

      if (_lastStartFailed) {
        _setStartFailed(false);
      }
      if (_pendingStart) {
        _setPendingStart(false);
      }

      // 获取实际使用的端口（Rust 代理）
      final activePort = _rustProxyService.port;
      if (current.proxyPort != activePort) {
        final prefs = _prefs;
        if (prefs != null && activePort != null) {
          await prefs.setInt(_proxyPortKey, activePort);
          notifier.value = notifier.value.copyWith(proxyPort: activePort);
          _touch(); // 触发 HttpClient 重建
        }
      }

      await _applyWebViewProxy();
    } finally {
      _applyDepth--;
      if (_applyDepth == 0) {
        final elapsed = DateTime.now().difference(startedAt);
        const minDuration = Duration(milliseconds: 400);
        if (elapsed < minDuration) {
          await Future<void>.delayed(minDuration - elapsed);
        }
        isApplying.value = false;
        await refreshDnsCacheStats();
        _touch();
      }
    }
  }

  void _setStartFailed(bool value) {
    if (_lastStartFailed == value) return;
    _lastStartFailed = value;
    _touch();
  }

  void _setPendingStart(bool value) {
    if (_pendingStart == value) return;
    _pendingStart = value;
    _touch();
  }

  Future<void> restartProxy() async {
    _beginApply(enabled: shouldRunLocalProxy);
    await _applyProxyState();
    _touch();
  }

  /// 检查代理是否仍然存活，若已意外停止则自动重启
  ///
  /// 用于 App 从后台恢复时调用：iOS 挂起进程后 Rust 代理的 TCP listener
  /// 可能失效，需要检测并重启。
  Future<void> ensureProxyAlive() async {
    if (!shouldRunLocalProxy) return;
    if (!_rustProxyService.isRunning) return;
    final alive = await _rustProxyService.checkAlive();
    if (!alive) {
      debugPrint('[DOH] 代理已失效，自动重启');
      await restartProxy();
    }
  }

  void _scheduleApplyProxyState() {
    _beginApply(enabled: shouldRunLocalProxy);
    _applyDebounce?.cancel();
    _applyDebounce = Timer(const Duration(milliseconds: 350), () async {
      await _applyProxyState();
      _touch();
    });
  }

  void _beginApply({required bool enabled}) {
    _wasRunningBeforeApply = _rustProxyService.isRunning;
    if (enabled) {
      _setPendingStart(true);
    }
    if (!isApplying.value) {
      isApplying.value = true;
    }
  }

  /// 获取当前活动的代理端口
  int? get _activeProxyPort => _rustProxyService.port;

  bool _webViewProxySet = false;

  Future<void> _stopLocalProxyUnlessRequiredByWebView() async {
    var retainForWindowsWebView = false;
    if (Platform.isWindows) {
      final runningPort = _rustProxyService.port;
      final clearApplied = await _clearWebViewProxy();
      retainForWindowsWebView =
          WindowsWebViewEnvironmentService.shouldRetainLocalProxy(
            clearApplied: clearApplied,
            activeEnvironmentPort:
                WindowsWebViewEnvironmentService.instance.activeLocalProxyPort,
            runningProxyPort: runningPort,
          );
    } else {
      await _clearWebViewProxy();
    }

    if (retainForWindowsWebView) {
      debugPrint('[DOH] WebView2 当前仍使用本地代理，保留端口直到应用重启');
      return;
    }
    await _rustProxyService.stop();
  }

  /// 传给 Rust 网关的「系统代理」上游。
  ///
  /// 背景（iOS 14 内部浏览器 DoH 接管的核心）：
  /// - WKWebView **默认跟随系统代理**（CFNetwork 栈），而本地 DoH 网关
  ///   （`127.0.0.1:<port>`）不在系统代理里。
  /// - iOS 17+ 可用 `WKWebsiteDataStore.proxyConfigurations` 把 WebView 直接
  ///   指向本地网关，两通道出口天然一致；iOS 14 无此 API
  ///   （见 [_applyWebViewProxy] 的能力说明），WebView 只能走系统代理。
  /// - 此时若 DoH 出站**直连**，则「WebView 经系统代理」与「DoH 直连」出口 IP
  ///   不一致 → 验证页铸出的 cf_clearance 绑的是代理节点 IP，对直连请求无效
  ///   → 过盾死循环。
  ///
  /// 因此在 iOS 上同样把系统代理交给网关，使 DoH 出站与 WKWebView 走**同一出口**，
  /// 达到「出口一致」的目标。
  ///
  /// 仅 Windows / iOS 有意义：其余平台 [SystemProxyService.effectiveProxyUrl]
  /// 恒为 null（直连），传入与传 null 等价。
  /// 注：VPN/TUN 模式下系统不写代理，二者都经 TUN，天然一致，此处返回 null。
  String? _systemProxyUrlForGateway() {
    if (!Platform.isWindows && !Platform.isIOS) return null;
    return SystemProxyService.instance.effectiveProxyUrl;
  }

  Future<void> _applyWebViewProxy() async {
    if (!shouldRunLocalProxy) return;
    final port = _activeProxyPort;
    if (port == null) return;

    if (Platform.isWindows) {
      try {
        final applied = await WindowsWebViewEnvironmentService.instance
            .setProxy('http://127.0.0.1:$port');
        _webViewProxySet = true;
        debugPrint(
          applied
              ? '[DOH] WebView2 代理已设置 -> 127.0.0.1:$port'
              : '[DOH] WebView2 代理已登记，重启应用后生效 -> '
                    '127.0.0.1:$port',
        );
      } catch (e) {
        debugPrint('[DOH] WebView2 代理设置失败: $e');
      }
      return;
    }

    if (await _requiresUnsupportedProxySkips()) {
      _recordWebViewProxyUnsupported('iOS/macOS 版本低于接管 API 要求');
      return;
    }

    _webViewProxyAttempted = true;
    try {
      await inappwebview.ProxyController.instance().setProxyOverride(
        settings: inappwebview.ProxySettings(
          proxyRules: [inappwebview.ProxyRule(url: 'http://127.0.0.1:$port')],
        ),
      );
      _webViewProxySet = true;
      _lastWebViewProxyError = null;
      _lastWebViewProxyErrorWasMissingPlugin = false;
      debugPrint('[DOH] WebView 代理已设置 -> 127.0.0.1:$port');
    } on MissingPluginException catch (e) {
      // 原生侧未注册（典型：iOS < 17 无 ProxyManager）——属**能力缺失**，
      // 不是配置问题。单独分类，让真机日志能一句话定性。
      _webViewProxySet = false;
      _lastWebViewProxyError = 'MissingPluginException';
      _lastWebViewProxyErrorWasMissingPlugin = true;
      debugPrint(
        '[DOH] WebView 代理接管不可用：原生 ProxyController 未注册 '
        '(${e.message}) → 内部浏览器流量裸连，不走本地 DoH',
      );
    } catch (e) {
      _webViewProxySet = false;
      _lastWebViewProxyError = e.runtimeType.toString();
      _lastWebViewProxyErrorWasMissingPlugin = false;
      debugPrint('[DOH] WebView 代理设置失败(${e.runtimeType}): $e');
    }
  }

  /// 记录「因平台能力缺失而根本未尝试接管」的状态。
  ///
  /// 与 [webViewProxyAttempted] 配合，使诊断报告能明确区分
  /// 「没尝试（不支持）」和「尝试了但失败」。
  void _recordWebViewProxyUnsupported(String reason) {
    _webViewProxyAttempted = false;
    _webViewProxySet = false;
    _lastWebViewProxyError = null;
    _lastWebViewProxyErrorWasMissingPlugin = false;
    debugPrint('[DOH] WebView 代理接管跳过：$reason');
  }

  /// 当前平台是否**无法**通过 `ProxyController.setProxyOverride` 接管 WebView。
  ///
  /// 这不是「可能报错」的保守判断，而是**能力上的硬缺失**，已源码级核实：
  ///
  /// - iOS < 17：`ProxyManager` 全程标注 `@available(iOS 17.0, *)`，且
  ///   `InAppWebViewFlutterPlugin` 只在 `if #available(iOS 17.0, *)` 分支里
  ///   注册它 → iOS 14 上 `...proxycontroller` MethodChannel **从未注册**，
  ///   Dart 侧 `invokeMethod` 抛 `MissingPluginException`（会被下面的 catch 吞掉）。
  ///   底层依赖 `WKWebsiteDataStore.proxyConfigurations`，该 API iOS 17 才引入。
  /// - macOS < 14：同上，`proxyConfigurations` 为 macOS 14 才可用。
  /// - 其余平台（Android）`setProxyOverride` 走原生 `WebView.setProxyOverride`，
  ///   一直可用。
  ///
  /// 因为此前这里是**静默 return**，真机排查时会误以为「设置成功但没用」。
  /// 现在显式打日志，让日志本身能证明「iOS 14 内部浏览器是裸连、未走 DoH」。
  ///
  /// 注意：iOS 上也没有替代拦截手段 —— `shouldInterceptRequest` 的
  /// `@SupportedPlatforms` 只列 Android/Windows/Linux（iOS 原生实现为 0 处），
  /// `CustomSchemeHandler` 只对自定义 scheme 生效、接管不了 `https://`。
  /// 因此 iOS 14 的 WebView 出口一致性只能走「系统代理」路径（见
  /// `SystemProxyReader` / `SystemProxyService`），不能在本函数里解决。
  Future<bool> _requiresUnsupportedProxySkips() async {
    if (Platform.isAndroid) return false;

    if (Platform.isIOS) {
      if (await _isiOS17OrAbove()) return false;
      debugPrint(
        '[DOH] iOS < 17 无 WKWebsiteDataStore.proxyConfigurations，'
        'WebView 无法接管 → 内部浏览器流量裸连（不走本地 DoH 代理）',
      );
      return true;
    }

    if (Platform.isMacOS) {
      if (await _isMacOS14OrAbove()) return false;
      debugPrint('[DOH] macOS < 14 不支持 proxyConfigurations，WebView 无法接管');
      return true;
    }

    // 其余平台（Windows 已在前面 return，Linux 无该系统代理 API）
    return true;
  }

  /// 同步版本的能力判断（用于 [webViewProxyState] 这类非 async 取值）。
  ///
  /// 只回答「这个**平台 + 系统大版本**是否具备接管 API」，不做任何 IO。
  /// iOS/macOS 的大版本缓存由 [_isiOS17OrAbove] / [_isMacOS14OrAbove] 填充；
  /// 尚未采样到缓存时保守返回 `false`（= 不具备），避免把未知冒充成支持。
  bool get _supportsProxyOverrideForPlatform {
    if (Platform.isAndroid) return true;
    if (Platform.isIOS) return _isiOS17OrAboveCache ?? false;
    if (Platform.isMacOS) return _isMacOS14OrAboveCache ?? false;
    return false;
  }

  Future<bool> _clearWebViewProxy() async {
    if (Platform.isWindows) {
      try {
        final applied = await WindowsWebViewEnvironmentService.instance
            .setProxy(null);
        _webViewProxySet = false;
        _webViewProxyAttempted = false;
        _lastWebViewProxyError = null;
        _lastWebViewProxyErrorWasMissingPlugin = false;
        debugPrint(
          applied ? '[DOH] WebView2 代理已清除' : '[DOH] WebView2 代理清除已登记，重启应用后生效',
        );
        return applied;
      } catch (e) {
        debugPrint('[DOH] WebView2 代理清除失败: $e');
        return false;
      }
    }

    if (!_webViewProxySet && !_webViewProxyAttempted) return true;

    // 与 _applyWebViewProxy 同一能力判断：不支持时无需也无法清除。
    if (await _requiresUnsupportedProxySkips()) {
      _webViewProxyAttempted = false;
      _lastWebViewProxyError = null;
      _lastWebViewProxyErrorWasMissingPlugin = false;
      return true;
    }
    try {
      await inappwebview.ProxyController.instance().clearProxyOverride();
      _webViewProxySet = false;
      _webViewProxyAttempted = false;
      _lastWebViewProxyError = null;
      _lastWebViewProxyErrorWasMissingPlugin = false;
      debugPrint('[DOH] WebView 代理已清除');
      return true;
    } catch (e) {
      debugPrint('[DOH] WebView 代理清除失败: $e');
      return false;
    }
  }

  static bool? _isMacOS14OrAboveCache;

  Future<bool> _isMacOS14OrAbove() async {
    if (!Platform.isMacOS) return false;
    if (_isMacOS14OrAboveCache != null) return _isMacOS14OrAboveCache!;
    final info = await DeviceInfoPlugin().macOsInfo;
    // 修复：majorVersion 对应 macOS 大版本，如 macOS 14 (Sonoma) => majorVersion == 14 ≠ Darwin 23
    _isMacOS14OrAboveCache = info.majorVersion >= 14;
    return _isMacOS14OrAboveCache!;
  }

  static bool? _isiOS17OrAboveCache;

  Future<bool> _isiOS17OrAbove() async {
    if (!Platform.isIOS) return false;
    if (_isiOS17OrAboveCache != null) return _isiOS17OrAboveCache!;
    final info = await DeviceInfoPlugin().iosInfo;
    final major = int.tryParse(info.systemVersion.split('.').first) ?? 0;
    _isiOS17OrAboveCache = major >= 17;
    return _isiOS17OrAboveCache!;
  }

  void _touch() {
    _version++;
    // 通过重新赋值触发监听器更新
    notifier.value = notifier.value.copyWith();
  }

  /// 用一次 **WebView 出口采样** 判定「内部浏览器与 DoH 是否同一出口」。
  ///
  /// 背景：iOS < 17 无法把 WebView 指向本地 DoH 网关（见
  /// [webViewProxyState] == `unsupported`），两通道只能靠「同经系统代理」
  /// 达到出口 IP 一致。出口一致这件事**只能实测**，不能靠设置推断：
  /// `CFNetworkCopySystemProxySettings` 读得到系统设置 ≠ App 进程内出口由它决定
  /// （PAC-only / 进程内另有代理配置时不成立）。
  ///
  /// 判定规则（保守，绝不把「未知」当「成功」）：
  /// - 无采样数据 / 非 iOS → `null`（不冒充成功）
  /// - WebView 已接管到本地网关（iOS 17+ `applied`）→ `true`
  /// - iOS <17（`unsupported`）：WebView 不经本地网关。此时**只有
  ///   [isGatewayMode] 为真（本地 DoH 网关真的在跑）才存在「DoH 出口」这个
  ///   东西可与 WebView 出口比对：
  ///   - 进程内固定代理且与系统设置一致 → `true`（两通道同经该代理）
  ///   - PAC / 直连 / 与系统设置不一致 → `false`
  ///   - 网关没在跑 → `null`：WebView 与 Dart 出口**都**不经 DoH，
  ///     「出口一致」在此毫无意义，`true` 会严重误导（历史误判来源）。
  ///
  /// 结果写回 [DohRouteDiagnostics.setDohEgressVerified]，让逐请求路由记录里的
  /// `dohEgressVerified` 字段能与之对应。仅 iOS 生效，失败不影响导航。
  bool? recordWebViewEgressEvidence(SystemProxyProbe? probe) {
    final bool? verified = _resolveEgressVerified(
      probe,
      isGatewayMode: isGatewayMode,
    );
    DohRouteDiagnostics.instance.setDohEgressVerified(verified);
    debugPrint(
      '[DOH] 内部浏览器出口结论: state=$webViewProxyState '
      'egressVerified=${verified ?? 'unknown'} '
      'gatewayMode=${isGatewayMode ? 'on' : 'off'} '
      'systemProxy=${probe?.systemProxyUrl ?? "none"} '
      'webViewProxyAttempted=$_webViewProxyAttempted',
    );
    return verified;
  }

  /// [recordWebViewEgressEvidence] 的纯判定部分（便于测试与复用）。
  ///
  /// 非 iOS 恒为 `null`：其它平台不依赖系统代理做出口统一，
  /// 采样结论与「内部浏览器是否走 DoH」无关，不得拿来充数。
  static bool? _resolveEgressVerified(
    SystemProxyProbe? probe, {
    required bool isGatewayMode,
  }) {
    if (!Platform.isIOS) return null;
    if (probe == null) return null;
    if (!isGatewayMode) {
      // 本地 DoH 网关未运行：WebView 与 Dart 出口都不经 DoH，
      // 说「一致」是伪结论。留 null，让调用方区分「未知」与「已确证」。
      return null;
    }
    // 网关在跑：WebView 经系统代理、网关出站也跟随系统代理（见
    // `_systemProxyUrlForGateway`）→ 两通道出口同源。前提是进程内
    // 真的是固定代理而非 PAC；PAC / 直连都判不一致。
    return probe.effectiveExitIsSystemProxy;
  }

  void _handleProxySettingsChanged() {
    if (_prefs == null) return;
    _clearResolvedHostCache();
    _scheduleApplyProxyState();
    _touch();
  }

  void _handleWebViewAdapterSettingsChanged() {
    if (_prefs == null || !shouldRunLocalProxy) return;
    _scheduleApplyProxyState();
    _touch();
  }

  void _handleSystemProxyChanged() {
    if (_prefs == null || !Platform.isWindows) return;
    // 应用内代理拥有更高优先级；只有走系统代理回退时才需要重启网关。
    if (_proxyService.current.isValid || !shouldRunLocalProxy) return;
    _scheduleApplyProxyState();
  }

  Future<ResolvedHostConfig> resolveHostForRequest(
    String host, {
    bool forceRefresh = false,
  }) async {
    final normalizedHost = _normalizeHost(host);
    if (normalizedHost == null) {
      return const ResolvedHostConfig.empty();
    }

    final serverIpOverride = _parseServerIpOverride();
    if (!current.dohEnabled) {
      _clearResolvedHostCache();
      return ResolvedHostConfig(
        dnsOverrides: serverIpOverride != null
            ? <String>[serverIpOverride]
            : const [],
        preferredIp: serverIpOverride,
      );
    }

    final entry = await _resolveHostEntry(
      normalizedHost,
      forceRefresh: forceRefresh,
    );
    final orderedIps = _applyHostIpPenalties(
      normalizedHost,
      entry?.ips ?? const [],
      preferredIp: entry?.preferredIp,
    );
    final stickyIp = _selectUsablePreferredIp(
      normalizedHost,
      entry?.preferredIp,
      orderedIps,
    );
    return ResolvedHostConfig(
      dnsOverrides: serverIpOverride != null
          ? <String>[serverIpOverride]
          : stickyIp != null
          ? <String>[stickyIp]
          : orderedIps,
      preferredIp: serverIpOverride ?? stickyIp,
      echConfig: entry?.echConfig,
    );
  }

  void reportHostConnectionFailure(String host, String? ip) {
    final normalizedHost = _normalizeHost(host);
    final normalizedIp = _normalizeSingleIp(ip);
    if (normalizedHost == null || normalizedIp == null) {
      return;
    }

    _evictExpiredHostIpPenalties();
    final penalties = _hostIpPenaltyCache.putIfAbsent(
      normalizedHost,
      () => <String, DateTime>{},
    );
    penalties[normalizedIp] = DateTime.now().add(_failedHostIpPenaltyTtl);
    if (current.dohEnabled) {
      final dohServer = current.selectedServerUrl;
      final dohServerEch = _effectiveEchServerUrl ?? current.selectedServerUrl;
      unawaited(
        _rustProxyService.clearPreferredHostIp(
          normalizedHost,
          dohServer,
          dohServerEch: dohServerEch,
          preferIpv6: current.preferIPv6,
        ),
      );
    }
  }

  void reportHostConnectionSuccess(String host, String? ip) {
    final normalizedHost = _normalizeHost(host);
    final normalizedIp = _normalizeSingleIp(ip);
    if (normalizedHost == null || normalizedIp == null) {
      return;
    }

    final penalties = _hostIpPenaltyCache[normalizedHost];
    if (penalties == null) {
      return;
    }
    penalties.remove(normalizedIp);
    if (penalties.isEmpty) {
      _hostIpPenaltyCache.remove(normalizedHost);
    }

    if (current.dohEnabled) {
      final dohServer = current.selectedServerUrl;
      final dohServerEch = _effectiveEchServerUrl ?? current.selectedServerUrl;
      unawaited(
        _rustProxyService.recordHostSuccess(
          normalizedHost,
          dohServer,
          dohServerEch: dohServerEch,
          preferIpv6: current.preferIPv6,
          ip: normalizedIp,
        ),
      );
    }
  }

  Future<List<String>> getDnsOverridesForHost(String host) async {
    return (await resolveHostForRequest(host)).dnsOverrides;
  }

  Future<Uint8List?> getEchConfigForHost(String host) async {
    return (await resolveHostForRequest(host)).echConfig;
  }

  Future<void> refreshDnsCacheStats() async {
    var stats = const DohDnsCacheStats.empty();
    try {
      stats = await _rustProxyService.dnsCacheStats() ?? stats;
    } catch (e) {
      debugPrint('[DOH] DNS cache stats refresh failed: $e');
    }
    _setDnsCacheStats(stats);
  }

  Future<List<DohDnsCacheRecord>> dnsCacheRecords() async {
    final records = <DohDnsCacheRecord>[];
    try {
      records.addAll(await _rustProxyService.dnsCacheRecords() ?? const []);
    } catch (e) {
      debugPrint('[DOH] DNS cache records load failed: $e');
    }

    final seen = records.map(_dnsCacheRecordKey).toSet();
    for (final item in _resolvedHostCache.entries) {
      final host = item.key;
      final entry = item.value;
      if (entry.isExpired) {
        continue;
      }

      void addLocalRecord(DohDnsCacheRecord record) {
        if (seen.add(_dnsCacheRecordKey(record))) {
          records.add(record);
        }
      }

      if (entry.ips.isNotEmpty) {
        addLocalRecord(
          DohDnsCacheRecord(
            host: host,
            kind: 'ip',
            values: entry.ips,
            ttl: entry.remaining,
          ),
        );
      }
      if (entry.echConfig?.isNotEmpty ?? false) {
        addLocalRecord(
          DohDnsCacheRecord(
            host: host,
            kind: 'ech',
            values: [base64Encode(entry.echConfig!)],
            ttl: entry.remaining,
          ),
        );
      }
      if (entry.preferredIp != null) {
        addLocalRecord(
          DohDnsCacheRecord(
            host: host,
            kind: 'preferred_ip',
            values: [entry.preferredIp!],
            ttl: entry.remaining,
          ),
        );
      }
    }

    records.sort((a, b) {
      final hostOrder = a.host.compareTo(b.host);
      if (hostOrder != 0) {
        return hostOrder;
      }
      return _dnsCacheRecordKindOrder(
        a.kind,
      ).compareTo(_dnsCacheRecordKindOrder(b.kind));
    });
    return records;
  }

  Future<void> clearDnsCache() async {
    _clearResolvedHostCache();
    await _rustProxyService.clearDnsCache();
    await refreshDnsCacheStats();
  }

  Future<int> forceRefreshDnsCache() async {
    final hosts = _collectCommonHosts();
    await clearDnsCache();
    if (!current.dohEnabled || hosts.isEmpty) {
      return 0;
    }

    await Future.wait(
      hosts.map((host) => _resolveHostEntry(host, forceRefresh: true)),
    );
    await refreshDnsCacheStats();
    return hosts.length;
  }

  Future<_ResolvedHostEntry?> _resolveHostEntry(
    String host, {
    bool forceRefresh = false,
  }) {
    _ensureResolvedHostCacheSignature();

    if (!forceRefresh) {
      final cached = _resolvedHostCache[host];
      if (cached != null) {
        if (!cached.isExpired) {
          if (cached.shouldRefreshSoon) {
            _refreshHostInBackground(host);
          }
          return Future.value(cached);
        }
        _resolvedHostCache.remove(host);
        _updateLocalDnsCacheStats();
        unawaited(refreshDnsCacheStats());
      }
    } else {
      if (_resolvedHostCache.remove(host) != null) {
        _updateLocalDnsCacheStats();
        unawaited(refreshDnsCacheStats());
      }
    }

    final inflight = _hostLookupInflight[host];
    if (inflight != null) {
      return inflight;
    }

    final future = _loadHostEntry(host, forceRefresh: forceRefresh);
    _hostLookupInflight[host] = future;
    return future.whenComplete(() {
      if (identical(_hostLookupInflight[host], future)) {
        _hostLookupInflight.remove(host);
      }
    });
  }

  Future<_ResolvedHostEntry?> _loadHostEntry(
    String host, {
    required bool forceRefresh,
  }) async {
    final dohServer = current.selectedServerUrl;
    final dohServerEch = _effectiveEchServerUrl ?? current.selectedServerUrl;
    final resolvedAt = DateTime.now();

    final rustResult = await _rustProxyService.lookupHost(
      host,
      dohServer,
      dohServerEch: dohServerEch,
      preferIpv6: current.preferIPv6,
      forceRefresh: forceRefresh,
    );
    if (rustResult != null && rustResult.hasData) {
      final entry = _ResolvedHostEntry(
        ips: _normalizeIpList(rustResult.ips),
        preferredIp: _normalizeSingleIp(rustResult.preferredIp),
        echConfig: rustResult.echConfig,
        ttl: _clampDnsTtl(rustResult.ttl),
        resolvedAt: resolvedAt,
      );
      _resolvedHostCache[host] = entry;
      _updateLocalDnsCacheStats();
      unawaited(refreshDnsCacheStats());
      debugPrint(
        '[DOH] Host 已解析 $host '
        '(DNS: ${entry.preferredIp ?? (entry.ips.isEmpty ? "none" : entry.ips.join(", "))}, '
        'ECH: ${entry.echConfig == null ? "off" : "on"}, '
        'TTL: ${entry.ttl.inSeconds}s)',
      );
      return entry;
    }

    final fallbackResults = await Future.wait<dynamic>([
      _lookupIpViaRust(host, dohServer, current.preferIPv6),
      _rustProxyService.lookupEchConfig(host, dohServerEch),
    ]);

    var ips = fallbackResults[0] as List<String>;
    final echConfig = fallbackResults[1] as Uint8List?;

    if (ips.isEmpty) {
      final fallback = await resolver.resolveAll(host);
      ips = _normalizeIpList(fallback.map((address) => address.address));
      if (ips.isNotEmpty) {
        debugPrint('[DOH] Dart IP 已解析 $host -> ${ips.join(', ')}');
      }
    }

    final hasData = ips.isNotEmpty || (echConfig?.isNotEmpty ?? false);
    // fallback 路径同样不要在真正连通前提前 pin 单 IP。
    // 让 rhttp 先拿完整候选集，避免把错误/不稳定边缘节点缓存成 sticky。
    final preferredIp = null;
    final entry = _ResolvedHostEntry(
      ips: ips,
      preferredIp: preferredIp,
      echConfig: echConfig != null && echConfig.isEmpty ? null : echConfig,
      ttl: hasData ? _defaultDnsCacheTtl : _missDnsCacheTtl,
      resolvedAt: resolvedAt,
    );
    _resolvedHostCache[host] = entry;
    _updateLocalDnsCacheStats();
    unawaited(refreshDnsCacheStats());

    if (!hasData) {
      debugPrint('[DOH] Host 解析失败或为空: $host');
    }
    return entry;
  }

  void _ensureResolvedHostCacheSignature() {
    final signature = _currentResolvedHostCacheSignature;
    if (_resolvedHostCacheSignature == signature) {
      return;
    }
    _clearResolvedHostCache();
    _resolvedHostCacheSignature = signature;
  }

  void _refreshHostInBackground(String host) {
    if (!_backgroundRefreshingHosts.add(host)) {
      return;
    }
    unawaited(
      _resolveHostEntry(host, forceRefresh: true).whenComplete(() {
        _backgroundRefreshingHosts.remove(host);
      }),
    );
  }

  void _setDnsCacheStats(DohDnsCacheStats stats) {
    dnsCacheStatsNotifier.value = stats.copyWith(
      dartEntryCount: _resolvedHostCache.length,
    );
  }

  void _updateLocalDnsCacheStats() {
    _setDnsCacheStats(dnsCacheStatsNotifier.value);
  }

  String _dnsCacheRecordKey(DohDnsCacheRecord record) =>
      '${record.host}|${record.kind}';

  int _dnsCacheRecordKindOrder(String kind) {
    switch (kind) {
      case 'ip':
        return 0;
      case 'ech':
        return 1;
      case 'ech_negative':
        return 2;
      case 'preferred_ip':
        return 3;
      default:
        return 4;
    }
  }

  void _clearResolvedHostCache({bool touch = false}) {
    final changed =
        _resolvedHostCache.isNotEmpty ||
        _hostLookupInflight.isNotEmpty ||
        _backgroundRefreshingHosts.isNotEmpty ||
        _hostIpPenaltyCache.isNotEmpty ||
        _resolvedHostCacheSignature != null;
    _resolvedHostCache.clear();
    _hostLookupInflight.clear();
    _backgroundRefreshingHosts.clear();
    _hostIpPenaltyCache.clear();
    _resolvedHostCacheSignature = null;
    if (changed) {
      _updateLocalDnsCacheStats();
    }
    if (touch && changed) {
      _touch();
    }
  }

  void _handleRhttpSettingsChanged() {
    if (_prefs == null) return;
    _scheduleApplyProxyState();
    _touch();
  }

  String _resolveSelected(String selected, List<DohServer> customServers) {
    final allServers = [..._defaultServers, ...customServers];
    final found = allServers.any((s) => s.url == selected);
    return found ? selected : _defaultServers.first.url;
  }

  /// 根据 URL 查找服务器配置
  DohServer? _findServer(String url) {
    final allServers = [..._defaultServers, ...notifier.value.customServers];
    for (final server in allServers) {
      if (server.url == url) return server;
    }
    return null;
  }

  /// 获取选中服务器的 Bootstrap IP
  List<String> _getBootstrapIps(String url) {
    return _findServer(url)?.bootstrapIps ?? [];
  }

  String? _normalizeHost(String host) {
    final normalizedHost = host.trim().toLowerCase();
    if (normalizedHost.isEmpty ||
        InternetAddress.tryParse(normalizedHost) != null) {
      return null;
    }
    return normalizedHost;
  }

  String? _parseServerIpOverride() {
    final serverIp = current.serverIp?.trim();
    if (serverIp == null || serverIp.isEmpty) {
      return null;
    }
    return InternetAddress.tryParse(serverIp)?.address;
  }

  Duration _clampDnsTtl(Duration ttl) {
    if (ttl <= Duration.zero) {
      return _defaultDnsCacheTtl;
    }
    if (ttl < _missDnsCacheTtl) {
      return _missDnsCacheTtl;
    }
    if (ttl > const Duration(minutes: 30)) {
      return const Duration(minutes: 30);
    }
    return ttl;
  }

  String? get _currentResolvedHostCacheSignature => current.dohEnabled
      ? '${current.selectedServerUrl}|${_effectiveEchServerUrl ?? ""}|${current.preferIPv6 ? "v6" : "v4"}'
      : null;

  List<String> _collectCommonHosts() {
    final preloaded = PreloadedDataService();
    final hosts = <String>{
      'connect.linux.do',
      'ping.linux.do',
      'cdn.linux.do',
      'credit.linux.do',
      'cdk.linux.do',
    };

    for (final value in [
      AppConstants.baseUrl,
      preloaded.longPollingBaseUrl,
      preloaded.cdnUrl,
      preloaded.s3CdnUrl,
      preloaded.s3BaseUrl,
    ]) {
      final host = _extractHost(value);
      if (host != null) {
        hosts.add(host);
      }
    }

    final result = hosts.toList()..sort();
    return result;
  }

  String? _extractHost(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final normalized = raw.startsWith('//') ? 'https:$raw' : raw;
    final host = Uri.tryParse(normalized)?.host.trim().toLowerCase();
    if (host == null || host.isEmpty) {
      return null;
    }
    return host;
  }

  Future<List<String>> _lookupIpViaRust(
    String host,
    String dohServer,
    bool preferIpv6,
  ) async {
    final result = await _rustProxyService.lookupIp(
      host,
      dohServer,
      preferIpv6: preferIpv6,
    );
    return _normalizeIpList(result);
  }

  List<String> _normalizeIpList(Iterable<String> raw) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final value in raw) {
      final ip = InternetAddress.tryParse(value.trim())?.address;
      if (ip == null || !seen.add(ip)) {
        continue;
      }
      normalized.add(ip);
    }
    return normalized;
  }

  String? _normalizeSingleIp(String? raw) {
    if (raw == null) {
      return null;
    }
    return InternetAddress.tryParse(raw.trim())?.address;
  }

  List<String> _applyHostIpPenalties(
    String host,
    List<String> ips, {
    String? preferredIp,
  }) {
    if (ips.isEmpty) {
      return const [];
    }

    _evictExpiredHostIpPenalties();
    final penalties = _hostIpPenaltyCache[host];
    if (penalties == null || penalties.isEmpty) {
      return ips;
    }

    final preferred = _normalizeSingleIp(preferredIp);
    final available = <String>[];
    final penalized = <String>[];

    for (final ip in ips) {
      if (_isHostIpPenalized(host, ip)) {
        penalized.add(ip);
      } else {
        available.add(ip);
      }
    }

    if (preferred != null && available.remove(preferred)) {
      available.insert(0, preferred);
    }

    if (available.isNotEmpty) {
      return <String>[...available, ...penalized];
    }
    return penalized;
  }

  String? _selectUsablePreferredIp(
    String host,
    String? preferredIp,
    List<String> orderedIps,
  ) {
    final normalizedPreferred = _normalizeSingleIp(preferredIp);
    if (normalizedPreferred == null || orderedIps.isEmpty) {
      return null;
    }
    if (_isHostIpPenalized(host, normalizedPreferred)) {
      return null;
    }
    return orderedIps.first == normalizedPreferred ? normalizedPreferred : null;
  }

  bool _isHostIpPenalized(String host, String ip) {
    final penalties = _hostIpPenaltyCache[host];
    if (penalties == null) {
      return false;
    }
    final expiresAt = penalties[ip];
    if (expiresAt == null) {
      return false;
    }
    if (expiresAt.isAfter(DateTime.now())) {
      return true;
    }
    penalties.remove(ip);
    if (penalties.isEmpty) {
      _hostIpPenaltyCache.remove(host);
    }
    return false;
  }

  void _evictExpiredHostIpPenalties() {
    if (_hostIpPenaltyCache.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final emptyHosts = <String>[];
    for (final entry in _hostIpPenaltyCache.entries) {
      entry.value.removeWhere((_, expiresAt) => !expiresAt.isAfter(now));
      if (entry.value.isEmpty) {
        emptyHosts.add(entry.key);
      }
    }
    for (final host in emptyHosts) {
      _hostIpPenaltyCache.remove(host);
    }
  }

  List<DohServer> _decodeServers(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list
            .whereType<Map>()
            .map((e) => DohServer.fromJson(e.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  String get testHost {
    final baseUri = Uri.tryParse(AppConstants.baseUrl);
    return baseUri?.host ?? 'example.com';
  }
}

/// 默认 DOH 服务器列表
/// Bootstrap IP 来源：各 DNS 提供商官方文档
/// Chrome 也是这样实现的：预置 IP 地址，直接连接，不需要先 DNS 解析
const List<DohServer> _defaultServers = [
  DohServer(
    name: 'DNSPod',
    url: 'https://doh.pub/dns-query',
    bootstrapIps: ['1.12.12.12', '120.53.53.53'],
  ),
  DohServer(
    name: '腾讯 DNS',
    url: 'https://dns.pub/dns-query',
    bootstrapIps: ['119.29.29.29', '119.28.28.28'],
  ),
  DohServer(
    name: 'Cloudflare',
    url: 'https://cloudflare-dns.com/dns-query',
    bootstrapIps: [
      '1.1.1.1',
      '1.0.0.1',
      '2606:4700:4700::1111',
      '2606:4700:4700::1001',
    ],
  ),
  DohServer(
    name: 'Canadian Shield',
    url: 'https://private.canadianshield.cira.ca/dns-query',
  ),
  DohServer(
    name: '阿里 DNS',
    url: 'https://dns.alidns.com/dns-query',
    bootstrapIps: [
      '223.5.5.5',
      '223.6.6.6',
      '2400:3200::1',
      '2400:3200:baba::1',
    ],
  ),
  DohServer(
    name: 'Quad9',
    url: 'https://dns.quad9.net/dns-query',
    bootstrapIps: ['9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'],
  ),
  DohServer(
    name: 'Google',
    url: 'https://dns.google/dns-query',
    bootstrapIps: [
      '8.8.8.8',
      '8.8.4.4',
      '2001:4860:4860::8888',
      '2001:4860:4860::8844',
    ],
  ),
];
