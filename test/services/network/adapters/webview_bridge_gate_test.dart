import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_bridge_gate.dart';

void main() {
  group('WebViewBridgeGate', () {
    test('未达上限时立即放行，不排队', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      await gate.acquire();
      await gate.acquire();
      expect(gate.inFlight, 2);
      expect(gate.queuedTotal, 0);
      expect(gate.peakWaiting, 0);
      gate.release();
      gate.release();
      expect(gate.inFlight, 0);
    });

    test('超出上限时排队，release 后按 FIFO 转交名额', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 1);
      await gate.acquire();
      var thirdDone = false;
      final second = gate.acquire();
      final third = gate.acquire().then((_) => thirdDone = true);
      expect(gate.queuedTotal, 2);
      expect(gate.peakWaiting, 2);
      expect(gate.inFlight, 1);

      // 释放一个名额 → 第二个获得，但第三个仍在等。
      gate.release();
      await second;
      expect(thirdDone, isFalse);
      expect(gate.inFlight, 1);

      gate.release();
      await third;
      expect(thirdDone, isTrue);
      gate.release();
      expect(gate.inFlight, 0);
    });

    test('release 在无在飞请求时不把计数压成负数', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      gate.release();
      gate.release();
      expect(gate.inFlight, 0);
    });

    test('reset 只清统计量，不丢弃等待者', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 1);
      await gate.acquire();
      final waiting = gate.acquire();
      expect(gate.queuedTotal, 1);
      gate.reset();
      expect(gate.queuedTotal, 0);
      expect(gate.peakWaiting, 0);
      // 等待者仍在队列里，release 后应被放行。
      gate.release();
      await waiting;
      expect(gate.inFlight, 1);
    });

    test('maxConcurrent setter 拒绝非正值', () {
      final gate = WebViewBridgeGate(maxConcurrent: 3);
      gate.maxConcurrent = 0;
      expect(gate.maxConcurrent, 3);
      gate.maxConcurrent = -1;
      expect(gate.maxConcurrent, 3);
      gate.maxConcurrent = 5;
      expect(gate.maxConcurrent, 5);
    });

    test('D28: 加权请求按权重占槽位，权重和不得顶穿上限', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 3);
      // 图片（权重 2）入桥 → 占 2 个槽位。
      await gate.acquire(weight: WebViewBridgeGate.imageWeight);
      expect(gate.inFlight, 2);
      expect(gate.weightedAcquires, 1);
      // 再来一张图（权重 2）会顶穿上限 3 → 必须排队。
      var secondDone = false;
      final second = gate
          .acquire(weight: WebViewBridgeGate.imageWeight)
          .then((_) => secondDone = true);
      expect(gate.inFlight, 2);
      expect(gate.queuedTotal, 1);
      // 释放第一张图 → 第二张图名额转交，并按它自己的权重计入（+2）。
      gate.release(weight: WebViewBridgeGate.imageWeight);
      await second;
      expect(secondDone, isTrue);
      expect(gate.inFlight, 2);
      expect(gate.weightedAcquires, 2);
      gate.release(weight: WebViewBridgeGate.imageWeight);
      expect(gate.inFlight, 0);
    });

    test('D28: 默认权重请求行为与旧版一致（向后兼容）', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      await gate.acquire();
      await gate.acquire();
      expect(gate.inFlight, 2);
      expect(gate.weightedAcquires, 0);
      gate.release();
      gate.release();
      expect(gate.inFlight, 0);
    });

    test('D30: 活跃滚动图片×API 交错时，槽位计数不漂移、不饿死 API', () async {
      // 模拟活跃刷帖的真实混合负载：上限 3，图片(权重2)与 API(权重1)
      // 交错进入桥。目标是锁定 D28 的权重账本在交错场景下自洽——
      // inFlight 永不越界、全部释放后回到 0、weightedAcquires 恰好等于
      // 图片条数，且轻量 API 在容量放得下时不被队首大图永久饿死。
      final gate = WebViewBridgeGate(maxConcurrent: 3);
      // 第一张图 + 一个 API 立即进桥占满 3 槽；第二张图 + 两个 API 排队。
      // 注：fImage1 / fApi1 立即完成（未排队），此处无需 await，
      // 保留变量名只为标明「这两条已进桥」，故显式忽略未使用告警。
      unawaited(gate.acquire(weight: 2)); // inFlight 2，weighted=1
      unawaited(gate.acquire(weight: 1)); // inFlight 3
      final fImage2 = gate.acquire(weight: 2); // 排队
      final fApi2 = gate.acquire(weight: 1); // 排队
      final fApi3 = gate.acquire(weight: 1); // 排队
      var api3Done = false;
      fApi3.whenComplete(() => api3Done = true);
      expect(gate.inFlight, 3);
      expect(gate.queuedTotal, 3);
      expect(gate.weightedAcquires, 1);

      // 释放 API(权重1)：槽位降到 2，队首 image2(权重2) 放不下 → 不唤醒，
      // 轻量 API 也不被部分放行（保持 FIFO，锁死「不做部分放行」语义）。
      gate.release(weight: 1);
      expect(gate.inFlight, 2);
      expect(gate.queuedTotal, 3);

      // 释放 image1(权重2)：槽位归零，FIFO 唤醒 image2(权重2) → inFlight2，
      // 再唤醒 api2(权重1) → inFlight3；api3 仍排队。
      gate.release(weight: 2);
      await fImage2;
      await fApi2;
      expect(gate.inFlight, 3);
      expect(gate.weightedAcquires, 2);
      expect(api3Done, isFalse, reason: 'api3 仍应排队');
      expect(gate.queuedTotal, 3);

      // 释放 image2(权重2)：唤醒 api3，最后全部释放账本归零。
      gate.release(weight: 2);
      await fApi3;
      expect(gate.inFlight, 2);
      gate.release(weight: 1); // api2
      gate.release(weight: 1); // api3
      expect(gate.inFlight, 0);
      expect(gate.weightedAcquires, 2, reason: '2 张图都按权重进入过桥');
      expect(gate.queuedTotal, 3, reason: '3 个请求真实排队过');
    });
  });

  group('D31 排队等待归因', () {
    test('排队请求结算等待时长并按权重累加槽位等待量', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      final waits = <int>[];
      gate.onQueueWait = waits.add;

      // 占满 2 个槽位。
      await gate.acquire(weight: 1);
      await gate.acquire(weight: 1);
      expect(gate.inFlight, 2);
      expect(gate.waiting, 0);

      // 图片(权重2)进不来 → 排队；槽位等待量按权重 2 累加。
      var imageDone = false;
      final fImage = gate.acquire(weight: 2).then((_) => imageDone = true);
      expect(gate.waiting, 1);
      expect(gate.queuedTotal, 1);
      expect(gate.queuedWeighted, 2);
      expect(imageDone, isFalse);
      expect(waits, isEmpty, reason: '尚未放行，不该结算等待');

      // 释放一个槽位仍放不下权重 2 → 继续等待，不结算。
      gate.release(weight: 1);
      expect(gate.waiting, 1);
      expect(waits, isEmpty);

      // 再释放一个槽位 → 放行图片，结算一次等待。
      gate.release(weight: 1);
      await fImage;
      expect(gate.waiting, 0);
      expect(gate.inFlight, 2);
      expect(waits.length, 1, reason: '放行时结算一次排队时长');
      expect(waits.single, greaterThanOrEqualTo(0));

      gate.release(weight: 2);
      expect(gate.inFlight, 0);
      gate.resetAllForTest();
      gate.onQueueWait = null;
    });

    test('未排队请求不产生等待归因，reset 清空槽位等待量', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 4);
      var calls = 0;
      gate.onQueueWait = (_) => calls++;

      await gate.acquire(weight: 1);
      await gate.acquire(weight: 2);
      expect(calls, 0, reason: '直接放行不排队，零归因');
      expect(gate.queuedWeighted, 0);

      gate.release(weight: 1);
      gate.release(weight: 2);
      gate.reset();
      expect(gate.queuedWeighted, 0);
      expect(gate.queuedTotal, 0);
      gate.resetAllForTest();
      gate.onQueueWait = null;
    });
  });

  group('D33 闸门饱和时间采样', () {
    test('首次采样只建基线，不累加', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      gate.sampleSaturation(1000);
      expect(gate.saturatedMs, 0);
      expect(gate.unsaturatedMs, 0);
      expect(gate.observedMs, 0);
      expect(gate.saturationPct, isNull);
      gate.resetAllForTest();
    });

    test('未饱和区间记到非饱和侧，饱和区间记到饱和侧', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      // 基线：空闸门（非饱和）。
      gate.sampleSaturation(0);
      // 1000ms 后仍空 → 非饱和 1000ms。
      gate.sampleSaturation(1000);
      expect(gate.unsaturatedMs, 1000);
      expect(gate.saturatedMs, 0);

      // 占满 2 个槽位 → 之后进入饱和。
      await gate.acquire(weight: 1);
      await gate.acquire(weight: 1);
      // 2000ms 时采样：距上次 1000ms，此刻在飞=2=上限 → 饱和。
      gate.sampleSaturation(2000);
      expect(gate.saturatedMs, 1000);
      expect(gate.unsaturatedMs, 1000);
      expect(gate.saturationPct, 50);

      gate.release(weight: 1);
      gate.release(weight: 1);
      // 4000ms 时采样：距上次 2000ms，此刻在飞=0 → 非饱和。
      gate.sampleSaturation(4000);
      expect(gate.saturatedMs, 1000);
      expect(gate.unsaturatedMs, 3000);
      expect(gate.saturationPct, 25);
      gate.resetAllForTest();
    });

    test('wouldBlock 只读判定，不改变放行行为', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      expect(gate.wouldBlock(), isFalse);
      expect(gate.wouldBlock(weight: 2), isFalse);
      await gate.acquire(weight: 1);
      expect(gate.wouldBlock(), isFalse, reason: '在飞 1，权重 1 仍放得下');
      expect(gate.wouldBlock(weight: 2), isTrue, reason: '1+2>2，权重 2 放不下');
      await gate.acquire(weight: 1);
      expect(gate.wouldBlock(), isTrue, reason: '已满');
      // wouldBlock 是纯读：在飞数不变。
      expect(gate.inFlight, 2);
      gate.release(weight: 1);
      gate.release(weight: 1);
      expect(gate.inFlight, 0);
      gate.resetAllForTest();
    });

    test('时间未推进或倒流时不累加', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      gate.sampleSaturation(1000);
      gate.sampleSaturation(1000);
      expect(gate.observedMs, 0);
      gate.sampleSaturation(500);
      expect(gate.observedMs, 0);
      gate.resetAllForTest();
    });

    test('reset 清空饱和计时并丢弃采样基线', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      gate.sampleSaturation(0);
      gate.sampleSaturation(1000);
      expect(gate.unsaturatedMs, 1000);
      gate.reset();
      expect(gate.saturatedMs, 0);
      expect(gate.unsaturatedMs, 0);
      expect(gate.saturationPct, isNull);
      // 基线已丢弃：重置后第一次采样不补记「重置前→重置后」的时间。
      gate.sampleSaturation(5000);
      expect(gate.observedMs, 0);
      gate.resetAllForTest();
    });
  });

  group('D43 采样密度（空白时长）自检', () {
    test('间隔未超阈值时不计空白', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      gate.sampleSaturation(0);
      // 间隔 200ms = 阈值，不算「超过」，不计空白。
      gate.sampleSaturation(200);
      expect(gate.unobservedGapMs, 0);
      expect(gate.unobservedGapPct, 0);
      gate.resetAllForTest();
    });

    test('间隔超阈值时整段计入空白，且不破坏总和不变式', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      gate.sampleSaturation(0);
      // 间隔 1000ms > 200ms → 整段 1000ms 计入空白。
      gate.sampleSaturation(1000);
      expect(gate.unobservedGapMs, 1000);
      expect(gate.observedMs, 1000, reason: '饱和 + 非饱和 = 观测总时长');
      expect(gate.unobservedGapPct, 100);
      gate.resetAllForTest();
    });

    test('空白与饱和同源：饱和期无事件时饱和占比被低估', () async {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      // 基线：空闸门（非饱和）。
      gate.sampleSaturation(0);
      // 占满 2 个槽位，然后 1000ms 内没有任何请求事件。
      await gate.acquire(weight: 1);
      await gate.acquire(weight: 1);
      gate.sampleSaturation(1000);
      // 这段被记成「非饱和」（因为采样时刻闸门已满，但归因用的是
      // 「距上次采样这段时间」——上次采样时闸门是空的）。
      // 这正是 D43 要暴露的偏差来源：空白占比高 → 结论不可信。
      expect(gate.unobservedGapMs, 1000);
      expect(gate.unobservedGapPct, 100);
      final verdict = gate.sampleDensityVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('采样过稀'));
      expect(verdict, contains('可能被系统性低估'));
      gate.release(weight: 1);
      gate.release(weight: 1);
      gate.resetAllForTest();
    });

    test('采样密集时判为可信', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      gate.sampleSaturation(0);
      // 每 100ms 采一次，共 10 次 → 空白 0。
      for (var i = 1; i <= 10; i++) {
        gate.sampleSaturation(i * 100);
      }
      expect(gate.unobservedGapMs, 0);
      final verdict = gate.sampleDensityVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('采样密度**良好**'));
      gate.resetAllForTest();
    });

    test('空白占比中等时给出谨慎解读', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      gate.sampleSaturation(0);
      // 密集段：每 100ms 采一次，共 8 次 → 800ms 无空白。
      for (var i = 1; i <= 8; i++) {
        gate.sampleSaturation(i * 100);
      }
      // 再一段 400ms 空白 → 空白 400 / 观测 1200 ≈ 33%，落在 20~50 之间。
      gate.sampleSaturation(1200);
      final gapPct = gate.unobservedGapPct;
      expect(gapPct, isNotNull);
      expect(gapPct! >= 20 && gapPct < 50, isTrue, reason: '实际 $gapPct%');
      final verdict = gate.sampleDensityVerdict;
      expect(verdict, contains('采样密度**中等**'));
      gate.resetAllForTest();
    });

    test('reset 同时清空空白计时', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      gate.sampleSaturation(0);
      gate.sampleSaturation(1000);
      expect(gate.unobservedGapMs, 1000);
      gate.reset();
      expect(gate.unobservedGapMs, 0);
      expect(gate.unobservedGapPct, isNull);
      gate.resetAllForTest();
    });

    test('无样本时返回 null，不冒充结论', () {
      final gate = WebViewBridgeGate(maxConcurrent: 2);
      expect(gate.sampleDensityVerdict, isNull);
      expect(gate.unobservedGapPct, isNull);
      gate.resetAllForTest();
    });
  });
}
