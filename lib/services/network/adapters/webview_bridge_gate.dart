import 'dart:async';

import 'package:flutter/foundation.dart';

/// D13: WebView 桥并发闸门——把「同时在飞的桥请求数」限到一个有界值。
///
/// 动机（活跃刷帖发热，2026-10-13 老板实测：装 test-48 后**空闲**不热、
/// **刷一会**仍发热严重）：
/// 桥是**共享资源**——单个隐藏 WKWebView、单条 JS 线程。每个走桥请求都要付
/// 「拼 JS 脚本 → evaluateJavascript 跨语言 → fetch → 响应经
/// WebMessageChannel 分块 / base64 回传 Dart」这套固定税。
///
/// 活跃滚动刷帖时，图片与 API 请求会**同时**涌入。无上限并发并不会让总吞吐更高：
/// - 所有请求挤在一条 JS 线程上互相排队，每个都在飞更久；
/// - 每个在飞请求都持有桥回调与分块缓冲，CPU 峰值叠加；
/// - 上下文切换与分块回调次数随并发数增长 → 总 CPU 时间不减反增。
///
/// 因此给桥加一个**有界信号量**：超出的请求在 Dart 侧排队等待，
/// 而不是一起涌进 WebView。
///
/// 设计约束（与项目其它诊断/限流一致）：
/// - **不阻塞 JS 执行**：等待发生在 Dart 侧 `Completer` 队列上，
///   不碰任何 WebView 挂起/暂停 API（硬性禁令），不引入滚动挂起；
/// - **空闲零开销**：无等待者时不创建 Timer、不轮询；
/// - `release()` 严格配对，调用方在 `finally` 里释放，异常/取消都不漏放；
/// - 只记录整数计数，不记录 URL / Headers / 正文。
class WebViewBridgeGate {
  WebViewBridgeGate({int maxConcurrent = defaultMaxConcurrent})
    : assert(maxConcurrent > 0, 'maxConcurrent 必须为正数'),
      _maxConcurrent = maxConcurrent;

  static final WebViewBridgeGate instance = WebViewBridgeGate();

  /// 默认并发上限。
  ///
  /// 取 4 的依据：活跃刷帖时桥负载以「同源图片 + API GET」为主，
  /// 单条 JS 线程上 4 个并发已足以打满 WebKit 的 fetch 流水线；
  /// 再高只会增加在飞时长与分块回调次数，不提升实际吞吐。
  /// 可通过 [maxConcurrent] 调整，实测后按诊断页数据微调。
  static const int defaultMaxConcurrent = 4;

  int _maxConcurrent;
  int _inFlight = 0;

  /// 当前在飞的桥请求数（只读，供诊断页展示）。
  int get inFlight => _inFlight;

  /// 当前并发上限。
  int get maxConcurrent => _maxConcurrent;

  /// 调整并发上限（诊断页/灰度开关用）。降低时不驱逐已在飞请求，
  /// 只影响后续 [acquire]。
  set maxConcurrent(int value) {
    if (value <= 0) return;
    _maxConcurrent = value;
  }

  /// 排队峰值：曾同时等待进入桥的请求数最大值。
  int peakWaiting = 0;

  /// 累计发生过的「排队等待」次数（即因闸门满而必须等待的请求数）。
  ///
  /// 这个数字就是本闸门实际拦下的并发洪峰规模：
  /// 为 0 说明活跃期并发本就不高，限流无收益；
  /// 明显 > 0 且平均在飞时长下降，说明限流生效。
  int queuedTotal = 0;

  int _waiting = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// 申请一个桥名额。返回的 Future 完成时即表示可以进入桥。
  ///
  /// 注意：调用方**必须**在 `finally` 里调用 [release]，否则名额泄漏。
  Future<void> acquire() {
    if (_inFlight < _maxConcurrent) {
      _inFlight++;
      return Future<void>.value();
    }
    _waiting++;
    if (_waiting > peakWaiting) {
      peakWaiting = _waiting;
    }
    queuedTotal++;
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  /// 释放一个桥名额。若有等待者，名额直接转交（不经过 _inFlight 归零）。
  void release() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      _waiting--;
      // 名额转交：_inFlight 保持不变。
      if (!next.isCompleted) {
        next.complete();
      }
      return;
    }
    if (_inFlight > 0) {
      _inFlight--;
    }
  }

  /// 诊断页重置时调用：清空计数。
  ///
  /// 不丢弃等待者（丢弃会让它们永久挂起），只重置统计量。
  void reset() {
    peakWaiting = 0;
    queuedTotal = 0;
  }

  /// 仅用于测试：把内部状态置回初值。
  @visibleForTesting
  void resetAllForTest() {
    _inFlight = 0;
    _waiting = 0;
    peakWaiting = 0;
    queuedTotal = 0;
    for (final w in _waiters) {
      if (!w.isCompleted) {
        w.complete();
      }
    }
    _waiters.clear();
  }
}
