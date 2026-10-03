import 'package:dio/dio.dart';

/// 网关改写仅在传输调用期间生效；异常和取消必须恢复原始请求。
Future<T> withGatewayRequest<T>(
  RequestOptions options,
  int port,
  Future<T> Function() send,
) async {
  final uri = options.uri;
  final baseUrl = options.baseUrl;
  final path = options.path;
  final hadHost = options.headers.containsKey('Host');
  final host = options.headers['Host'];
  options.headers['Host'] = uri.host;
  options.baseUrl = '';
  options.path = Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: uri.path,
    query: uri.query.isEmpty ? null : uri.query,
    fragment: uri.fragment.isEmpty ? null : uri.fragment,
  ).toString();
  try {
    return await send();
  } finally {
    options.baseUrl = baseUrl;
    options.path = path;
    if (hadHost) {
      options.headers['Host'] = host;
    } else {
      options.headers.remove('Host');
    }
  }
}
