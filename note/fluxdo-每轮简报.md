【FluxDO 第21轮 · 2026-10-16 10:00 北京时间】

结论：本轮推进 D41「无效负载代价」——把 D40 数出来的「白付税条数」换算成桥内耗时下界，直接回答「砍无效负载值不值得做」。已 push，CI 仍被账号级冻结挡住（dispatch 422，第21轮）。

证据：
- D41 改动：新增 wastedCostVerdict 判据，取保守下界（无效请求全落在较便宜路径 × 条数），三档结论（下界占桥内总耗时 ≥15% 可观 / 5~15% 中等 / <5% 很小）。文件：webview_bridge_diagnostics.dart / ios14_network_diagnostics_page.dart。
- commit 78a52172（09b1a854..78a52172），分支 fix/ios14-network-thermal。
- 本地验证（CI 同款 Dart 3.12.0）：dart format 0 changed；coalesce 66/66 通过（含 D41 八例）；gate+probe 33/33 通过。
- 前置核对：run #78 a4f8ac9c success，Release ios14-test-78 已出，无遗留 failure。
- 版本后缀 052→053。

下一步：等老板恢复 GitHub Actions 出包（0.2.28.053）；实机刷帖读诊断页六件套（D35/D36 忙闲形态 + D26 主导类别 + D37 单请求税轻重 + D38 削哪条路径 + D40 多少白付税 + D41 值不值得砍）定位活跃发热靶点。SS 接管内置浏览器方向下轮交替推进。
