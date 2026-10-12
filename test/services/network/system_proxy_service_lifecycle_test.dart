import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/system_proxy_service.dart';

/// `SystemProxyService` 前后台节拍契约（DoH 模式省电）。
///
/// 背景：iOS 上每次周期 tick 是一趟平台通道 IPC + 阻塞式
/// `CFNetworkCopySystemProxySettings()` 系统调用。后台无需读系统代理，
/// 故 `pause()` 停拍、`resume()` 立即补一次再重挂拍。
///
/// ⚠️ 硬性边界：本改动**只动轮询节拍**，不触碰 WebView / JS 执行，
/// 与历史「滚动挂起 → iOS 验证页白屏」的路线无关。这里锁死
/// `pause()` / `resume()` 在任意平台都不抛异常、且不影响
/// `effectiveProxyUrl` 的可读性（非 Windows/iOS 恒为 null）。
void main() {
  group('SystemProxyService 前后台节拍', () {
    tearDown(() {
      SystemProxyService.instance.resetForTest();
    });

    test('pause 后 resume 不抛异常，且可反复调用', () {
      final service = SystemProxyService.instance;
      expect(() => service.pause(), returnsNormally);
      expect(() => service.resume(), returnsNormally);
      expect(() => service.pause(), returnsNormally);
      expect(() => service.pause(), returnsNormally, reason: '重复 pause 幂等');
      expect(() => service.resume(), returnsNormally);
      expect(() => service.resume(), returnsNormally, reason: '重复 resume 幂等');
    });

    test('pause/resume 不影响 effectiveProxyUrl 的可读性', () {
      final service = SystemProxyService.instance;
      service.pause();
      // 测试平台非 Windows/iOS → 恒为 null；关键是不因 pause 抛异常。
      expect(service.effectiveProxyUrl, isNull);
      service.resume();
      expect(service.effectiveProxyUrl, isNull);
    });

    test('pause 期间仍可显式 refresh 不抛异常（后台补读路径）', () {
      final service = SystemProxyService.instance;
      service.pause();
      expect(service.refresh, returnsNormally);
      expect(() => service.start(), returnsNormally);
    });
  });
}
