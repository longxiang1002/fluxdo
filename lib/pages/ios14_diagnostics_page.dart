import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import '../services/diagnostics/ios14_diagnostics.dart';
import '../services/network/system_proxy_service.dart';

/// 由网络设置打开的测试诊断页面，采集需要用户主动开启。
class Ios14DiagnosticsPage extends StatefulWidget {
  const Ios14DiagnosticsPage({super.key, this.diagnostics});
  final Ios14Diagnostics? diagnostics;

  @override
  State<Ios14DiagnosticsPage> createState() => _Ios14DiagnosticsPageState();
}

class _Ios14DiagnosticsPageState extends State<Ios14DiagnosticsPage> {
  Ios14Diagnostics get _diagnostics =>
      widget.diagnostics ?? Ios14Diagnostics.instance;
  String _status = '';

  Future<void> _copy() async {
    try {
      // 附带「内部浏览器出口」采样：证明 WebView 出口是否由系统代理决定，
      // 即 DoH 出站（跟随系统代理）与 WebView 出口能否一致。
      // 非 iOS 或读取失败时为 null，不影响其余报告。
      final exitProbe = await SystemProxyProbe.exportJson();
      final report = <String, Object?>{
        ...jsonDecode(_diagnostics.exportJson()) as Map<String, Object?>,
        'webviewExitProbe': exitProbe,
      };
      await Clipboard.setData(
        ClipboardData(text: const JsonEncoder.withIndent('  ').convert(report)),
      );
      if (mounted) setState(() => _status = '诊断报告已复制');
    } catch (_) {
      if (mounted) setState(() => _status = '复制失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('iOS 14 测试诊断')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '默认关闭，仅在当前进程内按分钟汇总，最多保留 60 分钟。'
          '不保存网址、账户、Cookie、请求正文或错误原文，不写入磁盘。'
          '这不是温度测量，也不证明所有请求均经过 DoH。',
        ),
        SwitchListTile(
          title: const Text('启用聚合诊断'),
          subtitle: const Text('关闭后停止采集；重置可清除已采集数据'),
          value: _diagnostics.enabled,
          onChanged: (value) => setState(() => _diagnostics.setEnabled(value)),
        ),
        const Text(
          '视频销毁计数表示内联组件释放，不代表全屏共享控制器已销毁。'
          'WebView 计数表示初始化／销毁尝试。复制时生成最新安全 JSON。',
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () => setState(() {
            _diagnostics.reset();
            _status = '诊断数据已重置';
          }),
          child: const Text('重置诊断数据'),
        ),
        FilledButton(onPressed: _copy, child: const Text('复制安全 JSON 报告')),
        Semantics(liveRegion: true, child: Text(_status)),
      ],
    ),
  );
}
