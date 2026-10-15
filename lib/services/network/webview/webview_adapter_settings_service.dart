import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../constants.dart';
import '../adapters/webview_bridge_gate.dart';

/// WebView 适配器设置服务
///
/// 开启后，主站 API 请求通过 WebView 内核发送（真正的 Chrome TLS 指纹），
/// 可改善因 TLS 指纹被 Cloudflare 识别为非浏览器客户端导致的登录失效问题。
///
/// 仅对主域名的 API 请求生效，排除：
/// - CDN 图片请求（cdn.linux.do 等子域名）
/// - MessageBus 长轮询（/message-bus/ 路径）
class WebViewAdapterSettingsService {
  WebViewAdapterSettingsService._internal();

  static final WebViewAdapterSettingsService instance =
      WebViewAdapterSettingsService._internal();

  static const _enabledKey = 'webview_adapter_enabled';

  /// D24：同源图片分流开关的持久化键。
  ///
  /// 动机：D19/D22 把两个 A/B 开关做成运行时可选，但只存在内存里——
  /// 实机刷帖对比发热时若中途重启 App（TrollStore 覆盖装、崩溃、手动杀），
  /// 开关会静默回落到默认值，A/B 数据就废了。落盘后实验状态可跨重启保持，
  /// 也便于出包后一次性把结论固化。
  static const _imageNativeRoutingKey = 'webview_image_native_routing';

  /// D24：桥并发上限的持久化键。
  static const _gateMaxConcurrentKey = 'webview_gate_max_concurrent';

  /// 用户持久化的兼容模式开关。
  ///
  /// 设置页只监听这个 notifier，避免把 CF 恢复流程启用的临时兼容模式
  /// 误显示成用户主动修改的永久设置。
  final ValueNotifier<bool> notifier = ValueNotifier(false);

  /// 当前会话的临时兼容模式开关，不写入 SharedPreferences。
  final ValueNotifier<bool> sessionFallbackNotifier = ValueNotifier(false);

  /// 实际用于请求分流的开关。
  ///
  /// 持久化兼容模式或会话临时兼容模式任一开启时均为 true。
  final ValueNotifier<bool> effectiveNotifier = ValueNotifier(false);

  /// D2：同源静态图片是否分流到原生 Dio 直连（默认开启）。
  ///
  /// 这是活跃刷帖时体量最大的走桥负载（图片经 JS fetch + 分块跨桥回传），
  /// 分流到原生栈可显著削减桥负载。默认 true；若实测 CF 403/拦截率升高，
  /// 可在诊断页一键切回「同源图片走桥」做 A/B，无需改代码。
  /// 仅影响 `resourceKindImage` 分流分支，不动 API/写请求的桥路由。
  final ValueNotifier<bool> imageNativeRoutingNotifier = ValueNotifier(true);

  /// 当前同源图片是否走原生 Dio 直连。
  bool get imageNativeRoutingEnabled => imageNativeRoutingNotifier.value;

  /// 设置同源图片分流开关（诊断页 A/B 试验用，运行时可切换）。
  ///
  /// D24：同时落盘，重启后仍保持该实验档位。
  void setImageNativeRouting(bool value) {
    imageNativeRoutingNotifier.value = value;
    unawaited(_prefs?.setBool(_imageNativeRoutingKey, value));
  }

  /// D22：桥并发闸门上限的运行时 A/B 开关（默认 4，与 D13 初值一致）。
  ///
  /// 动机（2026-10-13 深夜重定位）：D20/D21 已能判「限流值不值得做」，
  /// 但判完还得改代码 + 重出包才能试。这里把上限做成**运行时可选**，
  /// 老板在诊断页一键切 4→3→2，刷一轮就能对比活跃期平均并发与发热，
  /// 无需每档都等一次 CI 出包。
  ///
  /// 只影响 [WebViewBridgeGate.maxConcurrent]，不动任何 WebView 挂起/暂停
  /// API，也不改变请求语义（只是让超出的请求在 Dart 侧 Completer 队列上
  /// 多等一会儿，不阻塞 JS 执行）。
  final ValueNotifier<int> gateMaxConcurrentNotifier = ValueNotifier(
    WebViewBridgeGate.defaultMaxConcurrent,
  );

