import 'dart:async';

import 'package:flutter/foundation.dart';

// 注：此处仅文档注释里以 [WebViewBridgeDiagnostics] 交叉引用，未实际使用其符号，
// 故不 import（避免与 diagnostics 反向引用本类形成循环 import）。

/// D12: WebView 桥「活跃期」探针——只统计，不改变任何请求行为。
///
/// 动机（活跃刷帖发热，2026-10-13 老板实测：装 test-48 后**空闲**不热、
/// **刷一会**仍发热严重）：
/// 此前 D1 的 [WebViewBridgeDiagnostics] 只能给出「走桥请求总数 / 字节量 /
/// 累计耗时」这类**总量**画像，无法回答两个关键问题：
///   1. 活跃刷帖时，桥是「持续并发」还是「偶尔突发」？（决定并发限流值不值得做）
///   2. 桥的**单次请求平均耗时**是多少？如果均值远高于原生直连（几十 ms），
///      说明每个请求都在付跨语言 + 分块回传的固定税，这才是活跃发热的主因。
///
/// 本探针把这两点压成 O(1) 整数：
///   - `concurrencyPeak`：活跃期同时未完成的桥请求峰值；
///   - `concurrencySamples`：活跃期「有请求在飞」的采样次数（用于算
///     `busyRatio`，即刷帖时桥到底有多忙）；
///   - `inFlightMs`：所有请求「在飞时长」之和（除以请求数 = 平均耗时）。
///
/// 设计约束（与项目其它诊断一致）：
/// - **常开但零日志**：只有整数加减，不落盘、不逐请求打印，激活态开销可忽略；
/// - 不记录 URL / Headers / 正文，无账户内容；
/// - 不触碰任何 WebView 挂起 / 暂停 API，不阻塞 JS 执行（硬性禁令）。
class WebViewBridgeProbe {
  WebViewBridgeProbe._();

  static final WebViewBridgeProbe instance = WebViewBridgeProbe._();

  /// 活跃期同时未完成的桥请求峰值。
  int concurrencyPeak = 0;

  /// 活跃期「有请求在飞」的采样次数。
  int concurrencySamples = 0;

  /// 所有桥请求「在飞时长」之和（毫秒），除以请求数即平均耗时。
  int inFlightMs = 0;

  /// 完成过的桥请求数（与 [inFlightMs] 配对算均值）。
  int completedRequests = 0;

  /// D21: 活跃期「在飞请求数 × 时间」的积分（毫秒·个）。
  ///
  /// 动机（活跃刷帖发热，2026-10-13 老板实测仍热）：D12 的并发采样此前只在
  /// **有请求在飞**时每秒 +1，因此 `busyRatio` 恒等于 100%，无法回答「刷帖时
  /// 桥到底有多忙、并发有多高」。活跃发热恰恰是**持续并发**的症状，需要一个
  /// 能反映「活跃期平均同时有多少请求占着桥」的指标。
  ///
  /// 本积分在采样器运行期间（即有请求在飞时）每秒累加当前在飞数，
  /// 除以 [activeSampledMs] 即得**活跃期平均并发**。纯整数累加，
  /// 只在活跃期发生，空闲零开销；不触碰任何 WebView 挂起/暂停 API。
  int inFlightIntegralMs = 0;

  /// D21: 采样器处于「活跃期」的累计时长（毫秒），与 [inFlightIntegralMs] 配对。
  int activeSampledMs = 0;

  /// D35: 采样器处于「空闲期」的累计时长（毫秒）——采样器在跑但这一秒没有
  /// 请求在飞。
  ///
  /// 动机（2026-10-13 深夜重定位：活跃刷帖时发热）：
  /// D21 只算了「活跃期平均并发」，但**活跃期本身占了多少时间**从未被测量。
  /// 若刷帖时桥几乎一直有请求在飞（活跃占比高），说明负载是**持续**的，
  /// 降低单请求开销（D16/D17）才有意义；若活跃占比很低（大量空闲间隙），
  /// 说明发热更可能来自「每次活跃的启停抖动」（采样器反复启停、WebView
  /// 空闲后被唤醒），优化方向应转向减少启停次数而非单请求耗时。
  ///
  /// 与 [activeSampledMs] 配对，二者之和即采样器运行的总时长。
  /// 纯整数累加，只在采样器运行期间发生，空闲零开销；不触碰任何
  /// WebView 挂起/暂停 API，不阻塞 JS。
  int idleSampledMs = 0;

  int _inFlight = 0;
  Timer? _sampler;
  Stopwatch? _activeWatch;

  /// 采样周期：1s。仅在「有请求在飞」时启动，归零即停。
  static const Duration sampleInterval = Duration(seconds: 1);

  /// 请求进入桥（fetch 开始）时调用。
  void onRequestStart() {
    _inFlight++;
    if (_inFlight > concurrencyPeak) {
      concurrencyPeak = _inFlight;
    }
    _ensureSampler();
  }

  /// 请求离开桥（成功/失败/取消）时调用。[inFlight] 为该请求在飞时长。
  void onRequestEnd(Duration inFlight) {
    if (_inFlight > 0) {
      _inFlight--;
    }
    inFlightMs += inFlight.inMilliseconds;
    completedRequests++;
    if (_inFlight == 0) {
      _stopSampler();
    }
  }

