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
    // 复制按钮现在会先 await 一次「内部浏览器出口采样」
    // （SystemProxyProbe.exportJson → probeEffectiveProxy；非 iOS/macOS
    // 直接返回 null，无定时器）再 await Clipboard.setData。这条 await 链
    // 跨了真实的微任务/事件循环边界，仅靠 tester.pump()（只在 FakeAsync
    // 里推进一帧）无法排空，cliboard 始终为 null。用 runAsync 让真实事件
    // 循环跑完这次异步链，再 pump 刷新 UI。
    await tester.runAsync(() async {
      // 给 _copy() 的 await 链留出真实时间完成（平台通道 mock 立即返回，
      // 这里只是排空微任务；有上限兜底避免死循环）。
      var waited = 0;
      while (clipboard == null && waited < 50) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        waited++;
      }
    });
    await tester.pump();
    expect(clipboard, isNotNull, reason: '复制动作应在 runAsync 后完成');
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
