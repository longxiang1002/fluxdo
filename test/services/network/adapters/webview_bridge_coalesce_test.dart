import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_bridge_diagnostics.dart';
import 'package:fluxdo/services/network/adapters/webview_bridge_gate.dart';

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

  group('D16 桥单位成本速判', () {
    test('样本不足时不冒充结论', () {
      stats.apiGet = 3;
      stats.totalMs = 900;
      expect(stats.bridgeCostVerdict, isNull);
    });

    test('平均耗时远超原生直连 → 判为固定税主导', () {
      stats.apiGet = 10;
      stats.totalMs = 4000; // 平均 400ms
      final verdict = stats.bridgeCostVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('桥单位成本偏高'));
      expect(verdict, contains('400ms'));
    });

    test('平均耗时中等 → 提示交叉排查', () {
      stats.apiGet = 10;
      stats.totalMs = 1800; // 平均 180ms
      final verdict = stats.bridgeCostVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('桥单位成本中等'));
    });

    test('平均耗时接近原生 → 指出桥非主因', () {
      stats.apiGet = 10;
      stats.totalMs = 600; // 平均 60ms
      final verdict = stats.bridgeCostVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('桥单位成本良好'));
    });

    test('reset 后成本速判回到无结论', () {
      stats.apiGet = 10;
      stats.totalMs = 4000;
      expect(stats.bridgeCostVerdict, isNotNull);
      stats.reset();
      expect(stats.bridgeCostVerdict, isNull);
    });
  });

  group('D17 桥固定税拆解', () {
    test('样本不足时不冒充结论', () {
      stats.apiGet = 3;
      stats.totalMs = 900;
      stats.cookiePrepMs = 600;
      expect(stats.bridgeTaxBreakdownVerdict, isNull);
    });

    test('cookie 准备主导 → 指向边界同步', () {
      stats.apiGet = 10;
      stats.totalMs = 3000;
      stats.cookiePrepMs = 2000; // 平均 200ms
      stats.jsEvalMs = 300; // 平均 30ms
      stats.browserWaitMs = 400; // 平均 40ms
      final verdict = stats.bridgeTaxBreakdownVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('主导段 = cookie 准备'));
      expect(verdict, contains('cookie 准备 200ms'));
    });

    test('JS 调用主导 → 指向脚本瘦身', () {
      stats.apiGet = 10;
      stats.totalMs = 3000;
      stats.cookiePrepMs = 100;
      stats.jsEvalMs = 2000; // 平均 200ms
      stats.browserWaitMs = 300;
      final verdict = stats.bridgeTaxBreakdownVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('主导段 = JS 调用'));
    });

    test('等浏览器主导 → 指出桥非主因', () {
      stats.apiGet = 10;
      stats.totalMs = 5000;
      stats.cookiePrepMs = 100;
      stats.jsEvalMs = 200;
      stats.browserWaitMs = 4000; // 平均 400ms
      final verdict = stats.bridgeTaxBreakdownVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('主导段 = 等浏览器返回'));
    });

    test('三段均衡 → 不押单段', () {
      stats.apiGet = 10;
      stats.totalMs = 3000;
      stats.cookiePrepMs = 700;
      stats.jsEvalMs = 700;
      stats.browserWaitMs = 700;
      final verdict = stats.bridgeTaxBreakdownVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('三段均衡'));
    });

    test('reset 后拆解回到无结论', () {
      stats.apiGet = 10;
      stats.totalMs = 3000;
      stats.cookiePrepMs = 2000;
      expect(stats.bridgeTaxBreakdownVerdict, isNotNull);
      stats.reset();
      expect(stats.bridgeTaxBreakdownVerdict, isNull);
      expect(stats.cookiePrepMs, 0);
      expect(stats.browserWaitMs, 0);
      expect(stats.cookieBackSyncMs, 0);
    });
  });

  group('D32 桥内分段按类别归因', () {
    test('样本不足时不冒充结论', () {
      stats.apiGet = 3;
      stats.apiGetJsMs = 900;
      expect(stats.classPhaseVerdict, isNull);
    });

    test('JS 调用段主导 → 指向脚本瘦身（纯 CPU）', () {
      stats.apiGet = 10;
      stats.apiGetJsMs = 2000;
      stats.apiGetBrowserMs = 300;
      stats.apiGetCookieMs = 100;
      final verdict = stats.classPhaseVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('JS 调用段主导'));
      expect(verdict, contains('JS调用 2000 ms'));
    });

    test('等浏览器段主导 → 指出桥非 CPU 源，应降并发/分流', () {
      stats.apiGet = 10;
      stats.apiGetJsMs = 200;
      stats.apiGetBrowserMs = 4000;
      stats.apiGetCookieMs = 100;
      final verdict = stats.classPhaseVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('等浏览器段主导'));
    });

    test('cookie 准备段主导 → 指向边界同步降频', () {
      stats.apiGet = 10;
      stats.apiGetJsMs = 200;
      stats.apiGetBrowserMs = 300;
      stats.apiGetCookieMs = 3000;
      final verdict = stats.classPhaseVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('cookie 准备段主导'));
    });

    test('三段分散 → 不押单段', () {
      stats.apiGet = 10;
      stats.apiGetJsMs = 700;
      stats.apiGetBrowserMs = 700;
      stats.apiGetCookieMs = 700;
      final verdict = stats.classPhaseVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('三段分散'));
    });

    test('图片类分段聚合：JS 与等浏览器分别求和', () {
      stats.imageSameOriginJsMs = 100;
      stats.imageOtherJsMs = 50;
      stats.imageSameOriginBrowserMs = 400;
      stats.imageOtherBrowserMs = 200;
      expect(stats.imageJsMs, 150);
      expect(stats.imageBrowserMs, 600);
      expect(stats.totalClassifiedJsMs, 150);
      expect(stats.totalClassifiedBrowserMs, 600);
    });

    test('reset 后分段计数清零', () {
      stats.apiGet = 10;
      stats.apiGetJsMs = 2000;
      stats.imageSameOriginBrowserMs = 500;
      expect(stats.classPhaseVerdict, isNotNull);
      stats.reset();
      expect(stats.classPhaseVerdict, isNull);
      expect(stats.totalClassifiedJsMs, 0);
      expect(stats.totalClassifiedBrowserMs, 0);
      expect(stats.totalClassifiedCookieMs, 0);
      expect(stats.imageJsMs, 0);
      expect(stats.imageBrowserMs, 0);
    });
  });

  group('D33 闸门饱和时间占比速判', () {
    test('无观测样本时不冒充结论', () {
      WebViewBridgeGate.instance.reset();
      expect(stats.gateSaturationTimeVerdict, isNull);
    });

    test('饱和占比 ≥70% → 判为长期顶上限，指向分流而非再降上限', () {
      final gate = WebViewBridgeGate.instance;
      gate.reset();
      gate.saturatedMs = 800;
      gate.unsaturatedMs = 200;
      final verdict = stats.gateSaturationTimeVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('80%'));
      expect(verdict, contains('长期顶在上限'));
      expect(verdict, contains('分流原生'));
      gate.reset();
    });

    test('饱和占比 30~70% → 判为间歇性饱和，转向单请求固定税', () {
      final gate = WebViewBridgeGate.instance;
      gate.reset();
      gate.saturatedMs = 500;
      gate.unsaturatedMs = 500;
      final verdict = stats.gateSaturationTimeVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('间歇性饱和'));
      expect(verdict, contains('单请求固定税'));
      gate.reset();
    });

    test('饱和占比 <30% → 判为基本不饱和，限流无贡献', () {
      final gate = WebViewBridgeGate.instance;
      gate.reset();
      gate.saturatedMs = 100;
      gate.unsaturatedMs = 900;
      final verdict = stats.gateSaturationTimeVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('基本不饱和'));
      expect(verdict, contains('回退上限'));
      gate.reset();
    });
  });

  group('D34 端到端桥代价按类别归因', () {
    test('无完成请求时不冒充结论', () {
      expect(stats.endToEndAttributionVerdict, isNull);
      expect(stats.queueShareOfEndToEndPct, isNull);
      expect(stats.totalEndToEndMs, 0);
    });

    test('合计 = 各类别之和，排队占比按端到端口径算', () {
      stats.imageSameOriginTotalMs = 400;
      stats.imageOtherTotalMs = 100;
      stats.apiGetTotalMs = 300;
      stats.apiWriteTotalMs = 100;
      stats.otherTotalMs = 100;
      expect(stats.totalEndToEndMs, 1000);
      stats.apiGetQueueMs = 250;
      expect(stats.queueShareOfEndToEndPct, 25);
    });

    test('图片占比 ≥50% → 指向继续分流原生', () {
      stats.imageSameOriginTotalMs = 600;
      stats.apiGetTotalMs = 400;
      final verdict = stats.endToEndAttributionVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('代价压在图片上'));
      expect(verdict, contains('分流原生'));
    });

    test('API 占比 ≥50% → 指向合并调用/降条数', () {
      stats.imageSameOriginTotalMs = 200;
      stats.apiGetTotalMs = 700;
      stats.apiWriteTotalMs = 100;
      final verdict = stats.endToEndAttributionVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('代价压在 API 上'));
      expect(verdict, contains('合并调用'));
    });

    test('两类均不突出 → 提示查桥外因素', () {
      stats.imageSameOriginTotalMs = 300;
      stats.apiGetTotalMs = 300;
      stats.otherTotalMs = 400;
      final verdict = stats.endToEndAttributionVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('均不突出'));
      expect(verdict, contains('桥外'));
    });

    test('reset 清零端到端计数，保持「端到端 ≈ 进桥 + 排队」可交叉验证', () {
      stats.imageSameOriginTotalMs = 500;
      stats.apiGetTotalMs = 500;
      stats.imageSameOriginMs = 300;
      stats.apiGetQueueMs = 200;
      stats.reset();
      expect(stats.totalEndToEndMs, 0);
      expect(stats.queueShareOfEndToEndPct, isNull);
      expect(stats.endToEndAttributionVerdict, isNull);
    });
  });

  group('D37 单请求固定税', () {
    test('无样本时均值与判据均为 null', () {
      expect(stats.averageBridgeCostMs, isNull);
      expect(stats.perRequestTaxVerdict, isNull);
    });

    test('样本不足（< bridgeCostMinSamples）时判据为 null，但均值可算', () {
      stats.imageSameOrigin = 3;
      stats.totalMs = 300;
      expect(stats.totalRequests, 3);
      expect(stats.averageBridgeCostMs, 100);
      expect(stats.perRequestTaxVerdict, isNull);
    });

    test('均值 = 总耗时 / 走桥请求数', () {
      stats.imageSameOrigin = 10;
      stats.apiGet = 10;
      stats.totalMs = 400;
      expect(stats.totalRequests, 20);
      expect(stats.averageBridgeCostMs, 20);
    });

    test('均值 >= 50ms → 判为「单请求税很重」，指向削单请求开销', () {
      stats.imageSameOrigin = 10;
      stats.totalMs = 600;
      final verdict = stats.perRequestTaxVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('D37'));
      expect(verdict, contains('很重'));
      expect(verdict, contains('D16/D17'));
    });

    test('均值 10~50ms → 判为「单请求税中等」，指向减少走桥条数', () {
      stats.imageSameOrigin = 10;
      stats.totalMs = 200;
      final verdict = stats.perRequestTaxVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('中等'));
      expect(verdict, contains('减少走桥条数'));
    });

    test('均值 < 10ms → 判为「单请求税很轻」，提示转查桥外因素', () {
      stats.imageSameOrigin = 10;
      stats.totalMs = 50;
      final verdict = stats.perRequestTaxVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('很轻'));
      expect(verdict, contains('桥之外'));
    });

    test('reset 清零后均值与判据回到 null', () {
      stats.imageSameOrigin = 10;
      stats.totalMs = 600;
      expect(stats.perRequestTaxVerdict, isNotNull);
      stats.reset();
      expect(stats.averageBridgeCostMs, isNull);
      expect(stats.perRequestTaxVerdict, isNull);
    });
  });
}
