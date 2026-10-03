import 'dart:collection';

/// 仅记录固定枚举路由、状态码和配置代号。不记录 URL、请求头或正文。
/// 默认关闭；最多保存 60 次请求头结果，不逐请求写盘或刷新 UI。
class DohRouteDiagnostics {
  static final instance = DohRouteDiagnostics();
  static const maxRecords = 60;
  bool enabled = false;
  final Queue<Map<String, Object?>> _records = Queue();
  int _generation = 0;

  int get generation => _generation;

  void reset() {
    _records.clear();
    _generation++;
  }

  void setEnabled(bool value) {
    enabled = value;
    reset();
  }

  void record({
    required int generation,
    required int settingsVersion,
    required String route,
    required String adapter,
    required bool dohEnabled,
    int? status,
    bool failed = false,
  }) {
    if (!enabled || generation != _generation) return;
    const routes = {'webview', 'gateway', 'direct-or-rhttp'};
    const adapters = {'webview', 'native', 'network', 'rhttp', 'io-ios14'};
    _records.add({
      'settingsVersion': settingsVersion,
      'route': routes.contains(route) ? route : 'unknown',
      'adapter': adapters.contains(adapter) ? adapter : 'unknown',
      'dohConfigured': dohEnabled,
      'httpStatus': status,
      'transportFailed': failed,
    });
    while (_records.length > maxRecords) {
      _records.removeFirst();
    }
  }

  List<Map<String, Object?>> snapshot() =>
      _records.map((entry) => Map<String, Object?>.of(entry)).toList();
}
