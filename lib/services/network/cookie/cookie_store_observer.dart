import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../adapters/webview_bridge_diagnostics.dart';
import 'session_cookie_sentinel.dart';

/// 监听 WV cookie store 的外部变化,触发 sweep。
///
/// 设计依据: docs/cookie-sync-design-v0.4.0.md §5.5 (Phase B)
///
/// 工作流:
/// 1. macOS/iOS native 端注册 `WKHTTPCookieStoreObserver`,
///    cookie 变化时通过 channel `com.fluxdo/cookie_observer` 推送
///    `onCookiesChanged` 事件
/// 2. 本服务监听该事件,debounce 500ms 后对所有已知 url 跑 sweepAll
/// 3. native 端在我们自己 setCookie/delete 时通过 internalWriteCount
///    抑制通知, 避免 sweep → setCookie → 又通知 → sweep 死循环
///
/// 已知 url 由 [registerUrl] 维护 (通常在 Priming 时 register)。
class CookieStoreObserver {
  CookieStoreObserver._();
  static final CookieStoreObserver instance = CookieStoreObserver._();

  static const _channel = MethodChannel('com.fluxdo/cookie_observer');
  static const Duration _debounceWindow = Duration(milliseconds: 500);

  bool _attached = false;
  Timer? _debounce;
  final Set<String> _knownUrls = {};

  /// D4: 收到外部 cookie 变化后，到下一位点之间最多等多久才真正 sweep。
  ///
  /// 动机（活跃刷帖发热）：此前 `cookiesDidChange` 一到就把
  /// `cookieBoundarySynced` 置 false，于是**下一个走桥请求**在自身请求路径上
  /// 同步跑一次 `sweepAll`（O(cookie 数) 次原生 `getAllCookies` 全量枚举 +
  /// 跨语言往返），即使那次变化只是 CF 轮换/服务端下发的一枚新 cookie、
  /// 根本不需要在请求路径上立刻收敛。刷帖时 CF 会持续下发 cookie，等于
  /// 每个请求都背着一次边界同步。
  ///
  /// 这里改为「延后同步」：变化只把状态标记为「待同步」，由已在跑的
  /// 500ms debounce（[notifyExternalChange] / native 事件共用）在**请求路径
  /// 之外**完成一次 sweep；期间到达的走桥请求直接跳过同步（与 D2 的
  /// 「已同步即跳过」同一语义，只是把「已同步」的判定从「被变化立刻作废」
  /// 改成「由 debounce 统一收敛」）。收敛窗口即 [_debounceWindow]，
  /// 不再单独定义常量（原 `_resyncWindow` 从未被引用，已移除）。
  ///
  /// 正确性：sweep 本就是最终一致的兜底，延后一个 debounce 窗口不改变
  /// 任何同步/删除语义；窗口内到达的请求用到的仍是 jar↔WV 已就绪的
  /// cookie 集（priming 幂等保证），只是不在这条请求路径上做去重。

  /// native observer 支持的平台 (macOS / iOS)。
  ///
  /// Android 走 [notifyExternalChange] 由 WV onLoadStop 等 hook 主动触发。
  /// 其它平台 (Windows/Linux) 暂不支持,本服务无操作。
  bool get hasNativeObserver => io.Platform.isMacOS || io.Platform.isIOS;

  /// 启动监听。幂等,重复调用安全。
  ///
  /// Apple 平台会绑定 native `WKHTTPCookieStoreObserver` 通过 channel 通知;
  /// 其它平台依靠 [notifyExternalChange] 主动触发。
  void attach() {
    if (_attached) return;
    _attached = true;
    if (hasNativeObserver) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
    debugPrint(
      '[CookieObserver] attached on ${io.Platform.operatingSystem} '
      '(nativeObserver=$hasNativeObserver)',
    );
  }

  /// 由 Dart 端主动触发 (例如 WV onLoadStop / Android cookie 变化推测点)。
  ///
  /// 与 native observer 共享 debounce timer, 因此 Apple 平台同时由两端
  /// 触发也只会 sweep 一次 (debounce 内)。
  void notifyExternalChange() {
    _onCookiesChanged();
  }

  /// 注册一个 url, 后续 cookie change 事件会对这个 url 跑 sweepAll。
  ///
  /// 通常在 Priming 时调用 (priming 的 url 就是 WV 主域)。
  void registerUrl(String url) {
    if (url.isEmpty) return;
    _knownUrls.add(url);
  }

  /// 仅测试用。
  @visibleForTesting
  void resetForTest() {
    _debounce?.cancel();
    _debounce = null;
    _knownUrls.clear();
    _attached = false;
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onCookiesChanged') {
      _onCookiesChanged();
    }
    return null;
  }

  void _onCookiesChanged() {
    _debounce?.cancel();
    // D4: 只标记「待同步」，不在请求路径上立即失效边界同步状态。
    // 真正的 sweep 交给下面的 debounce 在请求路径之外完成。
    WebViewBridgeDiagnostics.instance.markResyncPending();
    _debounce = Timer(_debounceWindow, _doSweep);
  }

  Future<void> _doSweep() async {
    final urls = _knownUrls.toList(growable: false);
    // D4: 无论是否有已知 url，debounce 到期即视为「已收敛」——清掉待同步
    // 标记，让后续走桥请求恢复「已同步即跳过」的快路径。
    WebViewBridgeDiagnostics.instance.clearResyncPending();
    if (urls.isEmpty) return;
    debugPrint(
      '[CookieObserver] external cookie change detected, sweepAll for $urls',
    );
    for (final url in urls) {
      try {
        final results = await SessionCookieSentinel.instance.sweepAll(url);
        final mismatch = results
            .where(
              (r) => r.variantsBefore != r.variantsAfter || r.variantsAfter > 1,
            )
            .toList();
        if (mismatch.isNotEmpty) {
          debugPrint(
            '[CookieObserver] sweepAll($url) handled ${mismatch.length} cookies: $mismatch',
          );
        }
      } catch (e) {
        debugPrint('[CookieObserver] sweepAll($url) failed: $e');
      }
    }
  }
}
