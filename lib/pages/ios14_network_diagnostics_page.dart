import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/network/adapters/apple_transport_policy.dart';
import '../services/network/adapters/platform_adapter.dart';
import '../services/network/adapters/webview_bridge_diagnostics.dart';
import '../services/network/doh/doh_route_diagnostics.dart';
import '../services/network/doh/network_settings_service.dart';
import '../services/network/proxy/gateway_upstream.dart';
import '../services/network/proxy/proxy_settings_service.dart';

/// 把 [NetworkSettingsService.webViewProxyState] 的机器值翻成一句人话。
///
/// 刻意与枚举一一对应、不回退到默认文案：测试包需要能从界面文字直接区分
/// 「系统版本就没有这个能力」和「有能力但调用失败」。
String webViewProxyStateLabel(String state) => switch (state) {
  'unsupported' => '当前系统版本无接管 API',
  'not-running' => '本地代理未运行，未尝试接管',
  'attempting' => '已发起接管，结果未定',
  'failed' => '已发起接管但失败',
  'applied' => '接管调用已成功',
  _ => '状态未知',
};

/// 测试包专用入口：所有显示内容均为能力/路由元数据，无账户内容。
class Ios14NetworkDiagnosticsPage extends StatefulWidget {
  const Ios14NetworkDiagnosticsPage({super.key});

  @override
  State<Ios14NetworkDiagnosticsPage> createState() =>
      _Ios14NetworkDiagnosticsPageState();
}