  /// 当前在飞请求数（只读，供诊断页展示）。
  int get inFlight => _inFlight;

  /// 活跃期「桥有多忙」：有请求在飞的采样次数 / 总采样次数。
  /// 无采样时返回 null（尚未观测到任何桥活动）。
  double? get busyRatio {
    final total = concurrencySamples + idleSamples;
    if (total == 0) return null;
    return concurrencySamples / total;
  }

  /// 活跃期「桥空闲」的采样次数（有采样器在跑但这一秒没有请求在飞）。
  int idleSamples = 0;

  /// 平均单次桥请求耗时（毫秒）；无完成请求时返回 null。
  double? get averageInFlightMs {
    if (completedRequests == 0) return null;
    return inFlightMs / completedRequests;
  }

  /// D21: 活跃期平均同时占用桥的请求数（并发度）；无活跃采样时返回 null。
  ///
  /// 这是活跃发热最直接的画像：值明显 > 1 说明活跃刷帖时桥是**持续并发**的，
  /// 单条 JS 线程被多个请求轮转，CPU 花在跨语言调用与分块回传的反复切换上。
  double? get averageActiveConcurrency {
    if (activeSampledMs <= 0) return null;
    return inFlightIntegralMs / activeSampledMs;
  }

  void _ensureSampler() {
    if (_sampler != null) return;
    // D21: 活跃期计时与积分只在采样器运行期间累加（即确实有请求在飞时）。
    _activeWatch = Stopwatch()..start();
    _sampler = Timer.periodic(sampleInterval, (_) {
      if (_inFlight > 0) {
        concurrencySamples++;
        // D21: 每秒把当前在飞数积进总分（时间 × 并发度）。
        inFlightIntegralMs += _inFlight * sampleInterval.inMilliseconds;
      } else {
        idleSamples++;
        // D35: 这一秒没有请求在飞——把整秒记到空闲期，与活跃期配对。
        idleSampledMs += sampleInterval.inMilliseconds;
      }
    });
  }

  void _stopSampler() {
    _sampler?.cancel();
    _sampler = null;
    final watch = _activeWatch;
    if (watch != null) {
      watch.stop();
      // D21: 结算本段活跃时长（可能不足一个采样周期，仍按实际毫秒计）。
      activeSampledMs += watch.elapsedMilliseconds;
      _activeWatch = null;
    }
  }

  /// D35: 采样器运行的总时长（毫秒）= 活跃期 + 空闲期。
  int get sampledTotalMs => activeSampledMs + idleSampledMs;

  /// D35: 桥「活跃时长占比」（0~100 的整数百分比）；无样本返回 null。
  ///
  /// 这是「活跃刷帖时桥到底有多忙」的时间维度答案：占比高（如 >80%）
  /// 说明刷帖期间桥几乎一直在工作，发热是**持续负载**造成的，应继续
  /// 削单请求开销；占比低说明活跃是**间歇**的，发热更可能来自启停抖动，
  /// 应转向减少启停次数。纯派生、零采样、零新增运行时开销。
  int? get activeTimeSharePct {
    final total = sampledTotalMs;
    if (total <= 0) return null;
    return (activeSampledMs * 100 / total).round();
  }

  /// D35: 活跃时长占比速判——回答「活跃刷帖时桥是持续忙还是间歇忙」。
  ///
  /// 判据只用已聚合整数，纯派生、零采样、零新增运行时开销。返回 `null`
  /// 表示样本不足。
  String? get activeTimeVerdict {
    final pct = activeTimeSharePct;
    if (pct == null) return null;
    final head =
        '桥活跃时长占比（D35）：活跃 $activeSampledMs ms / '
        '空闲 $idleSampledMs ms，活跃占 $pct%。';
    if (pct >= 80) {
      return '$head **桥几乎一直在忙**——活跃刷帖时负载是持续的，'
          '发热来自单请求开销的累积；下一步继续削单请求成本'
          '（D16/D17 三段耗时、D3 避免 base64 回退）。';
    }
    if (pct >= 40) {
      return '$head **桥忙闲参半**——负载呈脉冲式；'
          '可在削单请求开销的同时，评估把同源图片继续分流原生（D2/D19）'
          '以拉低每个脉冲的高度。';
    }
    return '$head **桥大部分时间空闲**——活跃是间歇性的，'
        '发热更可能来自每次活跃的启停抖动（采样器反复启停、WebView 唤醒），'
        '下一步转向减少启停次数（合并请求、拉长空闲判定窗口）。';
  }

  /// 诊断页重置时调用：清空计数并停表。
  void reset() {
    _stopSampler();
    concurrencyPeak = 0;
    concurrencySamples = 0;
    idleSamples = 0;
    inFlightMs = 0;
    completedRequests = 0;
    inFlightIntegralMs = 0;
    activeSampledMs = 0;
    idleSampledMs = 0;
    _inFlight = 0;
  }

  /// 仅用于测试：把内部在飞计数置回初值（不触碰统计量）。
  @visibleForTesting
  void resetInFlightForTest() {
    _stopSampler();
    _inFlight = 0;
  }
}
