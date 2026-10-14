# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-13 起主攻**：DoH 模式下 App 仍旧发热（症状=**活跃刷帖时**发热，非空闲）。


## 🎯 本轮（2026-10-15 00:00 CST）— D14：JS 侧分块合并（响应侧削峰）

### CI 前置核对（强制第 0 步）
- **#72** `0c371a61`（D13 桥并发闸门）= ✅ success，Release **`ios14-test-72`** 已出
  （`fluxdo-ios14-test-72-0c371a61.ipa`，`0.2.28.027`）。
- **#71** `1cba3697`（D12）= ✅ success，Release `ios14-test-71` 已出。
- **#70** `96bbfeea` = ✅ success。
- 结论：无未修复 failure，Release/IPA 齐全，可推进新工作。

### 1) 证据
- 二进制流响应路径里 JS 对 `response.body` 逐 chunk `reader.read()`，
  **每个 chunk 各发一次 `postMessage`** 跨桥回传；每次都要跨 JS↔native
  边界 + Dart 回调派发。活跃刷帖时大图以许多小 chunk 到达，
  边界穿越批数与 chunk 数同阶 → CPU 峰值叠加（活跃期发热结构性来源）。
- 跨域图片与其它二进制流仍走桥，且 D2 分流开关一旦因 CF 403 回退，
  全部图片会回到这条逐 chunk 路径 → 把该路径本身做轻，收益与分流无关。

### 2) 改动
- `webview_http_adapter.dart`：JS 侧新增 `pushChunk`/`flushPending`，
  攒到 64KB 再一次性跨桥回传；流末 flush 余量；新增 `coalesceStats` 回传统计。
  - **正确性**：flush 时 `out` 独占恰好 `pendingLen` 的 ArrayBuffer
    （transfer 会送整个 buffer，不能带 64KB 尾部垃圾）。
  - Dart 侧消息处理器新增 `coalesceStats` 分支累加计数。
- `webview_bridge_diagnostics.dart`：新增 `streamRawChunks` /
  `streamCoalescedMessages` / 派生 `streamMessagesSaved`；`reset()` 清零。
- `ios14_network_diagnostics_page.dart`：新增「JS 侧分块合并（D14）」区块 + 判读；
  JSON report 增三字段。
- **禁令遵守**：只在 JS 内存里合并，不碰 pauseTimers/resumeTimers，不阻塞 JS。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：**0 changed，exit 0** ✅。
- `flutter test`（gate + probe + coalesce）：**13 项全过** ✅。
- 本地 `flutter analyze` OOM（analysis server -9），非代码问题。

### 4) 提交与 CI
- commit `226c36f9`，push `0c371a61..226c36f9`。
- `APP_VERSION_SUFFIX` 027 → **028**。触发 workflow（HTTP 204）→ **run #73**。

### 下一步
1. 核对 #73 → 确认 Release + IPA 直链。
2. 实机刷帖后看 D14：原始 chunk ≫ 合并后消息 → 合并生效；
   两者接近 → 转查响应侧序列化。与 D13 排队数据交叉判读。
3. SS 接管内置浏览器方向与主线轮次交替。

## 🎯 本轮（2026-10-14 23:00 CST）— D13：桥并发闸门 + 响应字节量化

### CI 前置核对（强制第 0 步）
- **#71** `1cba3697`（D12 探针）= **in_progress**，step1–9 全 success，
  当前跑 step10「构建未签名 IPA」（23:00 时约 54 分钟，属正常编译耗时），
  **无 conclusion=failure，无需先修**。
- **#70** `96bbfeea` = ✅ success（已读上报四计数）。
- **#69** `4acb7cc9` = ✅ success（D11），Release `ios14-test-69` 已出。
- Release 已到 `ios14-test-70`（`0.2.28.026` 对应 #71 待出）。
- 结论：无未修复 failure，可推进新工作。

### 1) 证据：为什么做并发闸门
- D12 探针已能测「并发峰值 / 忙碌占比 / 平均在飞时长」，但**只能测不能治**。
- 桥的固定税是**结构性**的：每个走桥请求都要
  `拼 JS 脚本 → evaluateJavascript 跨语言 → fetch → 响应经
  WebMessageChannel 分块 / base64 回传 Dart`。
  活跃滚动刷帖时，图片与 API 请求会**同时**涌入，每个都在飞期间占用
  JS 线程 + 原生桥回调，CPU 峰值叠加 → 发热。
- 桥本身是**共享资源**（单个隐藏 WKWebView + 单条 JS 线程），
  无上限并发只会让每个请求都在飞更久（互相排队），
  总 CPU 时间不减反增（更多上下文切换 + 更多分块回调）。
- 因此：给桥加一个**有界并发闸门**，把「同时在飞的桥请求数」限到
  一个合理值（默认 4），超出的请求在 Dart 侧排队等待，
  **不阻塞 JS、不挂起 WebView、不改任何请求语义**。

### 2) 改动
- 新增 `lib/services/network/adapters/webview_bridge_gate.dart`
  （`WebViewBridgeGate`）：纯 Dart 信号量，`acquire()` / `release()`，
  可配置 `maxConcurrent`（默认 4），记录 `peakWaiting`（排队峰值）
  与 `queuedTotal`（累计排队次数）供诊断页判读。
  - **绝不在持有闸门时执行任何 WebView 挂起/暂停 API**；
  - 等待是 `Completer` 队列，不轮询、不 Timer，空闲零开销；
  - `release()` 严格配对，`finally` 里调用，异常/取消都不漏放。
- `webview_http_adapter.dart`：`fetch` 进入后先 `gate.acquire()`，
  `finally` 里 `gate.release()`（在 `onRequestEnd` 之前），
  保证「在飞时长」统计包含排队时间，便于看出限流是否生效。
- `webview_bridge_diagnostics.dart`：新增响应字节量化
  `imageResponseBytes`（同源图片走桥时的响应字节，用于 D2 分流收益对比）；
  `reset()` 一并清零。
- `ios14_network_diagnostics_page.dart`：D12 区块追加「桥并发闸门」
  三行（当前在飞 / 排队峰值 / 累计排队）+ 说明。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- 待跑。

### 4) 提交与 CI
- 待提交。

### 下一步
1. 核对 #71 与本轮 run → 确认 Release + IPA 直链。
2. 实机刷帖后看 D12/D13：若「累计排队」高且平均在飞时长下降 →
   限流生效，可继续下调 `maxConcurrent`（4→3→2）找最优；
   若排队为 0 → 并发本就不高，转查 CF 刷新重建频率 / 响应侧序列化。
3. SS 接管内置浏览器方向与主线轮次交替。
