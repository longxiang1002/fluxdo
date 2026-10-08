import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'system_proxy_detector.dart';

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
  String? get effectiveProxyUrl {
    _ensureStarted();
    return _effectiveProxyUrl;
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

  @visibleForTesting
  void resetForTest() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _started = false;
    _effectiveProxyUrl = null;
    _lastConfig = const SystemProxyConfig();
  }
}