class _Ios14NetworkDiagnosticsPageState
    extends State<Ios14NetworkDiagnosticsPage> {
  final _settings = NetworkSettingsService.instance;
  final _routes = DohRouteDiagnostics.instance;
  final _proxyService = ProxySettingsService.instance;
  final _bridge = WebViewBridgeDiagnostics.instance;
  bool _testing = false;
  String _dnsResult = '尚未测试';
  int? _testedVersion;

  @override
  void initState() {
    super.initState();
    _settings.notifier.addListener(_changed);
    _settings.isApplying.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _settings.notifier.removeListener(_changed);
    _settings.isApplying.removeListener(_changed);
    super.dispose();
  }

  Future<void> _testDns() async {
    final config = _settings.current;
    final version = _settings.version;
    setState(() {
      _testing = true;
      _dnsResult = '测试中';
    });
    try {
      // 直接调用生产使用的 Rust DoH 解析，不把系统 DNS 兜底当成功。
      final result = await _settings.proxyService
          .lookupHost(
            'linux.do',
            config.selectedServerUrl,
            preferIpv6: config.preferIPv6,
            forceRefresh: true,
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _testedVersion = version;
        _dnsResult = result != null && result.ips.isNotEmpty
            ? 'Rust DoH 查询成功（${result.ips.length} 个地址）；仅证明解析，不代表 WebView 已接管'
            : '解析未返回地址；不能认定 DoH 生效';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _testedVersion = version;
        _dnsResult = 'DoH 查询失败或超时；未使用系统 DNS 结果冒充成功';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 本地网关实际会使用的上游（应用内代理 > 系统代理 > 直连）。
  ///
  /// 与 `gateway_upstream.dart::GatewayUpstream.resolve` 同一优先级口径，
  /// 用于回答「配置好的 SS 到底有没有被网关接走」这个此前完全不可见的问题。
  GatewayUpstream? get _resolvedUpstream => GatewayUpstream.resolve(
    applicationProxy: _proxyService.current,
    systemProxyUrl: null,
  );

  /// SS 加密算法名，仅用于确认「是 SS 而非 SOCKS5/HTTP」；不含任何密钥材料。
  String? get _upstreamCipher {
    final s = _proxyService.current;
    return s.isShadowsocks && s.cipher.isNotEmpty ? s.cipher : null;
  }

  Map<String, Object?> _report() => {
    'schema': 1,
    'iosMajor': Platform.isIOS
        ? appleSystemMajorVersion(Platform.operatingSystemVersion)
        : null,
    'settingsVersion': _settings.version,
    'dohConfigured': _settings.current.dohEnabled,
    'gatewayRunning': _settings.isGatewayMode,
    'proxyStartFailed': _settings.lastStartFailed,
    'configurationApplying':
        _settings.isApplying.value || _settings.pendingStart,
    'serverIpOverrideConfigured':
        _settings.current.serverIp?.isNotEmpty ?? false,
    'proxyResolverMatchesSelection': _settings.proxyService.isUsingDohServer(
      _settings.current.selectedServerUrl,
    ),
    'webViewProxyApplied': _settings.webViewProxyApplied,
    // 三态拆解：把「本来就无接管 API」「尝试过但失败」「成功」分开，
    // 避免 webViewProxyApplied=false 这一个布尔值掩盖真实原因。
    'webViewProxyState': _settings.webViewProxyState,
    'webViewProxyAttempted': _settings.webViewProxyAttempted,
    'webViewProxyError': _settings.lastWebViewProxyError,
    'webViewProxyErrorIsMissingPlugin':
        _settings.lastWebViewProxyErrorWasMissingPlugin,
    // 内部浏览器与 DoH 是否已确证同一出口（null = 未采样，不冒充成功）。
    'dohEgressVerified': _routes.dohEgressVerified,
    'dohRouteExact': _routes.dohRouteExact,
    // ── 上游代理（含 Shadowsocks）是否进入本地网关 ──
    // 只暴露协议/主机/端口与「是否有效」，绝不落盘或展示口令/密钥。
    'upstreamConfigured': _proxyService.current.enabled,
    'upstreamProtocol': _proxyService.current.protocol.storageValue,
    'upstreamHost': _proxyService.current.host,
    'upstreamPort': _proxyService.current.port,
    'upstreamIsValid': _proxyService.current.isValid,
    'upstreamResolvedProtocol': _resolvedUpstream?.protocol,
    'upstreamResolvedHost': _resolvedUpstream?.host,
    'upstreamResolvedPort': _resolvedUpstream?.port,
    'upstreamCipher': _upstreamCipher,
    // ── 网络桥开销画像（D1）──
    // 只暴露聚合计数与字节量，不含 URL/正文，无账户内容。
    'bridgeStats': _bridgeReport(),
    'iosIoFallback': usesIosIoTransport,
    'dnsTestVersion': _testedVersion,
    'dnsTestResult': _dnsResult,
    'routes': _routes.snapshot(),
  };

  Map<String, Object?> _bridgeReport() {
    final s = WebViewBridgeDiagnostics.instance;
    return {
      'totalRequests': s.totalRequests,
      'imageSameOrigin': s.imageSameOrigin,
      'imageOther': s.imageOther,
      'apiGet': s.apiGet,
      'apiWrite': s.apiWrite,
      'other': s.other,
      'textResponses': s.textResponses,
      'textResponseBytes': s.textResponseBytes,
      'streamResponses': s.streamResponses,
      'streamResponseBytes': s.streamResponseBytes,
      'totalResponseBytes': s.totalResponseBytes,
      'requestBodyBase64': s.requestBodyBase64,
      'requestBodyStreamBridge': s.requestBodyStreamBridge,
      'requestBodyDirect': s.requestBodyDirect,
      'avgTotalMs': s.totalRequests == 0 ? 0 : s.totalMs ~/ s.totalRequests,
      'avgJsEvalMs': s.totalRequests == 0 ? 0 : s.jsEvalMs ~/ s.totalRequests,
      'failed': s.failed,
      'cookieSweeps': s.cookieSweeps,
      'cookieSweepsSkipped': s.cookieSweepsSkipped,
      'cookieBatchCountCalls': s.cookieBatchCountCalls,
      'cookieBatchCountNames': s.cookieBatchCountNames,
    };
  }

  @override
  Widget build(BuildContext context) {
    final version = _settings.version;
    final oldTest = _testedVersion != null && _testedVersion != version;
    final iosMajor = appleSystemMajorVersion(Platform.operatingSystemVersion);
    final webViewUnsupported =
        Platform.isIOS && (iosMajor == null || iosMajor < 17);
    return Scaffold(
      appBar: AppBar(title: const Text('iOS 14 网络验证')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '实际基础引擎：${getAdapterDisplayName(resolveEffectiveAdapter().type)}',
          ),
          Text('DoH 开关：${_settings.current.dohEnabled ? "开启" : "关闭"}'),
          Text('本地 DoH 网关：${_settings.isGatewayMode ? "运行中" : "未运行"}'),
          Text('代理启动失败：${_settings.lastStartFailed ? "是" : "否"}'),
          Text(
            '配置应用中：${_settings.isApplying.value || _settings.pendingStart ? "是，稍后重新验证" : "否"}',
          ),
          Text(
            'WebView 代理实际设置：${_settings.webViewProxyApplied ? "已应用" : "未应用"}'
            '（${webViewProxyStateLabel(_settings.webViewProxyState)}）',
          ),
          if (_settings.lastWebViewProxyError != null)
            Text(
              'WebView 接管失败原因：${_settings.lastWebViewProxyError}'
              '${_settings.lastWebViewProxyErrorWasMissingPlugin ? "（原生接口未注册，属系统版本能力缺失）" : ""}',
            ),
          Text(
            '内部浏览器与 DoH 出口是否一致：'
            '${switch (_routes.dohEgressVerified) {
              true => "已确证一致",
              false => "已确证不一致",
              null => "尚未采样",
            }}',
          ),
          const Divider(height: 24),
          Text(
            '上游代理（含 Shadowsocks）',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(
            '应用内代理配置：'
            '${_proxyService.current.enabled ? "已启用" : "未启用"}'
            '${_proxyService.current.hasServer ? "（${_proxyService.current.protocol.storageValue}://${_proxyService.current.host}:${_proxyService.current.port}）" : "（未填写服务器）"}',
          ),
          Text(
            '配置是否有效：${_proxyService.current.isValid ? "有效" : "无效或不完整"}'
            '${_upstreamCipher != null ? "，加密：$_upstreamCipher" : ""}',
          ),
          Text(
            '网关实际采用的最终上游：'
            '${_resolvedUpstream == null ? "直连（未使用任何上游代理）" : "${_resolvedUpstream!.protocol}://${_resolvedUpstream!.host}:${_resolvedUpstream!.port}"}',
          ),
          if (_resolvedUpstream == null && _proxyService.current.enabled)
            const Text('注意：已启用应用内代理，但配置无效（服务器/端口缺失或 SS 密钥不合法），网关仍按直连处理。'),
          if (_resolvedUpstream != null)
            Text(
              '内置浏览器接管：'
              '${_settings.webViewProxyApplied ? "已把 WebView 指向本地网关，上游为上述代理" : "未接管（WebView 流量未进入本地网关，上游代理对其无效）"}',
            ),
          const Text(
            '说明：上游代理作用于「本地网关的上游出口」。若内置浏览器未被接管，WebView 流量不经过网关，此处的 SS 配置对它同样无效。',
          ),
          const Divider(height: 24),
          Text('网络桥开销画像（活跃负载）', style: Theme.of(context).textTheme.titleSmall),
          Text(
            '走桥请求总数：${_bridge.totalRequests}'
            '（图片同源 ${_bridge.imageSameOrigin} / 图片其他 ${_bridge.imageOther}'
            ' / API 读 ${_bridge.apiGet} / 写 ${_bridge.apiWrite}'
            ' / 其他 ${_bridge.other}）',
          ),
          Text(
            '响应字节：共 ${_bridge.totalResponseBytes}B'
            '（文本 ${_bridge.textResponseBytes}B / 二进制流 ${_bridge.streamResponseBytes}B）',
          ),
          Text(
            '流响应 ${_bridge.streamResponses} 次，文本响应 ${_bridge.textResponses} 次；'
            '失败 ${_bridge.failed} 次',
          ),
          Text(
            '请求体形态：direct ${_bridge.requestBodyDirect}'
            ' / streamBridge ${_bridge.requestBodyStreamBridge}'
            ' / base64 ${_bridge.requestBodyBase64}',
          ),
          Text(
            '平均耗时 ${_bridge.totalRequests == 0 ? 0 : _bridge.totalMs ~/ _bridge.totalRequests}ms'
            '（其中 JS 调用 ${_bridge.totalRequests == 0 ? 0 : _bridge.jsEvalMs ~/ _bridge.totalRequests}ms）',
          ),
          Text(
            'Cookie 边界同步：执行 ${_bridge.cookieSweeps} 次'
            ' / 省去 ${_bridge.cookieSweepsSkipped} 次',
          ),
          Text(
            '批量取数：${_bridge.cookieBatchCountCalls} 次调用'
            '覆盖 ${_bridge.cookieBatchCountNames} 个 cookie 名'
            '（预计省 ${_bridge.cookieBatchCountNames - _bridge.cookieBatchCountCalls} 次原生枚举）',
          ),
          const Text(
            '说明：边界同步（sweepAll）会对每个 cookie 名做多次原生 cookie 库往返，'
            '此前每个走桥请求都跑一遍。现仅在新建 WebView 会话或 WV 侧写过 cookie 后执行，'
            '且变体计数改为一次批量调用（原生侧一次 getAllCookies 枚举），'
            '「省去」次数即本轮减少的原生调用批次。',
          ),
          const Text(
            '说明：统计自进程启动以来所有经 WebView 桥的请求，常驻聚合、不含 URL 与正文。'
            '刷帖前后各看一次差值，即可判断活跃发热时图片与 API 各占多少。',
          ),
          OutlinedButton(
            onPressed: () => setState(WebViewBridgeDiagnostics.instance.reset),
            child: const Text('重置桥统计（刷帖前清零）'),
          ),
          const Divider(height: 24),
          if (webViewUnsupported)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'iOS 17 以下无法通过现有接口把 WebView 接入应用 DoH。登录、CF 和兼容模式可能使用系统网络。应用 DoH 开关不代表全应用覆盖。',
              ),
            ),
          const Text(
            '标准模式在 iOS 14 使用 IO；系统 VPN 与 HTTP 代理不是一回事。此页面不会切换你的 DNS、VPN 或账户。',
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _testing || !_settings.current.dohEnabled
                ? null
                : _testDns,
            child: const Text('测试当前 DoH（linux.do）'),
          ),
          Text(oldTest ? '配置已变化，以下测试仅供历史参考：$_dnsResult' : _dnsResult),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('采集实际请求路由'),
            subtitle: const Text('默认关闭，最多60条，仅内存。启用后返回刷帖，再来刷新查看。'),
            value: _routes.enabled,
            onChanged: (value) => setState(() => _routes.setEnabled(value)),
          ),
          const Text(
            'gateway 表示请求实际交给本地网关；还需 gatewayResolverMatched=true 才说明解析器配置匹配且无固定 IP 覆盖。dohEgressVerified 只有在内部浏览器出口被实测确证走 DoH 时才为 true，未采样运行时为 null（不冒充成功）。HTTP 状态仅为响应头结果。direct-or-rhttp 不等于已验证 DoH；webview 不等于已接入应用 DoH。配置代号不同的记录仅作历史参考。',
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => setState(() {}),
                child: const Text('刷新记录'),
              ),
              OutlinedButton(
                onPressed: () => setState(_routes.reset),
                child: const Text('清空记录'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(
                      text: const JsonEncoder.withIndent(
                        '  ',
                      ).convert(_report()),
                    ),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('已复制脱敏网络报告')));
                  }
                },
                child: const Text('复制脱敏报告'),
              ),
            ],
          ),
          SelectableText(const JsonEncoder.withIndent('  ').convert(_report())),
        ],
      ),
    );
  }
}