  /// 当前桥并发上限。
  int get gateMaxConcurrent => gateMaxConcurrentNotifier.value;

  /// 设置桥并发上限（诊断页 A/B 试验用，运行时即切即生效）。
  ///
  /// 下限保护为 1：0 会让所有走桥请求永久排队（闸门永不释放名额）。
  /// D24：同时落盘，重启后仍保持该实验档位。
  void setGateMaxConcurrent(int value) {
    if (value < 1) return;
    gateMaxConcurrentNotifier.value = value;
    WebViewBridgeGate.instance.maxConcurrent = value;
    unawaited(_prefs?.setInt(_gateMaxConcurrentKey, value));
  }

  SharedPreferences? _prefs;

  /// 用户持久化设置是否开启。
  bool get enabled => notifier.value;

  bool get persistentEnabled => notifier.value;

  /// 当前会话是否因 CF 恢复流程临时启用了兼容模式。
  bool get sessionFallbackEnabled => sessionFallbackNotifier.value;

  /// 当前请求是否应允许使用 WebView 适配器。
  bool get effectiveEnabled => effectiveNotifier.value;

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    notifier.value = prefs.getBool(_enabledKey) ?? false;
    _syncEffectiveEnabled();
    // D24：恢复上一轮的 A/B 实验档位（未设置过则保持默认 true / 4）。
    imageNativeRoutingNotifier.value =
        prefs.getBool(_imageNativeRoutingKey) ?? true;
    final savedCap = prefs.getInt(_gateMaxConcurrentKey);
    if (savedCap != null && savedCap >= 1) {
      gateMaxConcurrentNotifier.value = savedCap;
      WebViewBridgeGate.instance.maxConcurrent = savedCap;
    }
  }

  Future<void> setEnabled(bool value) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = value;
    _syncEffectiveEnabled();
    await prefs.setBool(_enabledKey, value);
  }

  /// 仅在当前应用会话启用临时兼容模式。
  void enableSessionFallback() {
    _setSessionFallbackEnabled(true);
  }

  /// 退出当前会话的临时兼容模式。
  void disableSessionFallback() {
    _setSessionFallbackEnabled(false);
  }

  /// 在登录会话结束时清除临时兼容状态。
  ///
  /// 该操作不会修改用户持久化的兼容模式设置。
  void resetSessionFallback() {
    _setSessionFallbackEnabled(false);
  }

  /// 判断请求是否应走 WebView 适配器
  bool shouldUseWebView(Uri uri) {
    if (!effectiveEnabled) return false;
    return canUseWebView(uri);
  }

  /// 判断目标地址是否属于 WebView 适配器可覆盖的范围，不考虑当前是否启用。
  bool canUseWebView(Uri uri) {
    final baseHost = Uri.parse(AppConstants.baseUrl).host;
    // 仅主域名（排除 CDN、ping 等子域名）
    if (uri.host != baseHost) return false;
    // 排除 MessageBus 长轮询
    if (uri.path.startsWith('/message-bus/')) return false;
    return true;
  }

  void _setSessionFallbackEnabled(bool value) {
    if (sessionFallbackNotifier.value == value) return;
    sessionFallbackNotifier.value = value;
    _syncEffectiveEnabled();
  }

  void _syncEffectiveEnabled() {
    effectiveNotifier.value = enabled || sessionFallbackEnabled;
  }

  /// 重置单例内部状态，仅用于测试，使 initialize() 可重新执行。
  @visibleForTesting
  void resetForTest() {
    _prefs = null;
    notifier.value = false;
    sessionFallbackNotifier.value = false;
    effectiveNotifier.value = false;
    imageNativeRoutingNotifier.value = true;
    gateMaxConcurrentNotifier.value = WebViewBridgeGate.defaultMaxConcurrent;
  }
}
