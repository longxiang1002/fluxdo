import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'system_proxy_detector.dart';

/// App 进程真实生效代理的**诊断快照**（iOS）。
///
/// 字段全部来自原生 `CFNetworkCopyProxiesForURL` 求值结果：它给出的就是
/// CFNetwork 栈（WKWebView / URLSession）该请求会用的代理，
/// 因此是「WebView 出口」的直接证据。不含 URL、凭据或 PAC 脚本正文。
class SystemProxyProbeEntry {
  const SystemProxyProbeEntry({
    required this.type,
    this.host,
    this.port,
    this.hasPacScript = false,
    this.pacIsRemote = false,
    this.consistentWithSystem,
  });

  /// `http` / `https` / `socks` / `pac` / `pacInline` / `direct` / 未知原值。
  final String type;
  final String? host;
  final int? port;
  final bool hasPacScript;
  final bool pacIsRemote;

  /// 与 [SystemProxyService.effectiveProxyUrl] 的 host:port 是否一致；
  /// 无法比较（缺 host/port）时为 null。
  final bool? consistentWithSystem;

  /// 紧凑可读串（无 URL / 凭据 / PAC 正文），直接进 `describe()` 的日志。
  @override
  String toString() {
    final buffer = StringBuffer(type);
    if (host != null) {
      buffer.write(':$host:${port ?? 0}');
    }
    if (hasPacScript) {
      buffer.write(pacIsRemote ? '(pac:remote)' : '(pac)');
    }
    if (consistentWithSystem == true) {
      buffer.write('=sys');
    }
    return buffer.toString();
  }

  static SystemProxyProbeEntry fromMap(Map<String, Object?> map) {
    final rawPort = map['port'];
    return SystemProxyProbeEntry(
      type: map['type']?.toString() ?? 'unknown',
      host: map['host']?.toString(),
      port: rawPort is num ? rawPort.toInt() : null,
      hasPacScript: map['hasPacScript'] == true,
      pacIsRemote: map['pacIsRemote'] == true,
      consistentWithSystem: map['consistentWithSystem'] is bool
          ? map['consistentWithSystem'] as bool
          : null,
    );
  }
}

class SystemProxyProbe {
  const SystemProxyProbe({required this.entries, this.systemProxyUrl});

  final List<SystemProxyProbeEntry> entries;

  /// 同一次采样里系统设置侧读到的固定代理（可能为 null = 未启用）。
  final String? systemProxyUrl;

  /// 仅当**全部**条目都是同一固定代理、且与系统设置一致时才是 true。
  ///
  /// true 是「WebView 出口可被系统代理决定」的证据，即路径 C（让 DoH 出站
  /// 跟随系统代理）成立的前提；false/null 时说明 App 进程内有 PAC、
  /// 或代理未生效 → DoH 出站与 WebView 出口**无法保证一致**。
  bool? get effectiveExitIsSystemProxy {
    if (entries.isEmpty) return null;
    final fixed = entries.where(
      (e) => (e.type == 'http' || e.type == 'https' || e.type == 'socks'),
    );
    if (fixed.length != entries.length) return false;
    return fixed.every((e) => e.consistentWithSystem == true);
  }

  /// 出口是否走了任何固定代理（不含 direct / pac）。
  bool get usesFixedProxy =>
      entries.isNotEmpty &&
      entries.every(
        (e) => e.type == 'http' || e.type == 'https' || e.type == 'socks',
      );

  /// 高度脱敏的紧凑串，可直接进日志（无 URL / 凭据 / 脚本）。
  String describe() {
    if (entries.isEmpty) {
      return 'entries=0 systemProxy=${systemProxyUrl ?? 'direct'}';
    }
    return 'entries=[${entries.join(', ')}] '
        'systemProxy=${systemProxyUrl ?? 'direct'} '
        'exitIsSystemProxy=$effectiveExitIsSystemProxy';
  }

