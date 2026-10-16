import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diagnostics/ios14_diagnostics.dart';
import '../services/network/adapters/apple_transport_policy.dart';
import '../services/network/adapters/platform_adapter.dart';
import '../services/network/adapters/webview_bridge_diagnostics.dart';
import '../services/network/adapters/webview_bridge_probe.dart';
import '../services/network/adapters/webview_bridge_gate.dart';
import '../services/network/doh/doh_route_diagnostics.dart';
import '../services/network/doh/network_settings_service.dart';
import '../services/network/proxy/gateway_upstream.dart';
import '../services/network/proxy/proxy_settings_service.dart';
import '../services/network/webview/webview_adapter_settings_service.dart';

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
  final _probe = WebViewBridgeProbe.instance;
  final _gate = WebViewBridgeGate.instance;
  final _diag = Ios14Diagnostics.instance;
  bool _testing = false;
  String _dnsResult = '尚未测试';
  int? _testedVersion;

  @override
  void initState() {
    super.initState();
    _settings.notifier.addListener(_changed);
    _settings.isApplying.addListener(_changed);
    WebViewAdapterSettingsService.instance.imageNativeRoutingNotifier
        .addListener(_changed);
    WebViewAdapterSettingsService.instance.gateMaxConcurrentNotifier
        .addListener(_changed);
    WebViewAdapterSettingsService.instance.imageSkipPathsNotifier.addListener(
      _changed,
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// D27：弹窗输入一条「分流跳过片段」（图片 URL path 的子串，小写）。
  ///
  /// 用途：D2 整体分流同源图片后，若某条路径实测被 CF 拦/变糊，只把该路径
  /// 拉回走桥，而不必整体关掉分流。片段落盘，跨重启保持。
  Future<void> _addImageSkipPath() async {
    final controller = TextEditingController();
    final fragment = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加一条分流跳过片段'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '如 uploads/ 或 /user_avatar/',
            helperText: '按图片 URL 的 path 做子串匹配，命中则该路径仍走桥',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (fragment == null || fragment.trim().isEmpty) return;
    WebViewAdapterSettingsService.instance.addImageSkipPath(fragment);
  }

  @override
  void dispose() {
    _settings.notifier.removeListener(_changed);
    _settings.isApplying.removeListener(_changed);
    WebViewAdapterSettingsService.instance.imageNativeRoutingNotifier
        .removeListener(_changed);
    WebViewAdapterSettingsService.instance.gateMaxConcurrentNotifier
        .removeListener(_changed);
    WebViewAdapterSettingsService.instance.imageSkipPathsNotifier
        .removeListener(_changed);
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
    // ── 已读上报（/topics/timings）计数 ──
    // 只暴露固定事件计数，不含 URL/正文/账户内容。
    'readReport': {
      'timingsSend': _diag.countOf(Ios14DiagnosticEvent.timingsSend),
      'timingsSuccess': _diag.countOf(Ios14DiagnosticEvent.timingsSuccess),
      'timingsError': _diag.countOf(Ios14DiagnosticEvent.timingsError),
      'timingsRetry': _diag.countOf(Ios14DiagnosticEvent.timingsRetry),
      'diagnosticsEnabled': _diag.enabled,
    },
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
      'imageResponseBytes': s.imageResponseBytes,
      'activeLoadVerdict': s.activeLoadVerdict,
      'bridgeCostVerdict': s.bridgeCostVerdict,
      'bridgeTaxBreakdownVerdict': s.bridgeTaxBreakdownVerdict,
      'gateVsTaxVerdict': s.gateVsTaxVerdict,
      'gateSaturationVerdict': s.gateSaturationVerdict,
      'gateTuningVerdict': s.gateTuningVerdict,
      'bridgeByteTaxVerdict': s.bridgeByteTaxVerdict,
      'binaryBridgeResponses': s.binaryBridgeResponses,
      'binaryBridgeBytes': s.binaryBridgeBytes,
      'binaryBridgeChunks': s.binaryBridgeChunks,
      'classTimeVerdict': s.classTimeVerdict,
      'perRequestTaxVerdict': s.perRequestTaxVerdict,
      'averageBridgeCostMs': s.averageBridgeCostMs,
      'pathCostVerdict': s.pathCostVerdict,
      'textPathMs': s.textPathMs,
      'streamPathMs': s.streamPathMs,
      'textPathRequests': s.textPathRequests,
      'streamPathRequests': s.streamPathRequests,
      'textPathCostMs': s.textPathCostMs,
      'streamPathCostMs': s.streamPathCostMs,
      // D40: 无效负载——走桥请求的状态码分桶与白付税占比。
      'status2xx': s.status2xx,
      'status3xx': s.status3xx,
      'status4xx': s.status4xx,
      'status5xx': s.status5xx,
      'transportFailed': s.transportFailed,
      'wastedRequests': s.wastedRequests,
      'wastedSharePct': s.wastedSharePct,
      'wastedLoadVerdict': s.wastedLoadVerdict,
      // D41: 无效负载代价——白付税换算成桥内耗时下界与占比。
      'wastedCostVerdict': s.wastedCostVerdict,
      // D42: 无效负载来源——白付税集中在哪一类请求，决定下一步动谁。
      'wastedSourceVerdict': s.wastedSourceVerdict,
      'imageSameOriginMs': s.imageSameOriginMs,
      'imageOtherMs': s.imageOtherMs,
      'apiGetMs': s.apiGetMs,
      'apiWriteMs': s.apiWriteMs,
      'otherMs': s.otherMs,
      'gateMaxConcurrent':
          WebViewAdapterSettingsService.instance.gateMaxConcurrent,
      'gateWeightedAcquires': _gate.weightedAcquires,
      'gateInFlight': _gate.inFlight,
      'gateQueuedWeighted': _gate.queuedWeighted,
      'gateWaiting': _gate.waiting,
      'queueAttributionVerdict': s.queueAttributionVerdict,
      'classPhaseVerdict': s.classPhaseVerdict,
      'gateSaturationTimeVerdict': s.gateSaturationTimeVerdict,
      'gateSaturatedMs': _gate.saturatedMs,
      'gateUnsaturatedMs': _gate.unsaturatedMs,
      // D43: 采样空白（无请求事件的观测时长）与采样密度自检结论——
      // 用于判断 D33 饱和占比的可信度。
      'gateUnobservedGapMs': _gate.unobservedGapMs,
      'gateSampleDensityVerdict': _gate.sampleDensityVerdict,
      'gateObservedMs': _gate.observedMs,
      'gateSaturationPct': _gate.saturationPct,
      'endToEndAttributionVerdict': s.endToEndAttributionVerdict,
      'totalEndToEndMs': s.totalEndToEndMs,
      'imageSameOriginTotalMs': s.imageSameOriginTotalMs,
      'imageOtherTotalMs': s.imageOtherTotalMs,
      'apiGetTotalMs': s.apiGetTotalMs,
      'apiWriteTotalMs': s.apiWriteTotalMs,
      'otherTotalMs': s.otherTotalMs,
      'queueShareOfEndToEndPct': s.queueShareOfEndToEndPct,
      'totalClassifiedCookieMs': s.totalClassifiedCookieMs,
      'totalClassifiedJsMs': s.totalClassifiedJsMs,
      'totalClassifiedBrowserMs': s.totalClassifiedBrowserMs,
      'imageJsMs': s.imageJsMs,
      'imageBrowserMs': s.imageBrowserMs,
      'queueTotalMs': s.totalQueueMs,
      'imageSameOriginQueueMs': s.imageSameOriginQueueMs,
      'imageOtherQueueMs': s.imageOtherQueueMs,
      'apiGetQueueMs': s.apiGetQueueMs,
      'apiWriteQueueMs': s.apiWriteQueueMs,
      'otherQueueMs': s.otherQueueMs,
      'avgActiveConcurrency':
          WebViewBridgeProbe.instance.averageActiveConcurrency,
      'activeSampledMs': WebViewBridgeProbe.instance.activeSampledMs,
      'idleSampledMs': WebViewBridgeProbe.instance.idleSampledMs,
      'activeTimeSharePct': WebViewBridgeProbe.instance.activeTimeSharePct,
      'activeTimeVerdict': WebViewBridgeProbe.instance.activeTimeVerdict,
      'streamInFlight': WebViewBridgeProbe.instance.streamInFlight,
      'streamAwareVerdict': WebViewBridgeProbe.instance.streamAwareVerdict,
      'avgCookiePrepMs': s.totalRequests == 0
          ? 0
          : s.cookiePrepMs ~/ s.totalRequests,
      'avgBrowserWaitMs': s.totalRequests == 0
          ? 0
          : s.browserWaitMs ~/ s.totalRequests,
      'avgCookieBackSyncMs': s.totalRequests == 0
          ? 0
          : s.cookieBackSyncMs ~/ s.totalRequests,
      'avgInFlightMs': WebViewBridgeProbe.instance.averageInFlightMs,
      'requestBodyBase64': s.requestBodyBase64,
      'requestBodyStreamBridge': s.requestBodyStreamBridge,
      'requestBodyDirect': s.requestBodyDirect,
      'requestBodyInlineSmall': s.requestBodyInlineSmall,
      'avgTotalMs': s.totalRequests == 0 ? 0 : s.totalMs ~/ s.totalRequests,
      'avgJsEvalMs': s.totalRequests == 0 ? 0 : s.jsEvalMs ~/ s.totalRequests,
      'failed': s.failed,
      'cookieSweeps': s.cookieSweeps,
      'cookieSweepsSkipped': s.cookieSweepsSkipped,
      'cookieBatchCountCalls': s.cookieBatchCountCalls,
      'cookieBatchCountNames': s.cookieBatchCountNames,
      'variantCountCacheHits': s.variantCountCacheHits,
      'imageRoutedNative': s.imageRoutedNative,
      'imageRoutingSkipped': s.imageRoutingSkipped,
      'imageSkipPaths': WebViewAdapterSettingsService.instance.imageSkipPaths,
      'streamRawChunks': s.streamRawChunks,
      'streamCoalescedMessages': s.streamCoalescedMessages,
      'streamMessagesSaved': s.streamMessagesSaved,
      'cookieSweepsDeferred': s.cookieSweepsDeferred,
      'textBodyUnescaped': s.textBodyUnescaped,
      'textBodyUnescapedBytes': s.textBodyUnescapedBytes,
      'webViewPreservedOnConfigChange': s.webViewPreservedOnConfigChange,
      'primingDeduped': s.primingDeduped,
      'cookieSweepsSkippedForImage': s.cookieSweepsSkippedForImage,
      'cookieBackSyncDeduped': s.cookieBackSyncDeduped,
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
          if (_bridge.activeLoadVerdict != null)
            Text(
              '活跃发热归因速判（D15）：${_bridge.activeLoadVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          if (_bridge.bridgeCostVerdict != null)
            Text(
              '桥单位成本速判（D16）：${_bridge.bridgeCostVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          if (_bridge.bridgeTaxBreakdownVerdict != null)
            Text(
              '桥固定税拆解（D17）：${_bridge.bridgeTaxBreakdownVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          if (_bridge.gateVsTaxVerdict != null)
            Text(
              '闸门排队 vs 固定税归因（D20）：${_bridge.gateVsTaxVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          if (_bridge.gateSaturationVerdict != null)
            Text(
              '闸门饱和度（D21）：${_bridge.gateSaturationVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          if (_bridge.bridgeByteTaxVerdict != null)
            Text(
              '跨桥字节搬运税（D25）：${_bridge.bridgeByteTaxVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          Text(
            '流路径固定成本（D25）：${_bridge.binaryBridgeResponses} 个流响应'
            ' / ${_bridge.binaryBridgeChunks} 次分块回调'
            ' / ${_bridge.binaryBridgeBytes}B'
            '（每次回调 = 一次 JS↔native 边界穿越）',
          ),
          if (_bridge.classTimeVerdict != null)
            Text(
              '类别耗时归因（D26）：${_bridge.classTimeVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          if (_bridge.perRequestTaxVerdict != null)
            Text(
              '单请求固定税（D37）：${_bridge.perRequestTaxVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          if (_bridge.pathCostVerdict != null)
            Text(
              '响应路径成本对比（D38）：${_bridge.pathCostVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          Text(
            '路径拆分（D38）：文本路径 ${_bridge.textPathRequests} 条'
            ' / ${_bridge.textPathMs}ms'
            '（平均 ${_bridge.textPathCostMs?.round() ?? 0}ms）'
            '；流路径 ${_bridge.streamPathRequests} 条'
            ' / ${_bridge.streamPathMs}ms'
            '（平均 ${_bridge.streamPathCostMs?.round() ?? 0}ms）',
          ),
          Text(
            '各类别桥内耗时（D26）：图片同源 ${_bridge.imageSameOriginMs}ms'
            ' / 图片其他 ${_bridge.imageOtherMs}ms'
            ' / API 读 ${_bridge.apiGetMs}ms'
            ' / 写 ${_bridge.apiWriteMs}ms'
            ' / 其他 ${_bridge.otherMs}ms',
          ),
          if (_bridge.classPhaseVerdict != null)
            Text(
              '桥内分段归因（D32）：${_bridge.classPhaseVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          Text(
            '桥内三段耗时（D32）：cookie准备 '
            '${_bridge.totalClassifiedCookieMs}ms'
            ' / JS调用 ${_bridge.totalClassifiedJsMs}ms'
            ' / 等浏览器 ${_bridge.totalClassifiedBrowserMs}ms',
          ),
          Text(
            '图片类分段（D32）：JS调用 ${_bridge.imageJsMs}ms'
            ' / 等浏览器 ${_bridge.imageBrowserMs}ms'
            '（前者=纯 CPU 固定税，后者=I/O 等待，优化手段不同）',
          ),
          Text(
            '走桥请求总数：${_bridge.totalRequests}'
            '（图片同源 ${_bridge.imageSameOrigin} / 图片其他 ${_bridge.imageOther}'
            ' / API 读 ${_bridge.apiGet} / 写 ${_bridge.apiWrite}'
            ' / 其他 ${_bridge.other}）',
          ),
          // D40: 无效负载——走桥请求里有多少「付了满额固定税却没换回内容」。
          if (_bridge.totalRequests > 0)
            Text(
              '无效负载（D40）：${_bridge.wastedRequests} 条'
              '（${_bridge.wastedSharePct?.toStringAsFixed(1) ?? "-"}%）'
              '— 4xx ${_bridge.status4xx} / 5xx ${_bridge.status5xx}'
              ' / 传输失败 ${_bridge.transportFailed}'
              '（另有 2xx ${_bridge.status2xx} / 3xx ${_bridge.status3xx}）',
            ),
          if (_bridge.wastedLoadVerdict != null)
            Text(
              _bridge.wastedLoadVerdict!,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          // D41: 无效负载代价——把「白付税条数」换算成桥内耗时下界，
          // 直接回答「砍无效负载值不值得做」。
          if (_bridge.wastedCostVerdict != null)
            Text(
              _bridge.wastedCostVerdict!,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          // D42: 无效负载来源——白付税集中在哪一类，决定下一步动谁。
          if (_bridge.wastedSourceVerdict != null)
            Text(
              _bridge.wastedSourceVerdict!,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          if (_bridge.imageRoutedNative > 0)
            Text(
              '同源图片已分流原生直连：${_bridge.imageRoutedNative} 次'
              '（D2：这些请求不再走 JS fetch + 分块回传的桥路径）',
            ),
          if (_bridge.imageRoutingSkipped > 0)
            Text(
              '同源图片按豁免名单仍走桥：${_bridge.imageRoutingSkipped} 次'
              '（D27：命中下方跳过片段，回退到走桥旧行为）',
            ),
          Text(
            '分流跳过名单（D27）：'
            '${WebViewAdapterSettingsService.instance.imageSkipPaths.isEmpty ? "（空，全部同源图片都分流）" : WebViewAdapterSettingsService.instance.imageSkipPaths.join(" / ")}',
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: _addImageSkipPath,
                child: const Text('加一条跳过片段'),
              ),
              if (WebViewAdapterSettingsService
                  .instance
                  .imageSkipPaths
                  .isNotEmpty)
                OutlinedButton(
                  onPressed: () => setState(
                    () => WebViewAdapterSettingsService.instance
                        .clearImageSkipPaths(),
                  ),
                  child: const Text('清空名单'),
                ),
              for (final fragment
                  in WebViewAdapterSettingsService.instance.imageSkipPaths)
                InputChip(
                  label: Text(fragment),
                  onDeleted: () => setState(
                    () => WebViewAdapterSettingsService.instance
                        .removeImageSkipPath(fragment),
                  ),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('同源图片走原生直连（D2 A/B）'),
            subtitle: const Text(
              '开启=图片分流到原生 Dio（省桥负载）；若刷帖出现图片变糊/CF 拦截，关掉即回到走桥旧行为。运行时即切即生效。',
            ),
            value: WebViewAdapterSettingsService
                .instance
                .imageNativeRoutingEnabled,
            onChanged: (value) => setState(
              () => WebViewAdapterSettingsService.instance
                  .setImageNativeRouting(value),
            ),
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
            ' / base64 ${_bridge.requestBodyBase64}'
            ' / 小体内联 ${_bridge.requestBodyInlineSmall}',
          ),
          Text(
            '平均耗时 ${_bridge.totalRequests == 0 ? 0 : _bridge.totalMs ~/ _bridge.totalRequests}ms'
            '（其中 JS 调用 ${_bridge.totalRequests == 0 ? 0 : _bridge.jsEvalMs ~/ _bridge.totalRequests}ms）',
          ),
          Text(
            'Cookie 边界同步：执行 ${_bridge.cookieSweeps} 次'
            ' / 省去 ${_bridge.cookieSweepsSkipped} 次',
          ),
          if (_bridge.cookieSweepsDeferred > 0)
            Text(
              '边界同步延后收敛：${_bridge.cookieSweepsDeferred} 次'
              '（D4：WV cookie 变化交由 debounce 在请求路径外收敛，'
              '不再让每个走桥请求各背一次 sweepAll）',
            ),
          if (_bridge.textBodyUnescaped > 0)
            Text(
              '响应体免二次转义：${_bridge.textBodyUnescaped} 次'
              '（约 ${_bridge.textBodyUnescapedBytes}B）'
              '（D5：body 改平级字段回传，省下旧路径「JS 整包转义 + Dart 整包反转义」）',
            ),
          if (_bridge.webViewPreservedOnConfigChange > 0)
            Text(
              'WebView 桥跨配置变更复用：${_bridge.webViewPreservedOnConfigChange} 次'
              '（D6：无关设置版本 bump 不再拆掉隐藏 WKWebView，省下重建 + 重灌 cookie）',
            ),
          if (_bridge.primingDeduped > 0)
            Text(
              '重复 cookie 重灌去抖：${_bridge.primingDeduped} 次'
              '（D7：距上次 prime 不足 2s 的重复 priming 被短路，'
              '省下 O(cookie 数) 次原生 cookie 库往返）',
            ),
          if (_bridge.cookieSweepsSkippedForImage > 0)
            Text(
              '只读图片跳过边界同步：${_bridge.cookieSweepsSkippedForImage} 次'
              '（D8：同源图片只读 cookie，不跑 sweepAll，'
              '省下 O(cookie 数) 次原生 method channel 往返）',
            ),
          if (_bridge.cookieBackSyncDeduped > 0)
            Text(
              '响应侧边界回同步去抖合并：${_bridge.cookieBackSyncDeduped} 次'
              '（D9：写请求不再各自强制全量枚举 WV cookie，'
              '与读请求共用 800ms 去抖窗口，省下全量 getAllCookies 枚举）',
            ),
          if (_bridge.requestBodyInlineSmall > 0)
            Text(
              '小请求体内联：${_bridge.requestBodyInlineSmall} 次'
              '（D10：≤${WebViewBridgeDiagnostics.requestBodyInlineMaxBytes}B 的文本请求体'
              '不再走 base64 整包往返，省下 Dart 编码 + JS atob/Uint8Array.from 逐字节解码）',
            ),
          Text(
            '批量取数：${_bridge.cookieBatchCountCalls} 次调用'
            '覆盖 ${_bridge.cookieBatchCountNames} 个 cookie 名'
            '（预计省 ${_bridge.cookieBatchCountNames - _bridge.cookieBatchCountCalls} 次原生枚举）',
          ),
          Text(
            '变体计数缓存复用：${_bridge.variantCountCacheHits} 次'
            '（D3：同一批 sweep 内复用刚读到的计数，省掉重复的全量枚举）',
          ),
          const Divider(height: 24),
          Text('活跃期桥负载探针（D12）', style: Theme.of(context).textTheme.titleSmall),
          Text(
            '并发峰值：${_probe.concurrencyPeak} 个同时未完成的桥请求'
            '（当前在飞 ${_probe.inFlight}）',
          ),
          Text(
            '桥忙碌占比：${switch (_probe.busyRatio) {
              null => "尚未采样",
              final r => "${(r * 100).toStringAsFixed(0)}%"
                  '（有请求在飞 ${_probe.concurrencySamples} 秒 / 空闲 ${_probe.idleSamples} 秒）',
            }}',
          ),
          Text(
            '平均单次桥请求在飞时长：'
            '${_probe.averageInFlightMs == null ? "尚无完成请求" : "${_probe.averageInFlightMs!.toStringAsFixed(0)}ms"}'
            '（完成 ${_probe.completedRequests} 次，累计 ${_probe.inFlightMs}ms）',
          ),
          Text(
            '活跃期平均并发（D21）：'
            '${_probe.averageActiveConcurrency == null ? "尚未采样" : _probe.averageActiveConcurrency!.toStringAsFixed(2)}'
            ' 个请求同时占用桥'
            '（活跃采样 ${_probe.activeSampledMs}ms，积分 ${_probe.inFlightIntegralMs}ms·个）',
          ),
          const Text(
            '判读：并发峰值高且忙碌占比高 → 桥是活跃期主要 CPU 源，值得做并发限流；'
            '平均在飞时长若远高于原生直连（几十 ms 级），说明每个请求都在付跨语言 + '
            '分块回传的固定税。',
          ),
          OutlinedButton(
            onPressed: () => setState(() {
              _probe.reset();
            }),
            child: const Text('重置活跃期桥负载探针（刷帖前清零）'),
          ),
          const Divider(height: 24),
          Text('桥并发闸门（D13）', style: Theme.of(context).textTheme.titleSmall),
          Text('当前在飞：${_gate.inFlight} / 上限 ${_gate.maxConcurrent} 个桥请求'),
          Text('排队峰值：${_gate.peakWaiting} 个请求曾同时在闸门外等待'),
          Text(
            '累计排队：${_gate.queuedTotal} 次'
            '（这个数字就是闸门实际拦下的并发洪峰规模）',
          ),
          Text(
            '图片加权入桥（D28）：${_gate.weightedAcquires} 次'
            '（图片按权重 ${WebViewBridgeGate.imageWeight} 占槽位，'
            '在飞数已是权重和）',
          ),
          Text(
            '槽位等待量（D31）：${_gate.queuedWeighted}（= 排队请求的权重之和，'
            '与「累计排队 ${_gate.queuedTotal} 次」同量纲对比可看出'
            '排队里大图占多少）',
          ),
          Text(
            '排队耗时归因（D31）：${_bridge.queueAttributionVerdict}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (_bridge.gateSaturationTimeVerdict != null)
            Text(
              '闸门饱和时间占比（D33）：${_bridge.gateSaturationTimeVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          Text(
            '饱和计时（D33）：饱和 ${_gate.saturatedMs}ms'
            ' / 非饱和 ${_gate.unsaturatedMs}ms'
            '（在请求进出桥时各采一次，无定时器）',
          ),
          // D43: 采样密度自检——D33 的饱和占比只在请求进出桥时采样，
          // 空白时间越长，饱和占比越可能被低估，D22 的限流结论越不可信。
          if (_gate.sampleDensityVerdict != null)
            Text(
              _gate.sampleDensityVerdict!,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          Text(
            '采样空白（D43）：${_gate.unobservedGapMs}ms'
            '（两次采样间隔 > ${WebViewBridgeGate.unobservedGapThresholdMs}ms 的部分；'
            '这段没有请求事件，饱和/非饱和是外推的）',
          ),
          Text(
            '端到端桥代价归因（D34）：${_bridge.endToEndAttributionVerdict}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            '端到端桥代价（D34）：合计 ${_bridge.totalEndToEndMs}ms'
            '（图片 ${_bridge.imageSameOriginTotalMs + _bridge.imageOtherTotalMs}ms'
            ' / API ${_bridge.apiGetTotalMs + _bridge.apiWriteTotalMs}ms'
            ' / 其它 ${_bridge.otherTotalMs}ms）；'
            '其中排队占 ${_bridge.queueShareOfEndToEndPct ?? 0}%'
            '（= 端到端里有多少时间卡在闸门外）',
          ),
          if (_probe.activeTimeVerdict != null)
            Text(
              '桥活跃时长占比（D35）：${_probe.activeTimeVerdict}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          Text(
            '活跃/空闲计时（D35）：活跃 ${_probe.activeSampledMs}ms'
            ' / 空闲 ${_probe.idleSampledMs}ms'
            '（采样器每秒按「有/无请求在飞」记一笔，无新增定时器）',
          ),
          Text(
            '流在途修正（D36）：当前仍在回传响应体的二进制流 '
            '${_probe.streamInFlight} 条；'
            '${_probe.streamAwareVerdict ?? "暂无样本"}',
          ),
          const Text(
            '判读：累计排队明显 > 0 且平均在飞时长下降 → 限流生效，'
            '可继续下调上限（4→3→2）找最优；排队为 0 → 活跃期并发本就不高，'
            '限流无收益，转查 CF 刷新重建频率或响应侧序列化。'
            '闸门只在 Dart 侧排队，不挂起 WebView、不阻塞 JS 执行。',
          ),
          Text(
            '限流实验建议（D22）：${_bridge.gateTuningVerdict}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            '运行时并发上限（D22 A/B）：'
            '${WebViewAdapterSettingsService.instance.gateMaxConcurrent} 个',
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final cap in const [2, 3, 4, 6])
                ChoiceChip(
                  label: Text('$cap'),
                  selected:
                      WebViewAdapterSettingsService
                          .instance
                          .gateMaxConcurrent ==
                      cap,
                  onSelected: (_) => setState(() {
                    WebViewAdapterSettingsService.instance.setGateMaxConcurrent(
                      cap,
                    );
                  }),
                ),
            ],
          ),
          const Text(
            '切换后即生效（无需重出包）：每降一档就少一条同时在飞的跨语言回传链。'
            '刷一轮后看「活跃期平均并发」与发热是否同步下降；'
            '若排队占比明显抬升说明已伤吞吐，回调一档。',
          ),
          OutlinedButton(
            onPressed: () => setState(() {
              _gate.reset();
            }),
            child: const Text('重置桥并发闸门计数'),
          ),
          const Divider(height: 24),
          Text('JS 侧分块合并（D14）', style: Theme.of(context).textTheme.titleSmall),
          Text(
            '原始 chunk：${_bridge.streamRawChunks} 个'
            ' → 合并后跨桥消息：${_bridge.streamCoalescedMessages} 条',
          ),
          Text(
            '省下的跨桥消息：${_bridge.streamMessagesSaved} 条'
            '（每条本都要跨一次 JS↔native 边界 + Dart 回调派发）',
          ),
          const Text(
            '判读：原始 chunk 远多于合并后消息 → 合并生效，活跃刷帖时大图回传的'
            '边界穿越批数被显著压下；两者接近 → 响应 chunk 本就很大（或走 base64 '
            'fallback），合并无收益，转查响应侧序列化。合并只发生在 JS 侧，'
            '不挂起 WebView、不阻塞 JS 执行，字节序与语义完全不变。',
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
          // ── 已读上报（/topics/timings）──
          // 直接回答「刷过的帖子为什么不识别已读」：区分「压根没发」
          // （_inProgress/_cfFrozen 卡死、未登录）与「发了但失败」
          // （CF 403/超时）与「发了也成功」（问题在服务端或游标同步）。
          const Text(
            '已读上报（/topics/timings）',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            '发送 ${_diag.countOf(Ios14DiagnosticEvent.timingsSend)} 次'
            ' / 成功 ${_diag.countOf(Ios14DiagnosticEvent.timingsSuccess)} 次'
            ' / 失败 ${_diag.countOf(Ios14DiagnosticEvent.timingsError)} 次'
            ' / 重试 ${_diag.countOf(Ios14DiagnosticEvent.timingsRetry)} 次',
          ),
          const Text(
            '判读：发送不涨＝压根没发（上报被冻结或未登录）；'
            '发送涨但成功不涨＝请求失败（CF 403/超时）；'
            '发送涨且成功涨＝已上报成功，若仍不识别则问题在服务端或本地游标同步。'
            '需先在设置里开启「聚合诊断」才会计数。',
          ),
          OutlinedButton(
            onPressed: () => setState(() {
              Ios14Diagnostics.instance.reset();
            }),
            child: const Text('重置已读上报计数（刷帖前清零）'),
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
