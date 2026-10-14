import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_bridge_diagnostics.dart';

void main() {
  late WebViewBridgeDiagnostics stats;

  setUp(() {
    stats = WebViewBridgeDiagnostics.instance;
    stats.reset();
  });

  tearDown(() {
    stats.reset();
  });

  test('D14 合并统计：省下的跨桥消息数 = 原始 chunk - 实际消息', () {
    stats.streamRawChunks += 40;
    stats.streamCoalescedMessages += 5;
    expect(stats.streamMessagesSaved, 35);
  });

  test('D14 合并统计：消息数不少于原始 chunk 时不报负数', () {
    stats.streamRawChunks += 3;
    stats.streamCoalescedMessages += 3;
    expect(stats.streamMessagesSaved, 0);

    stats.streamRawChunks = 0;
    stats.streamCoalescedMessages = 4;
    expect(stats.streamMessagesSaved, 0);
  });

  test('D14 合并统计：reset 清零', () {
    stats.streamRawChunks += 10;
    stats.streamCoalescedMessages += 2;
    stats.reset();
    expect(stats.streamRawChunks, 0);
    expect(stats.streamCoalescedMessages, 0);
    expect(stats.streamMessagesSaved, 0);
  });

  group('D15 活跃发热归因速判', () {
    test('无走桥请求时不冒充结论', () {
      expect(stats.activeLoadVerdict, isNull);
    });

    test('图片分流多于走桥且字节小 → 判为桥负载已瘦身', () {
      stats.imageRoutedNative = 20;
      stats.imageSameOrigin = 2;
      stats.apiGet = 5;
      stats.textResponseBytes = 512 * 1024;
      final verdict = stats.activeLoadVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('桥负载已瘦身'));
    });

    test('图片字节占桥总量过半 → 判为图片主导', () {
      stats.imageSameOrigin = 10;
      stats.imageRoutedNative = 1;
      stats.streamResponseBytes = 4 * 1024 * 1024;
      stats.imageResponseBytes = 3 * 1024 * 1024;
      final verdict = stats.activeLoadVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('图片主导'));
    });

    test('桥以 API/文本为主 → 指出真凶大概率不在桥', () {
      stats.apiGet = 30;
      stats.imageRoutedNative = 0;
      stats.imageSameOrigin = 0;
      stats.textResponseBytes = 256 * 1024;
      final verdict = stats.activeLoadVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('API/文本'));
    });

    test('reset 后速判回到无结论', () {
      stats.apiGet = 5;
      expect(stats.activeLoadVerdict, isNotNull);
      stats.reset();
      expect(stats.activeLoadVerdict, isNull);
    });
  });
}
