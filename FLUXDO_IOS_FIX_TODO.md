# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-13 起主攻**：DoH 模式下 App 仍旧发热（症状=**活跃刷帖时**发热，非空闲）。


## 🎯 本轮（2026-10-15 04:00 CST）— D18：走桥请求脚本瘦身（砍每请求 JS 解析固定税）

### CI 前置核对（强制第 0 步）
- **#77** `affbc514`（D17 桥固定税拆解）= ✅ success，Release **`ios14-test-77`** 已出
  （`fluxdo-ios14-test-77-affbc514.ipa`）。
- **#76** `a47bc69c`（D16 修复）= ✅ success；**#75** failure 已由 #76 修复。
- 结论：无未修复 failure，Release/IPA 齐全，可推进新工作。

### 1) 本轮判断（为什么做 D18）
- D15/D16/D17 已把「桥负载量 / 单位成本 / 成本拆解」三问补齐，诊断侧到位。
- 但老板实测刷帖仍热 → 需要**真正动手砍** D17 拆出来的固定税。
- 代码证据：每个走桥请求的 JS 脚本里，都**重复内联**一段与请求无关的
  abort 辅助声明：
  `window.__fluxdoFetchAborters = ... || {}` +
  `window.__fluxdoAbortFetch = ... || function(id){...}`（函数体 6 行）。
  这些声明幂等、与请求无关，却在**每个请求**都要重新解析一遍 →
  活跃刷帖时直接抬高 D17 里「JS 调用」那一段的固定税。
- 这是**零语义变化**的纯瘦身，且不依赖尚未拿到的真机数据即可安全落地。

### 2) 改动（小而稳，零行为变化、不碰任何 WebView 挂起 API）
- `lib/services/network/adapters/webview_http_adapter.dart`：
  - 新增 `_installFetchHelpers(controller)`：WebView 就绪时**一次性**把
    `__fluxdoFetchAborters` / `__fluxdoAbortFetch` 装到 window。
  - `initialize()` 在 `_writeBootstrapHtml` 之后、`_isInitialized = true` 之前调用它。
  - 文本路径脚本：删掉重复的 `__fluxdoAbortFetch` 函数体声明，只保留
    `window.__fluxdoFetchAborters = window.__fluxdoFetchAborters || {};`（一行兜底）。
  - 二进制流路径脚本：同上瘦身。
  - 安装失败只记日志：请求脚本仍带 `|| {}` 兜底，abort 退化为 no-op
    （`_abortWebViewFetch` 本就有 `if (window.__fluxdoAbortFetch)` 守卫），
    不影响响应正确性，也不会白屏。
- 未触碰任何 WebView 挂起/暂停 API，不阻塞 JS 执行；fetch 的 cookie/凭据/
  CF 指纹路径完全不变（过盾不受影响）。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：1 个改动 dart 文件 **0 changed，exit 0** ✅
- `dart analyze --fatal-infos` 因 2 核/3.7G 机器 analysis server OOM 崩溃
  （历史已知环境问题，非代码问题）；`dart format` 全文件解析通过 = 语法有效。
- 结构核对：`__fluxdoAbortFetch` 声明数 3 → **1**（仅 hoisted 助手），
  `__fluxdoFetchAborters` 初始化 3 处（助手 + 2 条请求脚本）。

### 4) 提交与 CI
- commit `（见 progress-log）`，push 后触发 workflow。
- `APP_VERSION_SUFFIX` 031 → **032**。

### 下一步
1. 核对本轮 run → 确认 Release + IPA 直链。
2. 实机刷帖对比 `jsEvalMs`（D17 的 JS 段）是否下降；若 D17 判「JS 主导」，
   本改动即为直接命中靶点。
3. SS 接管内置浏览器方向与主线轮次交替。
