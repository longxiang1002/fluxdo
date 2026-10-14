【FluxDO 攻坚简报】2026-10-15 00:00（北京时间）

本轮结论：主线推进 D14「JS 侧分块合并」——二进制流响应此前每读到一个
小 chunk 就各自跨桥 postMessage 一次，活跃刷帖时大图会被切成几十上百次
JS↔native 边界穿越，是活跃期发热的结构性来源。现改为在 JS 侧攒到 64KB
再一次性回传，把跨桥批数压到约 1/N，字节序与语义完全不变。

证据：commit 226c36f9（webview_http_adapter.dart 新增 pushChunk/flushPending
+ coalesceStats 统计；诊断页新增「JS 侧分块合并」区块）；本地 dart format
0 changed、单测 13 项全过；已 push 并触发 CI run #73（APP_VERSION_SUFFIX 028）。
前置核对：#72（D13）success，Release ios14-test-72 + IPA 已出，无未修复失败。

下一步：等 #73 出包；实机刷帖后看诊断页「原始 chunk → 合并后消息」——
原始 chunk 远多于消息数即合并生效，可与 D13 排队数据交叉判读。
