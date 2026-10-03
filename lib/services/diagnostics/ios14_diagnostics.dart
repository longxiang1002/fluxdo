import 'dart:collection';
import 'dart:convert';

/// 只接受固定事件类型，禁止传入 URL、异常原文或用户数据。
enum Ios14DiagnosticEvent {
  timingsSend,
  timingsSuccess,
  timingsError,
  timingsRetry,
  messageBusRequest,
  messageBusSuccess,
  messageBusError,
  messageBusCancelled,
  messageBusTimeout,
  messageBusRateLimited,
  cfRoundStart,
  cfRoundSuccess,
  cfRoundFailure,
  cfHiddenWebViewInit,
  cfHiddenWebViewDispose,
  videoInlineInit,
  videoInlineDispose,
  videoInitialize,
  videoInitializeError,
}

enum Ios14RouteEngine { io, cupertino, rhttp, webView, other }

enum Ios14RoutePath { direct, dohGateway, fallback, webViewUncovered }

/// 默认关闭，仅在内存中按分钟聚合；无定时器、监听器和磁盘写入。
/// 关闭时不读取时钟；视频释放表示内联租户释放，
/// 不等于原生控制器已销毁（全屏仍可能持有它）。
class Ios14Diagnostics {
  Ios14Diagnostics({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static final instance = Ios14Diagnostics();
  static const maxBuckets = 60;
  static const maxCount = 1000000;
  final DateTime Function() _clock;
  final _buckets = SplayTreeMap<int, Map<String, int>>();
  bool _enabled = false;
  bool get enabled => _enabled;

  void setEnabled(bool value) => _enabled = value;
  void reset() => _buckets.clear();

  void record(Ios14DiagnosticEvent event) => _record(event.name);

  /// 在真实传输分派时调用，不在设置选择时计数。
  /// 每次请求只接受固定引擎和路径组合，不接受端点或域名。
  void recordRoute({
    required Ios14RouteEngine engine,
    required Ios14RoutePath path,
  }) => _record('route.${engine.name}.${path.name}');

  void _prune(int minute) {
    _buckets.removeWhere((key, _) => key < minute - maxBuckets + 1);
    while (_buckets.length > maxBuckets) {
      _buckets.remove(_buckets.firstKey());
    }
  }

  void _record(String key) {
    if (!_enabled) return;
    final minute = _clock().millisecondsSinceEpoch ~/ 60000;
    final counts = _buckets.putIfAbsent(minute, () => <String, int>{});
    counts[key] = ((counts[key] ?? 0) + 1).clamp(0, maxCount);
    _prune(minute);
  }

  String exportJson() {
    _prune(_clock().millisecondsSinceEpoch ~/ 60000);
    return const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'enabled': enabled,
      'bucketSeconds': 60,
      'maxBuckets': maxBuckets,
      'countSaturation': maxCount,
      'scope': 'current isolate; lifecycle counts are attempts/inline tenants',
      'buckets': [
        for (final entry in _buckets.entries)
          {'epochMinute': entry.key, 'counts': Map.of(entry.value)},
      ],
    });
  }
}
