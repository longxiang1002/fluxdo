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
  });
}
