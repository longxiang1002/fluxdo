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
  ///
  /// D28：这是**权重和在飞数**——图片类走桥请求按 [imageWeight] 计，
  /// 其它请求按 1 计。因此该值可能大于「实际请求条数」，含义是
  /// 「当前占用的桥槽位」，与 [maxConcurrent] 同一量纲。
  int get inFlight => _inFlight;

  /// 当前并发上限。
  int get maxConcurrent => _maxConcurrent;

  /// 调整并发上限（诊断页/灰度开关用）。降低时不驱逐已在飞请求，
  /// 只影响后续 [acquire]。
  set maxConcurrent(int value) {
    if (value <= 0) return;
    _maxConcurrent = value;
  }

  /// D28: 图片类走桥请求占用的桥槽位数（权重）。
  ///
  /// 动机（2026-10-13 深夜重定位：活跃刷帖时发热）：
  /// 桥是**单条 JS 线程**上的共享资源，但不同请求的「单位成本」并不相同——
  /// 图片流（同源静态资源）响应体大、经 WebMessageChannel 分块回传的
  /// 回调次数多、在飞时间长；API/文本请求体小、回传快。
  /// 若二者按同一权重抢槽位，活跃滚动时少量大图就会长期占住名额，
  /// 把大量轻量 API 请求挤到队列里，拉长整体在飞时间、抬高 CPU 峰值。
  ///
  /// 因此给图片类请求一个 **>1 的权重**：它一进桥就吃掉多个槽位，
  /// 从而让「同时在飞的大图数」自然下降，削平活跃期 CPU 峰值。
  /// 这仍是**纯 Dart 侧排队**，不碰任何 WebView 挂起/暂停 API，不阻塞 JS。
  ///
  /// 取 2 的依据：图片单请求的跨桥成本约为文本请求的 2 倍量级（体量+分块数），
  /// 权重 2 既能让大图更快触发排队，又不会把图片完全饿死（上限 4 时仍可
  /// 同时跑 2 张图）。可通过诊断页观测 `weightedAcquires` 后再微调。
  static const int imageWeight = 2;

  /// D28: 累计以加权（weight > 1）方式进入桥的请求数（只读，供诊断页展示）。
  ///
  /// 与 [totalRequests] 的区别：后者是桥请求**条数**，本值是其中按
  /// 更高权重占槽位的**条数**（当前即图片类）。用于验证「图片权重是否
  /// 真的在活跃期生效」，纯整数累加，零采样、零新增运行时开销。
  int weightedAcquires = 0;

  /// 排队峰值：曾同时等待进入桥的请求数最大值。
  int peakWaiting = 0;

  /// 累计发生过的「排队等待」次数（即因闸门满而必须等待的请求数）。
  ///
  /// 这个数字就是本闸门实际拦下的并发洪峰规模：
  /// 为 0 说明活跃期并发本就不高，限流无收益；
  /// 明显 > 0 且平均在飞时长下降，说明限流生效。
  int queuedTotal = 0;

  /// D31: 累计「因闸门满而在 Dart 侧排队」的**槽位等待量**（= 等待者权重之和）。
  ///
  /// 动机（2026-10-13 深夜重定位：活跃刷帖时发热）：
  /// [queuedTotal] 只回答「有多少条请求排过队」，但活跃期发热是**CPU 时间**
  /// 问题，而排队造成的 CPU 代价 ≈ 排队请求数 × 它在飞时长。D28 给图片类
  /// 请求权重 2 之后，「条数」与「代价」已经不同量纲：一张大图排队 300ms
  /// 与一个 API 排队 300ms 对 CPU 的影响并不相同。
  ///
  /// 本计数器把等待者按**权重**累加（图片 +2、其它 +1），与 [_inFlight]
  /// 同一量纲，便于诊断页回答「限流到底把多少槽位时间挪到了等待上」。
  /// 纯整数累加，零采样、零新增运行时开销。
  int queuedWeighted = 0;

  int _waiting = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// 与 [_waiters] 一一对应的权重队列（D28）：等待者被转交名额时，
  /// 需要按它自己的权重计入 [_inFlight]。
  final List<int> _waiterWeights = <int>[];

  /// D31: 与 [_waiters] 一一对应的「入队时刻」队列。
  ///
  /// 用于在请求真正进入桥时算出**这次排队等了多久**，并把它按请求类别
  /// 归因（见 [onQueueWait]）。只存 1 个 Stopwatch 引用/等待者，不存
  /// URL、Headers 或正文；空闲期无等待者即无任何对象，零常驻开销。
  final List<Stopwatch> _waiterWatches = <Stopwatch>[];

  /// D31: 排队等待结束（请求即将进入桥）时的回调，参数为等待毫秒数。
  ///
  /// 由调用方（桥适配器）设置，用来把「排队时间」按请求类别归因。
  /// 设为 null 即关闭归因，闸门本身不依赖它，也不因它抛错而中断放行。
  void Function(int waitedMs)? onQueueWait;

  /// D31: 当前正在等待进入桥的请求数（只读，供诊断页展示）。
  int get waiting => _waiting;

  /// 申请一个桥名额。返回的 Future 完成时即表示可以进入桥。
  ///
  /// [weight] 为本次请求占用的槽位数（D28）：图片类走桥请求传
  /// [imageWeight]（=2），其它请求用默认值 1。权重只影响「是否放行」的
  /// 判定与 [_inFlight] 的累加口径，**不改变排队语义**——超限的请求仍在
  /// Dart 侧 FIFO 等待，名额释放后按顺序转交。
  ///
  /// 注意：调用方**必须**在 `finally` 里以**相同 weight** 调用 [release]，
  /// 否则名额泄漏。
  Future<void> acquire({int weight = 1}) {
    final w = weight < 1 ? 1 : weight;
    // 判定用「已占槽位 + 本次权重」是否超上限，避免大权重请求把在飞数
    // 顶穿上限（例如上限 4、已占 3 时，权重 2 的图片不应被放行）。
    if (_inFlight + w <= _maxConcurrent) {
      _inFlight += w;
      if (w > 1) weightedAcquires++;
      return Future<void>.value();
    }
    _waiting++;
    if (_waiting > peakWaiting) {
      peakWaiting = _waiting;
    }
    queuedTotal++;
    // D31: 与条数分开累加「槽位等待量」，供诊断页衡量限流的真实代价。
    queuedWeighted += w;
    final completer = Completer<void>();
    _waiters.add(completer);
    _waiterWeights.add(w);
    _waiterWatches.add(Stopwatch()..start());
    return completer.future;
  }

  /// D31: 结算一次排队等待：停表、回调等待毫秒数。
  ///
  /// 只在「确实排过队」的请求上调用（即 [acquire] 返回的 Future 曾被挂起）。
  /// 回调异常被吞掉，绝不影响名额放行。
  void _settleQueueWait(Stopwatch? watch) {
    if (watch == null) return;
    watch.stop();
    final cb = onQueueWait;
    if (cb == null) return;
    try {
      cb(watch.elapsedMilliseconds);
    } catch (_) {
      // 归因失败不影响桥行为。
    }
  }

  /// 释放一个桥名额，并按 FIFO 唤醒能放下的队首等待者。
  ///
  /// [weight] 必须与对应 [acquire] 的 weight 一致，否则槽位计数会漂移。
  ///
  /// D28 语义修正：旧实现「名额转交、[_inFlight] 不变」只在权重恒为 1 时
  /// 成立。引入权重后必须改为「先扣减释放者的权重，再让队首等待者按
  /// **它自己的权重**重新占用槽位」——若扣减后仍放不下队首（例如释放的是
  /// 权重 1 的 API、队首是权重 2 的图片），则队首继续等待，不做部分放行。
  void release({int weight = 1}) {
    final w = weight < 1 ? 1 : weight;
    _inFlight -= w;
    if (_inFlight < 0) _inFlight = 0;
    // 循环唤醒：一次释放可能让多个轻量等待者依次进入。
    while (_waiters.isNotEmpty) {
      final nextWeight = _waiterWeights.first;
      if (_inFlight + nextWeight > _maxConcurrent) break;
      final next = _waiters.removeAt(0);
      _waiterWeights.removeAt(0);
      final nextWatch = _waiterWatches.removeAt(0);
      _waiting--;
      _inFlight += nextWeight;
      if (nextWeight > 1) weightedAcquires++;
      // D31: 先结算排队时长（归因），再放行——保证归因在请求真正开始前完成。
      _settleQueueWait(nextWatch);
      if (!next.isCompleted) {
        next.complete();
      }
    }
  }

  /// 诊断页重置时调用：清空计数。
  ///
  /// 不丢弃等待者（丢弃会让它们永久挂起），只重置统计量。
  void reset() {
    peakWaiting = 0;
    queuedTotal = 0;
    queuedWeighted = 0;
    weightedAcquires = 0;
  }

  /// 仅用于测试：把内部状态置回初值。
  @visibleForTesting
  void resetAllForTest() {
    _inFlight = 0;
    _waiting = 0;
    peakWaiting = 0;
    queuedTotal = 0;
    queuedWeighted = 0;
    weightedAcquires = 0;
    for (final w in _waiters) {
      if (!w.isCompleted) {
        w.complete();
      }
    }
    _waiters.clear();
    _waiterWeights.clear();
    _waiterWatches.clear();
  }
}
