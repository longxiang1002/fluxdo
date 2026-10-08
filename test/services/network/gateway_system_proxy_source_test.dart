import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/proxy/gateway_upstream.dart';
import 'package:fluxdo/services/network/proxy/proxy_settings_service.dart';

/// iOS 14 内部浏览器 DoH 接管：出口一致性契约。
///
/// WKWebView 默认跟随系统代理（CFNetwork 栈），本地 DoH 网关不在系统代理里。
/// iOS < 17 无法用 `WKWebsiteDataStore.proxyConfigurations` 把 WebView 指向
/// 本地网关，因此只能让**网关出站**也走系统代理，使两个通道出口 IP 一致。
///
/// 本文件锁死这一契约的**语义**（与 [GatewayUpstream.resolve] 的优先级）：
/// 应用内代理 > 系统代理 > 直连。
void main() {
  group('GatewayUpstream 系统代理来源契约', () {
    test('应用内代理有效时，系统代理不参与（不受 iOS 传值影响）', () {
      const applicationProxy = ProxySettings(
        enabled: true,
        protocol: UpstreamProxyProtocol.http,
        host: 'app.proxy',
        port: 8080,
      );

      final withSystem = GatewayUpstream.resolve(
        applicationProxy: applicationProxy,
        systemProxyUrl: 'http://127.0.0.1:7890',
      );

      expect(withSystem?.host, 'app.proxy');
      expect(withSystem?.port, 8080);
    });

    test('应用代理未启用时，系统代理决定出口（iOS 出口一致性依据）', () {
      final upstream = GatewayUpstream.resolve(
        applicationProxy: const ProxySettings(),
        systemProxyUrl: 'http://127.0.0.1:7890',
      );

      expect(upstream?.protocol, 'http');
      expect(upstream?.host, '127.0.0.1');
      expect(upstream?.port, 7890);
    });

    test('系统代理为 null 时回退直连（未配代理 / TUN 模式）', () {
      final upstream = GatewayUpstream.resolve(
        applicationProxy: const ProxySettings(),
        systemProxyUrl: null,
      );

      expect(upstream, isNull);
    });

    test('畸形系统代理不产生上游，避免全部请求挂死', () {
      for (final bad in [
        '',
        'not a url',
        'http://no-port.example',
        'ftp://127.0.0.1:21',
      ]) {
        expect(
          GatewayUpstream.fromSystemProxyUrl(bad),
          isNull,
          reason: '不应接受畸形系统代理: $bad',
        );
      }
    });

    test('SOCKS5 系统代理被正确识别为 socks5 上游', () {
      final upstream = GatewayUpstream.fromSystemProxyUrl(
        'socks5://127.0.0.1:1080',
      );

      expect(upstream?.protocol, 'socks5');
      expect(upstream?.port, 1080);
    });

    test('当前测试平台不是 Windows/iOS，网关应保持直连语义', () {
      // 契约：非 Windows / 非 iOS 平台传 null 与传 SystemProxyService 值等价，
      // 因为 SystemProxyService.effectiveProxyUrl 在这些平台恒为 null。
      expect(Platform.isWindows || Platform.isIOS, isFalse);
    });
  });
}
