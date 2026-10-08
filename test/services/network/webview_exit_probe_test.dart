import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/system_proxy_service.dart';

/// iOS 14 内部浏览器 DoH 接管：**WebView 出口采样**的语义契约。
///
/// 路径 C（「DoH 出站跟随系统代理 → 两通道出口一致」）成立的**前提**是
/// WKWebView 确实走系统代理。`SystemProxyReader.effectiveProxyUrl` 读的是
/// **系统设置**，无法证明 App 进程内实际出口；原生侧改用
/// `CFNetworkCopyProxiesForURL` 采样 App 进程真实生效的代理
/// （`AppDelegate` 的 `proxyProbe`），本文件锁死其判定语义。
void main() {
  SystemProxyProbeEntry entry({
    required String type,
    String? host,
    int? port,
    bool? consistent,
    bool pac = false,
    bool pacRemote = false,
  }) => SystemProxyProbeEntry(
    type: type,
    host: host,
    port: port,
    hasPacScript: pac,
    pacIsRemote: pacRemote,
    consistentWithSystem: consistent,
  );

  group('SystemProxyProbe 出口一致性判定', () {
    test('固定 HTTP 代理且与系统设置一致 → 出口由系统代理决定', () {
      final probe = SystemProxyProbe(
        systemProxyUrl: 'http://127.0.0.1:7890',
        entries: [
          entry(type: 'http', host: '127.0.0.1', port: 7890, consistent: true),
        ],
      );

      expect(probe.effectiveExitIsSystemProxy, isTrue);
      expect(probe.usesFixedProxy, isTrue);
      // 日志串必须可读：这条是「WebView 出口 == DoH 出站」的核心证据。
      expect(probe.describe(), contains('entries=[http:127.0.0.1:7890=sys]'));
      expect(probe.describe(), contains('exitIsSystemProxy=true'));
      expect(probe.describe(), isNot(contains('Instance of')));
    });

    test('PAC 条目 → 出口不由系统固定代理决定（路径 C 前提不成立）', () {
      final probe = SystemProxyProbe(
        systemProxyUrl: 'http://127.0.0.1:7890',
        entries: [entry(type: 'pac', pac: true, pacRemote: true)],
      );

      expect(probe.effectiveExitIsSystemProxy, isFalse);
      expect(probe.usesFixedProxy, isFalse);
      // 只留类型与是否 PAC/远端，不出现脚本 URL 或正文。
      expect(probe.describe(), contains('entries=[pac(pac:remote)]'));
      expect(probe.describe(), isNot(contains('.pac')));
      expect(probe.describe(), isNot(contains('function')));
    });

    test('直连（kCFProxyTypeNone）→ 与系统设置不一致', () {
      final probe = SystemProxyProbe(
        systemProxyUrl: 'http://127.0.0.1:7890',
        entries: [entry(type: 'direct')],
      );

      expect(probe.effectiveExitIsSystemProxy, isFalse);
      expect(probe.usesFixedProxy, isFalse);
    });

    test('代理存在但与系统设置 host:port 不同 → 不能认定出口一致', () {
      final probe = SystemProxyProbe(
        systemProxyUrl: 'http://10.0.0.2:8080',
        entries: [
          entry(type: 'http', host: '127.0.0.1', port: 7890, consistent: false),
        ],
      );

      expect(probe.effectiveExitIsSystemProxy, isFalse);
    });

    test('socks 也属于「被固定代理决定」的出口', () {
      final probe = SystemProxyProbe(
        systemProxyUrl: 'http://127.0.0.1:1080',
        entries: [
          entry(type: 'socks', host: '127.0.0.1', port: 1080, consistent: true),
        ],
      );

      expect(probe.effectiveExitIsSystemProxy, isTrue);
    });

    test('无条目 → 判定未知（不冒充成功）', () {
      const probe = SystemProxyProbe(entries: []);

      expect(probe.effectiveExitIsSystemProxy, isNull);
      expect(probe.usesFixedProxy, isFalse);
    });

    test('原生通道返回缺失字段时不抛异常，退化为未知', () {
      final probe = SystemProxyProbe.fromChannel(const {
        'count': 1,
        'entries': [
          {'type': 'http'},
        ],
      });

      expect(probe.entries, hasLength(1));
      expect(probe.entries.single.host, isNull);
      expect(probe.entries.single.consistentWithSystem, isNull);
      expect(probe.effectiveExitIsSystemProxy, isFalse);
    });

    test('导出 JSON 只含固定字段（无脚本正文/凭据）', () {
      final probe = SystemProxyProbe(
        systemProxyUrl: 'http://127.0.0.1:7890',
        entries: [
          entry(type: 'http', host: '127.0.0.1', port: 7890, consistent: true),
        ],
      );

      final json = probe.toJson();
      expect(json['exitIsSystemProxy'], isTrue);
      expect(json['systemProxyUrl'], 'http://127.0.0.1:7890');
      final first = (json['entries'] as List).first as Map<String, Object?>;
      expect(first.keys, containsAll(<String>['type', 'host', 'port']));
      expect(first.containsKey('pacScript'), isFalse);
      expect(first.containsKey('username'), isFalse);
    });
  });
}
