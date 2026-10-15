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
}
