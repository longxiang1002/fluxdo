import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/doh_route_diagnostics.dart';

void main() {
  test('默认关闭、限量、敏感值不进入报告、清空隔离旧请求', () {
    final d = DohRouteDiagnostics();
    void add({int? generation, String route = 'gateway'}) => d.record(
      generation: generation ?? d.generation,
      settingsVersion: 1,
      route: route,
      adapter: 'io-ios14',
      dohEnabled: true,
      status: 200,
    );
    add();
    expect(d.snapshot(), isEmpty);
    d.setEnabled(true);
    for (var i = 0; i < 90; i++) {
      add();
    }
    expect(d.snapshot(), hasLength(60));
    final old = d.generation;
    d.reset();
    add(generation: old);
    expect(d.snapshot(), isEmpty);
    add(route: 'https://secret.example/?token=secret');
    expect(d.snapshot().single['route'], 'unknown');
    expect(d.snapshot().toString(), isNot(contains('secret')));
    d.setEnabled(false);
    add();
    expect(d.snapshot(), isEmpty);
  });

  test('传输失败不能记录为成功，配置代号保留用于判断历史记录', () {
    final d = DohRouteDiagnostics()..setEnabled(true);
    d.record(
      generation: d.generation,
      settingsVersion: 7,
      route: 'gateway',
      adapter: 'io-ios14',
      dohEnabled: false,
      failed: true,
    );
    final record = d.snapshot().single;
    expect(record['httpStatus'], isNull);
    expect(record['transportFailed'], isTrue);
    expect(record['dohConfigured'], isFalse);
    expect(record['settingsVersion'], 7);
    record['settingsVersion'] = 999;
    expect(d.snapshot().single['settingsVersion'], 7);
  });
  test('匹配状态必须同时满足网关路由、DoH开启和运行配置匹配', () {
    final d = DohRouteDiagnostics()..setEnabled(true);
    for (final entry in [
      (false, 'gateway', true),
      (true, 'webview', true),
      (true, 'gateway', false),
      (true, 'gateway', true),
    ]) {
      d.record(
        generation: d.generation,
        settingsVersion: 1,
        route: entry.$2,
        adapter: 'io-ios14',
        dohEnabled: entry.$1,
        gatewayResolverMatched: entry.$3,
      );
    }
    expect(d.snapshot().map((r) => r['gatewayResolverMatched']), [
      false,
      false,
      false,
      true,
    ]);
  });
}
