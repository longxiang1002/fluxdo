import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/webview_bridge_probe.dart';

void main() {
  late WebViewBridgeProbe probe;

  setUp(() {
    probe = WebViewBridgeProbe.instance;
    probe.reset();
  });

  tearDown(() {
    probe.reset();
  });

  test('并发峰值记录同时未完成的最大请求数', () {
    probe.onRequestStart();
    probe.onRequestStart();
    probe.onRequestStart();
    expect(probe.concurrencyPeak, 3);
    expect(probe.inFlight, 3);

    probe.onRequestEnd(const Duration(milliseconds: 100));
    probe.onRequestEnd(const Duration(milliseconds: 100));
    expect(probe.inFlight, 1);
    // 峰值只增不减。
    expect(probe.concurrencyPeak, 3);

    probe.onRequestStart();
    expect(probe.concurrencyPeak, 3);
    probe.onRequestEnd(const Duration(milliseconds: 100));
    probe.onRequestEnd(const Duration(milliseconds: 100));
    expect(probe.inFlight, 0);
  });

  test('在飞时长累计与均值', () {
    probe.onRequestStart();
    probe.onRequestEnd(const Duration(milliseconds: 120));
    probe.onRequestStart();
    probe.onRequestEnd(const Duration(milliseconds: 80));

    expect(probe.completedRequests, 2);
    expect(probe.inFlightMs, 200);
    expect(probe.averageInFlightMs, 100);
  });

  test('无完成请求时均值为 null', () {
    expect(probe.averageInFlightMs, isNull);
    expect(probe.busyRatio, isNull);
  });

  test('在飞计数不会因多余 end 变成负数', () {
    probe.onRequestEnd(const Duration(milliseconds: 10));
    expect(probe.inFlight, 0);
    expect(probe.completedRequests, 1);
  });

  test('reset 清空全部统计量', () {
    probe.onRequestStart();
    probe.onRequestEnd(const Duration(milliseconds: 50));
    probe.reset();

    expect(probe.concurrencyPeak, 0);
    expect(probe.concurrencySamples, 0);
    expect(probe.idleSamples, 0);
    expect(probe.inFlightMs, 0);
    expect(probe.completedRequests, 0);
    expect(probe.inFlight, 0);
  });

  group('D35 桥活跃时长占比', () {
    test('无样本时占比与判据均为 null', () {
      expect(probe.activeTimeSharePct, isNull);
      expect(probe.activeTimeVerdict, isNull);
      expect(probe.sampledTotalMs, 0);
    });

    test('空闲计时与活跃计时配对，占比可算', () {
      // 直接注入已聚合整数（不依赖真实定时器）。
      probe.activeSampledMs = 9000;
      probe.idleSampledMs = 1000;

      expect(probe.sampledTotalMs, 10000);
      expect(probe.activeTimeSharePct, 90);
    });

    test('占比 >=80% 判为「桥几乎一直在忙」', () {
      probe.activeSampledMs = 8500;
      probe.idleSampledMs = 1500;

      final verdict = probe.activeTimeVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('桥几乎一直在忙'));
      expect(verdict, contains('85%'));
    });

    test('占比 40~80% 判为「桥忙闲参半」', () {
      probe.activeSampledMs = 5000;
      probe.idleSampledMs = 5000;

      final verdict = probe.activeTimeVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('桥忙闲参半'));
    });

    test('占比 <40% 判为「桥大部分时间空闲」', () {
      probe.activeSampledMs = 2000;
      probe.idleSampledMs = 8000;

      final verdict = probe.activeTimeVerdict;
      expect(verdict, isNotNull);
      expect(verdict, contains('桥大部分时间空闲'));
    });

    test('reset 一并清零空闲计时', () {
      probe.activeSampledMs = 5000;
      probe.idleSampledMs = 5000;
      probe.reset();

      expect(probe.idleSampledMs, 0);
      expect(probe.activeSampledMs, 0);
      expect(probe.activeTimeSharePct, isNull);
    });
  });
}
