import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/gateway_request.dart';

void main() {
  test('网关只改写传输 URL，返回后恢复 Cookie/重试所见 URL 和 Host', () async {
    final request = RequestOptions(
      baseUrl: 'https://linux.do',
      path: '/latest.json?page=2',
      headers: {'Host': 'original', 'Cookie': 'test-only'},
    );
    final original = request.uri;
    final result = await withGatewayRequest(request, 12345, () async {
      expect(request.uri.host, '127.0.0.1');
      expect(request.uri.port, 12345);
      expect(request.uri.scheme, 'http');
      expect(request.uri.queryParameters['page'], '2');
      expect(request.headers['Host'], 'linux.do');
      expect(request.headers['Cookie'], 'test-only');
      return 200;
    });
    expect(result, 200);
    expect(request.uri, original);
    expect(request.headers['Host'], 'original');
  });

  for (final type in [
    DioExceptionType.cancel,
    DioExceptionType.receiveTimeout,
    DioExceptionType.badCertificate,
  ]) {
    test('$type 原样抛出且恢复请求，不吞掉 TLS 错误', () async {
      final request = RequestOptions(path: 'https://linux.do/latest.json');
      final original = request.uri;
      final error = DioException(requestOptions: request, type: type);
      await expectLater(
        withGatewayRequest<void>(request, 12345, () async {
          throw error;
        }),
        throwsA(same(error)),
      );
      expect(request.uri, original);
      expect(request.headers.containsKey('Host'), isFalse);
    });
  }
}
