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
    // 复制按钮现在会先 await 一次「内部浏览器出口采样」（非 iOS 平台
    // probeEffectiveProxy 直接返回 null，无定时器），但这段 await 链会插入
    // 多个微任务/事件循环跳（exportJson → probeEffectiveProxy → 平台通道）。
    // 固定次数的 pump() 数量与实际跳数耦合、易随实现漂移，故改为循环推进，
    // 直到剪辑板被写入（有上限兜底，避免失败时死循环）。
    var pumped = 0;
    while (clipboard == null && pumped < 20) {
      await tester.pump();
      pumped++;
    }
    expect(clipboard, isNotNull, reason: '复制动作应在若干次 pump 后完成');
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
