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
  });
}
