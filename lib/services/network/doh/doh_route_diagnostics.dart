import 'dart:collection';

/// 仅记录固定枚举路由、状态码和配置代号。不记录 URL、请求头或正文。
/// 默认关闭；最多保存 60 次请求头结果，不逐请求写盘或刷新 UI。
class DohRouteDiagnostics {
  static final instance = DohRouteDiagnostics();
  static const maxRecords = 60;
  bool enabled = false;
  final Queue<Map<String, Object?>> _records = Queue();
  int _generation = 0;

  /// 由原生出口采样回填：**当前 DoH 通道是否已确证走 DoH 出口**。
  ///
  /// 三态语义，禁止把「未采样」冒充成「已确证」：
  /// - `true`  → 本次构建的运行时采样结果为「是」
  /// - `false` → 采样结果为「否」
  /// - `null`  → 尚未采样 / 平台不支持 / 采样构建未生效（**不冒充成功**）
  ///
  /// 只在每次采样时整块替换（不是逐请求叠加），避免脏值被当成当前事实。
  bool? dohEgressVerified;

  final List<bool Function()> _egressListeners = [];

  /// 采样完成后可反查「这条 dohGateway 记录是否在本分钟内被确证走 DoH」。
  bool get dohRouteExact => dohEgressVerified ?? false;

  void setDohEgressVerified(bool? value) {
    if (dohEgressVerified == value) return;
    dohEgressVerified = value;
    for (final listener in _egressListeners.toList()) {
      listener();
    }
  }

  int addEgressListener(bool Function() listener) {
    _egressListeners.add(listener);
    return _egressListeners.length - 1;
  }

  void removeEgressListener(int index) {
    if (index >= 0 && index < _egressListeners.length) {
      _egressListeners[index] = () => false;
    }
  }

  void reset() {
    _records.clear();
    _generation++;
  }

  void setEnabled(bool value) {
    enabled = value;
    reset();
  }

  int get generation => _generation;

  void record({
    required int generation,
    required int settingsVersion,
    required String route,
    required String adapter,
    required bool dohEnabled,
    bool gatewayResolverMatched = false,
    int? status,
    bool failed = false,
  }) {
    if (!enabled || generation != _generation) return;
    const routes = {'webview', 'gateway', 'direct-or-rhttp'};
    const adapters = {'webview', 'native', 'network', 'rhttp', 'io-ios14'};
    final normalizedRoute = routes.contains(route) ? route : 'unknown';
    // 只有 gateway 路由（= 交给本地 DoH 网关）才谈得上「出口是 DoH」。
    // 未采样（null）时必须如实记 null，不能塌缩成 false —— 那会让
    // 「不知道」和「已确证不是」混为一谈，正是真机排查最怕的歧义。
    final bool? egressVerified = normalizedRoute == 'gateway'
        ? dohEgressVerified
        : null;
    _records.add({
      'settingsVersion': settingsVersion,
      'route': normalizedRoute,
      'adapter': adapters.contains(adapter) ? adapter : 'unknown',
      'dohConfigured': dohEnabled,
      'gatewayResolverMatched':
          dohEnabled && normalizedRoute == 'gateway' && gatewayResolverMatched,
      // 三态：null = 未采样，true/false = 采样结论。仅 gateway 路由有意义。
      'dohEgressVerified': egressVerified,
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
