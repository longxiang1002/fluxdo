import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/ios14_diagnostics_page.dart';
import 'package:fluxdo/services/diagnostics/ios14_diagnostics.dart';

void main() {
  testWidgets('opt in, copy safe report, reset and disable', (tester) async {
    final diagnostics = Ios14Diagnostics();
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Ios14DiagnosticsPage(diagnostics: diagnostics)),
    );
    expect(diagnostics.enabled, false);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(diagnostics.enabled, true);
    diagnostics.record(Ios14DiagnosticEvent.timingsSend);
    await tester.ensureVisible(find.text('复制安全 JSON 报告'));
    await tester.tap(find.text('复制安全 JSON 报告'));
    // 复制按钮现在会先 await 一次「内部浏览器出口采样」（非 iOS 平台直接返回
    // null，无定时器），因此用 pump() 推进微任务，避免 pumpAndSettle 对
    // 平台通道/定时器的额外等待。
    await tester.pump();
    await tester.pump();
    expect(jsonDecode(clipboard!)['buckets'][0]['counts'], {'timingsSend': 1});
    expect(find.text('诊断报告已复制'), findsOneWidget);
    await tester.tap(find.text('重置诊断数据'));
    await tester.pump();
    expect(jsonDecode(diagnostics.exportJson())['buckets'], isEmpty);
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(diagnostics.enabled, false);
  });
}
