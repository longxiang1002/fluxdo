import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/apple_transport_policy.dart';

void main() {
  test('识别真实 Darwin iOS 版本格式，未知格式保守回退', () {
    expect(appleSystemMajorVersion('Version 14.8 (Build 18H17)'), 14);
    expect(appleSystemMajorVersion('iOS 15.0'), 15);
    expect(appleSystemMajorVersion('14.8.1'), 14);
    expect(appleSystemMajorVersion('Darwin Kernel Version 23'), isNull);
    expect(needsIosIoFallback(isIOS: true, systemVersion: ''), isTrue);
    expect(needsIosIoFallback(isIOS: false, systemVersion: ''), isFalse);
  });

  for (final requestKind in [
    'json',
    'message-bus-stream',
    'image-bytes',
    'external',
  ]) {
    test('iOS14 $requestKind 原生旁路不创建 Cupertino', () {
      var nativeCalls = 0;
      final transport = createIosCompatibleTransport<String>(
        isIOS: true,
        systemVersion: 'Version 14.8 (Build 18H17)',
        ioFactory: () => 'io',
        nativeFactory: () {
          nativeCalls++;
          throw StateError('iOS15 API');
        },
      );
      expect(transport, 'io');
      expect(nativeCalls, 0);
    });
  }

  test('iOS15及以后和非iOS保留原生工厂', () {
    for (final version in ['15.0', 'Version 17.6 (Build 21G80)', '26.0']) {
      expect(
        createIosCompatibleTransport<String>(
          isIOS: true,
          systemVersion: version,
          ioFactory: () => throw StateError('不应回退'),
          nativeFactory: () => 'native',
        ),
        'native',
      );
    }
    expect(
      createIosCompatibleTransport<String>(
        isIOS: false,
        systemVersion: '14.0',
        ioFactory: () => 'io',
        nativeFactory: () => 'native',
      ),
      'native',
    );
  });
}
