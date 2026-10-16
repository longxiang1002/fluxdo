import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/frame_jank_monitor.dart';

/// D39：常驻探针「按需启停」的可见性计数语义。
///
/// 动机（2026-10-13 深夜重定位：活跃刷帖时发热）：D11 已让「全树遍历」只在
/// 有人看诊断页时做，但 `FrameJankMonitor.start()` 里的两条常驻探针
/// （50ms UI 心跳 + 500ms 平台线程 RTT）此前只要监控一开就无条件跑。
/// D39 把它们的启停也绑到「诊断页可见」上。
///
/// 这里只测**计数语义**（纯静态状态，无 Timer、无 WebView、无平台通道），
/// 不测 Timer 是否真的停了——那需要 fake_async 且会碰 SchedulerBinding。
void main() {
  setUp(() {
    // 每个用例从「无人查看」开始，避免用例间互相污染。
    // 计数可能被其它用例抬高，这里按当前值逐步归零。
    while (FrameJankMonitor.hasDiagnosticsViewer) {
      FrameJankMonitor.setDiagnosticsViewerVisible(false);
    }
  });

  tearDown(() {
    while (FrameJankMonitor.hasDiagnosticsViewer) {
      FrameJankMonitor.setDiagnosticsViewerVisible(false);
    }
  });

  test('初始状态：无人查看诊断页', () {
    expect(FrameJankMonitor.hasDiagnosticsViewer, isFalse);
  });

  test('置位后可见；撤销后回到不可见', () {
    FrameJankMonitor.setDiagnosticsViewerVisible(true);
    expect(FrameJankMonitor.hasDiagnosticsViewer, isTrue);
    FrameJankMonitor.setDiagnosticsViewerVisible(false);
    expect(FrameJankMonitor.hasDiagnosticsViewer, isFalse);
  });

  test('多个诊断视图同时可见时，只有全部撤销才算无人查看', () {
    // 诊断页 + 悬浮面板同时挂载（真实场景：面板开着又进诊断页）。
    FrameJankMonitor.setDiagnosticsViewerVisible(true);
    FrameJankMonitor.setDiagnosticsViewerVisible(true);
    expect(FrameJankMonitor.hasDiagnosticsViewer, isTrue);

    FrameJankMonitor.setDiagnosticsViewerVisible(false);
    expect(FrameJankMonitor.hasDiagnosticsViewer, isTrue, reason: '还有一个视图在看');

    FrameJankMonitor.setDiagnosticsViewerVisible(false);
    expect(FrameJankMonitor.hasDiagnosticsViewer, isFalse);
  });

  test('多余的撤销不会把计数压成负数（dispose 顺序不保证）', () {
    FrameJankMonitor.setDiagnosticsViewerVisible(true);
    FrameJankMonitor.setDiagnosticsViewerVisible(false);
    FrameJankMonitor.setDiagnosticsViewerVisible(false);
    FrameJankMonitor.setDiagnosticsViewerVisible(false);
    expect(FrameJankMonitor.hasDiagnosticsViewer, isFalse);

    // 压成负数后再置位，仍应正确回到「可见」。
    FrameJankMonitor.setDiagnosticsViewerVisible(true);
    expect(FrameJankMonitor.hasDiagnosticsViewer, isTrue);
  });

  test('监控未运行时切换可见性不会抛异常（探针启停被 _started 短路）', () {
    // 本用例的前提：测试环境下 FrameJankMonitor 未 start()。
    expect(FrameJankMonitor.isRunning, isFalse);
    expect(
      () => FrameJankMonitor.setDiagnosticsViewerVisible(true),
      returnsNormally,
    );
    expect(FrameJankMonitor.hasDiagnosticsViewer, isTrue);
  });
}