  static SystemProxyProbe fromChannel(Map<String, Object?> map) {
    final rawEntries = map['entries'];
    final entries = <SystemProxyProbeEntry>[];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map) {
          entries.add(
            SystemProxyProbeEntry.fromMap(Map<String, Object?>.from(item)),
          );
        }
      }
    }
    return SystemProxyProbe(
      entries: entries,
      systemProxyUrl: map['systemProxyUrl']?.toString(),
    );
  }

  /// Fastlane 诊断导出用的脱敏结构。
  ///
  /// 每项只含固定字段（类型 / host / port / 是否 PAC / 与系统设置是否一致）；
  /// 不含请求 URL、凭据、PAC 脚本正文。`exitIsSystemProxy` 直接给出
  /// 「DoH 出站与内部浏览器出口能否保证一致」的判定依据。
  Map<String, Object?> toJson() => {
    'entries': [
      for (final e in entries)
        {
          'type': e.type,
          if (e.host != null) 'host': e.host,
          if (e.port != null) 'port': e.port,
          if (e.hasPacScript) 'hasPacScript': true,
          if (e.pacIsRemote) 'pacIsRemote': true,
          if (e.consistentWithSystem != null)
            'consistentWithSystem': e.consistentWithSystem,
        },
    ],
    'systemProxyUrl': systemProxyUrl,
    'exitIsSystemProxy': effectiveExitIsSystemProxy,
    'usesFixedProxy': usesFixedProxy,
  };

  /// 供诊断导出使用；非 iOS 或读取失败时返回 null。
  static Future<Map<String, Object?>?> exportJson() async {
    final probe = await SystemProxyService.instance.probeEffectiveProxy();
    if (probe == null) return null;
    return probe.toJson();
  }
}

/// Windows / iOS 系统代理跟随服务。
///
/// 背景:WebView2 / WKWebView 默认跟随系统代理(如 Clash「系统代理」模式、
/// 企业配置描述文件的 HTTP 代理),而 Dio/rhttp 走直连。两者出口 IP
/// 不一致时,验证 WebView 铸出的 cf_clearance 绑定的是代理节点 IP,对 Dio
/// 的直连请求永远无效 → CF 验证无限循环。
///
/// 本服务:
/// - Windows:周期读注册表系统代理(10s 节拍),见 [SystemProxyDetector]。
/// - iOS:周期经 MethodChannel `com.fluxdo/system_proxy` 读 CFNetwork
///   系统代理设置(原生层 CFNetworkCopySystemProxySettings)。
/// - 其余平台:直连,不经本服务干预。
///
/// 规则:
/// - 已启用固定代理 → [effectiveProxyUrl] 返回代理地址,Dio 跟随,与
///   WebView 保持同一出口;代理进程若已死,请求显式失败(与 WebView 一致),
///   不做可达性探测——探测无法区分翻墙代理与校园网等普通代理,不能作为
///   任何语义判定依据。
/// - 未启用 / PAC-only(无法在 Dart 侧求值)→ 直连。
///
/// VPN 虚拟网卡(TUN)模式不写系统代理,Dio 与 WebView 都经 TUN 出站,
/// 天然一致,无需本服务干预。
class SystemProxyService {
  SystemProxyService._();

  static final instance = SystemProxyService._();

  static const _refreshInterval = Duration(seconds: 10);

  static const _iosChannel = MethodChannel('com.fluxdo/system_proxy');

  /// 状态版本号。effectiveProxyUrl 变化时自增,RhttpAdapter 据此重建 client。
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  String? _effectiveProxyUrl;
  SystemProxyConfig _lastConfig = const SystemProxyConfig();
  Timer? _refreshTimer;
  bool _started = false;

  /// 当前系统代理地址(已启用的固定代理),未启用时为 null。
  ///
  /// 已启用固定代理 → 返回代理地址(Dio 跟随,与 WebView 保持同一出口);
  /// 代理进程若已死,请求显式失败(与 WebView 一致),不做可达性探测——
  /// 探测无法区分翻墙代理与校园网等普通代理,不能作为任何语义判定依据。
  ///
  /// 返回前做**格式校验**([sanitizeProxyUrl]):原生侧已过滤非法值,这里再
  /// 兜一层,避免把畸形 URL 透传给 rhttp/Dio 导致全部请求挂死
  /// (历史教训:iOS 系统代理误读 → 全站白屏)。
  String? get effectiveProxyUrl {
    _ensureStarted();
    return sanitizeProxyUrl(_effectiveProxyUrl);
  }

