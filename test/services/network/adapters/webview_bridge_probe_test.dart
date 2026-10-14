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
}
