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
}
