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
      final fImage1 = gate.acquire(weight: 2); // inFlight 2，weighted=1
      final fApi1 = gate.acquire(weight: 1); // inFlight 3
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
}