  /// 校验并规范化系统代理 URL;非法时返回 null(调用方退化为直连)。
  ///
  /// 只接受 `http://host:port`(CFNetwork/注册表里固定代理必为 HTTP 型),
  /// host 非空、port 在 1..65535、不含 userInfo;socks 由上游代理设置单独
  /// 处理,系统代理不承载。回环地址不在此拦截(本地代理如 Clash 常监听
  /// 127.0.0.1,是合法配置),由调用方按是否回环决定是否直连。
  @visibleForTesting
  static String? sanitizeProxyUrl(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final u = Uri.tryParse(trimmed);
    if (u == null) return null;
    if (u.scheme != 'http') return null;
    if (u.host.isEmpty) return null;
    if (u.userInfo.isNotEmpty) return null;
    if (!u.hasPort) return null;
    if (u.port <= 0 || u.port > 65535) return null;
    return 'http://${u.host}:${u.port}';
  }

  /// 注册表层面的系统代理配置(仅 Windows 有意义),供诊断 UI 展示。
  SystemProxyConfig get registryConfig => _lastConfig;

  /// 启动周期刷新。非 Windows / iOS 平台为 no-op。
  void start() => _ensureStarted();

  void _ensureStarted() {
    if (_started) return;
    if (!(Platform.isWindows || Platform.isIOS)) return;
    _started = true;
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => refresh());
    refresh();
  }

  /// 立即重读系统代理。Windows 读注册表;iOS 走原生 CFNetwork 读取。
  void refresh() {
    if (Platform.isWindows) {
      _refreshWindows();
    } else if (Platform.isIOS) {
      _refreshIos();
    }
  }

  void _refreshWindows() {
    final config = SystemProxyDetector.read();
    _lastConfig = config;
    _updateEffective(config.proxyUrl);
  }

  Future<void> _refreshIos() async {
    try {
      final proxy = await _iosChannel.invokeMethod<String>('effectiveProxyUrl');
      _updateEffective(proxy);
    } catch (e) {
      debugPrint('[SystemProxy] iOS 读取系统代理失败: $e');
    }
  }

  void _updateEffective(String? effective) {
    if (effective == _effectiveProxyUrl) return;
    debugPrint(
      '[SystemProxy] 系统代理变化: ${_effectiveProxyUrl ?? 'direct'} -> '
      '${effective ?? 'direct'}',
    );
    _effectiveProxyUrl = effective;
    version.value++;
  }

  /// 诊断：读取 **App 进程真实生效**的 CFNetwork 代理配置。
  ///
  /// 背景（iOS 14 内部浏览器 DoH 接管，路径 C 的前提校验）：
  /// 让「DoH 出站跟随系统代理」这条路成立，前提是 **WKWebView 确实走系统代理**。
  /// 这一步只靠读系统设置无法证明——系统代理是**每进程**取自
  /// `CFNetworkCopySystemProxySettings`，需要一个实证点。
  ///
  /// 原生侧用 `CFNetworkCopyProxiesForURL`（与 CFNetwork 栈同一份求值结果）
  /// 读取**本 App 进程**的代理字典，因此本方法返回的 `type/host/port`
  /// 就是 WKWebView 请求实际会用的出口；拿它和
  /// [effectiveProxyUrl]（DoH 网关出站依据）比对，即可判定两通道出口是否一致。
  ///
  /// 只返回固定字段，无 URL、无凭据、无 PAC 脚本正文。
  /// 非 iOS 平台返回 `null`（Android/桌面不适用该判定）。
  Future<SystemProxyProbe?> probeEffectiveProxy() async {
    if (!Platform.isIOS) return null;
    try {
      final raw = await _iosChannel.invokeMethod<Map<Object?, Object?>>(
        'proxyProbe',
      );
      if (raw == null) return null;
      return SystemProxyProbe.fromChannel(Map<String, Object?>.from(raw));
    } catch (e) {
      debugPrint('[SystemProxy] iOS 读取生效代理失败: $e');
      return null;
    }
  }

  @visibleForTesting
  void resetForTest() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _started = false;
    _effectiveProxyUrl = null;
    _lastConfig = const SystemProxyConfig();
  }
}
