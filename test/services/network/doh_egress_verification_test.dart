import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/doh_route_diagnostics.dart';

/// iOS 14 内部浏览器 DoH 接管：**出口确证**三态语义契约。
///
/// `dohGateway` 路由只说明「请求交给了本地 DoH 网关」，不说明出口真是 DoH。
/// 出口是否 DoH 只能靠原生采样（`CFNetworkCopyProxiesForURL`）实测。
/// 本文件锁死「未采样绝不冒充已确证」这条边界——此前真机排查正是被
/// 「设置成功但没用」这种模糊状态误导过。
void main() {
  group('DohRouteDiagnostics 出口确证三态', () {
    test('未采样时 dohEgressVerified 为 null，不冒充成功', () {
      final diagnostics = DohRouteDiagnostics();
      expect(diagnostics.dohEgressVerified, isNull);
      // dohRouteExact 是给「必须有布尔值」的场景用的保守视图。
      expect(diagnostics.dohRouteExact, isFalse);
    });

    test('采样为 true 后，gateway 记录的 dohEgressVerified 才为 true', () {
      final diagnostics = DohRouteDiagnostics()..enabled = true;
      diagnostics.setDohEgressVerified(true);
      diagnostics.record(
        generation: diagnostics.generation,
        settingsVersion: 1,
        route: 'gateway',
        adapter: 'network',
        dohEnabled: true,
      );

      final record = diagnostics.snapshot().single;
      expect(record['dohEgressVerified'], isTrue);
      expect(record['route'], 'gateway');
    });

    test('采样为 false 时 gateway 记录如实记为 false', () {
      final diagnostics = DohRouteDiagnostics()..enabled = true;
      diagnostics.setDohEgressVerified(false);
      diagnostics.record(
        generation: diagnostics.generation,
        settingsVersion: 1,
        route: 'gateway',
        adapter: 'network',
        dohEnabled: true,
      );

      expect(diagnostics.snapshot().single['dohEgressVerified'], isFalse);
    });

    test('非 gateway 路由不带出口确证结论（避免误读）', () {
      final diagnostics = DohRouteDiagnostics()..enabled = true;
      diagnostics.setDohEgressVerified(true);
      diagnostics.record(
        generation: diagnostics.generation,
        settingsVersion: 1,
        route: 'direct-or-rhttp',
        adapter: 'rhttp',
        dohEnabled: true,
      );
      diagnostics.record(
        generation: diagnostics.generation,
        settingsVersion: 1,
        route: 'webview',
        adapter: 'webview',
        dohEnabled: true,
      );

      for (final record in diagnostics.snapshot()) {
        expect(
          record['dohEgressVerified'],
          isNull,
          reason: '${record['route']} 不该声称出口已确证',
        );
      }
    });

    test('出口状态整块替换而非叠加，脏值不会残留', () {
      final diagnostics = DohRouteDiagnostics();
      diagnostics.setDohEgressVerified(true);
      diagnostics.setDohEgressVerified(null);

      expect(diagnostics.dohEgressVerified, isNull);
      expect(diagnostics.dohRouteExact, isFalse);
    });

    test('相同值重复写入不通知监听器（避免采样风暴）', () {
      final diagnostics = DohRouteDiagnostics();
      var notifications = 0;
      final token = diagnostics.addEgressListener(() {
        notifications++;
        return true;
      });
      diagnostics.setDohEgressVerified(true);
      diagnostics.setDohEgressVerified(true);
      expect(notifications, 1);

      diagnostics.removeEgressListener(token);
      diagnostics.setDohEgressVerified(false);
      expect(notifications, 1, reason: '已移除的监听器不应再被调用');
    });

    test('未知路由被归一化为 unknown，且仍不带出口确证', () {
      final diagnostics = DohRouteDiagnostics()..enabled = true;
      diagnostics.setDohEgressVerified(true);
      diagnostics.record(
        generation: diagnostics.generation,
        settingsVersion: 1,
        route: 'something-new',
        adapter: 'mystery',
        dohEnabled: true,
      );

      final record = diagnostics.snapshot().single;
      expect(record['route'], 'unknown');
      expect(record['adapter'], 'unknown');
      expect(record['dohEgressVerified'], isNull);
    });

    test('关闭采集时不写记录，出口状态本身仍可查询', () {
      final diagnostics = DohRouteDiagnostics()..setDohEgressVerified(true);
      diagnostics.record(
        generation: diagnostics.generation,
        settingsVersion: 1,
        route: 'gateway',
        adapter: 'network',
        dohEnabled: true,
      );

      expect(diagnostics.snapshot(), isEmpty);
      expect(diagnostics.dohEgressVerified, isTrue);
    });
  });
}
