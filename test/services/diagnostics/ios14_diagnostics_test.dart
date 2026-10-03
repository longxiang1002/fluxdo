import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/diagnostics/ios14_diagnostics.dart';

void main() {
  test('default off, fixed route vocabulary, disable and reset', () {
    var clockReads = 0;
    final diagnostics = Ios14Diagnostics(
      clock: () {
        clockReads++;
        return DateTime.utc(2026);
      },
    );
    diagnostics.record(Ios14DiagnosticEvent.timingsSend);
    expect(clockReads, 0);
    diagnostics.setEnabled(true);
    diagnostics.record(Ios14DiagnosticEvent.timingsSend);
    diagnostics.recordRoute(
      engine: Ios14RouteEngine.io,
      path: Ios14RoutePath.dohGateway,
    );
    diagnostics.setEnabled(false);
    diagnostics.record(Ios14DiagnosticEvent.timingsSend);
    final report = jsonDecode(diagnostics.exportJson()) as Map;
    final counts = report['buckets'][0]['counts'] as Map;
    expect(counts, {'timingsSend': 1, 'route.io.dohGateway': 1});
    expect(report['enabled'], false);
    diagnostics.reset();
    expect(jsonDecode(diagnostics.exportJson())['buckets'], isEmpty);
  });

  test('retains at most sixty minute buckets and expires old data', () {
    var now = DateTime.utc(2026);
    final diagnostics = Ios14Diagnostics(clock: () => now)..setEnabled(true);
    for (var i = 0; i < 120; i++) {
      diagnostics.record(Ios14DiagnosticEvent.messageBusRequest);
      now = now.add(const Duration(minutes: 1));
    }
    diagnostics.record(Ios14DiagnosticEvent.messageBusRequest);
    expect(jsonDecode(diagnostics.exportJson())['buckets'], hasLength(60));
    now = now.add(const Duration(hours: 2));
    expect(jsonDecode(diagnostics.exportJson())['buckets'], isEmpty);
  });

  test('clock rollback still has a hard bucket bound', () {
    var now = DateTime.utc(2026);
    final diagnostics = Ios14Diagnostics(clock: () => now)..setEnabled(true);
    for (var i = 0; i < 100; i++) {
      diagnostics.record(Ios14DiagnosticEvent.cfRoundStart);
      now = now.subtract(const Duration(minutes: 1));
    }
    expect(
      jsonDecode(diagnostics.exportJson())['buckets'].length,
      lessThanOrEqualTo(60),
    );
  });
}
