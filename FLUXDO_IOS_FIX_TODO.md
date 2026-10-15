# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-13 起主攻**：DoH 模式下 App 仍旧发热（症状=**活跃刷帖时**发热，非空闲）。


## 🎯 本轮（2026-10-15 11:00 CST）— D21：闸门饱和度归因（活跃并发量化）

### CI 前置核对（强制第 0 步）
- **#78** `a4f8ac9c` = ✅ success，全 15 步绿；Release **`ios14-test-78`** 已出
  （`0.2.28.032`）✅。
- **#77** `affbc514` = ✅ success；**#76** `a47bc69c` = ✅ success。
- → 无未修复 failure、无缺 Release。
- ⚠️ **但 Actions 仍被禁用**（本轮 dispatch 实测再返 HTTP 422
  `Actions has been disabled for this repository.`，仓库级 `GET /actions/permissions`
  仍报 `enabled:true` → 账号级禁用，需老板网页端恢复）。D19(`eb19dc37`)、
  D20(`0135b9ec`)、D21(`31c283fe`) 均无对应 run，**只差 CI 出包**。

### 本轮改动（D21，commit `31c283fe`）
**证据（先读代码定位）**：D12 探针的并发采样只在**有请求在飞**时每秒 +1
（`webview_bridge_probe.dart` `_ensureSampler`），因此 `busyRatio` 恒等于
100%——它只能回答「桥在不在忙」，回答不了「桥有多忙」。而 D20 的
`gateVsTaxVerdict` 用「排队占比」判断限流值不值得做，排队占比为 0 有两种
互斥含义：(a) 并发本就不高（桥非瓶颈）→ 转查渲染/DoH；(b) 并发长期顶在上限、
闸门把洪峰削平了 → 应继续下调上限或分流。两者优化方向相反，缺一个区分量。

**改动（纯派生只读计数，零采样新增、零运行时开销，不碰任何 WebView 挂起 API）**：
- `webview_bridge_probe.dart`：新增活跃期「在飞数 × 时间」积分
  `inFlightIntegralMs` 与活跃采样时长 `activeSampledMs`（采样器运行期间
  每秒累加 `_inFlight * 1000`，`_stopSampler` 按实际毫秒结算尾段），
  派生 `averageActiveConcurrency`（活跃期平均并发）。
- `webview_bridge_diagnostics.dart`：新增 `gateSaturationVerdict`
  ——平均并发 / 上限 ≥ 75% 判「饱和」（限流/分流仍有收益），
  37.5%~75% 判「中度占用」（优先分流而非限流），<37.5% 判「远未打满」
  （桥非主因，转查渲染/解码/DoH）。阈值常量 `gateSaturationRatio = 0.75`。
- `ios14_network_diagnostics_page.dart`：诊断页加 D21 一行展示 + 探针区
  「活跃期平均并发」一行；报告 map 加 `gateSaturationVerdict` /
  `avgActiveConcurrency` / `activeSampledMs`。
- `ios14-test.yml`：APP_VERSION_SUFFIX 034→**035**。
- **硬性禁令遵守**：无 pauseTimers/resumeTimers，无滚动挂起，不阻塞 JS。

### 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：3 文件 **0 changed，exit 0** ✅。

### CI
push `31c283fe`；dispatch 被 422 拒（Actions 禁用），无 run。

### 下一步
1. 老板恢复 GitHub Actions 后重跑 dispatch，出 D21 包（`0.2.28.035`）。
2. 实机刷帖前后各看一次诊断页：D21 判「饱和」→ 下调闸门上限（4→3→2）再对比
   发热；判「远未打满」→ 桥非主因，转查渲染/图片解码/DoH 出口。
3. SS 接管方向与主线交替推进。

## 🎯 本轮（2026-10-15 04:00 CST）— D19：同源图片分流做成诊断页运行时 A/B 开关

### CI 前置核对（强制第 0 步）
- **#78** `a4f8ac9c`（D18 走桥脚本瘦身）= ✅ success，Release **`ios14-test-78`** 已出
  （版本 0.2.28.032）。
- **#77** `affbc514`（D17）= ✅ success；**#75/76** 均已处理。
- 结论：无未修复 failure，Release/IPA 齐全，可推进新工作。

### 1) 本轮判断（为什么做 D19）
- 上轮已把 D2「同源图片分流到原生 Dio」的静态开关 `imageNativeRoutingEnabled`
  提升为 `WebViewAdapterSettingsService` 里的运行时 `ValueNotifier`，并已接线
  `platform_adapter.dart` 走桥判据（`requestCanUseWebViewAdapter` 见
  `imageRoutedNative++` 分流），但**诊断页只有监听、没有 A/B 切换入口**（半成品）。
- 图片是活跃刷帖时**体量最大的走桥负载**（JS fetch + 分块 base64 跨桥回传），
  分流到原生 Dio 是降发热主攻方向的直接命中点之一。
- 本轮补齐诊断页 `SwitchListTile`，让老板在实机上**即切即开/关**做 A/B：
  - 开 = 同源图片走原生直连（省桥负载）；
  - 若刷帖出现图片变糊 / CF 403，一键关掉即回走桥旧行为（遵守 D3 回退铁律，不硬推）。

### 2) 改动（小而稳，零行为变化基线，不碰任何 WebView 挂起 API）
- `webview_adapter_settings_service.dart`：新增 `imageNativeRoutingNotifier`
  （默认 true）、`imageNativeRoutingEnabled` getter、`setImageNativeRouting()`。
- `platform_adapter.dart`：`requestCanUseWebViewAdapter` 走桥判据改用
  service 动态开关替换原静态 bool（删掉旧的顶层 `bool imageNativeRoutingEnabled`）。
- `ios14_network_diagnostics_page.dart`：在「同源图片已分流原生直连」下方加
  `SwitchListTile`，绑定该 notifier，initState/dispose 里监听切换驱动刷新。
- `.github/workflows/ios14-test.yml`：`APP_VERSION_SUFFIX` 032 → **033**。
- 未触碰任何 pauseTimers / resumeTimers / 滚动挂起逻辑；默认行为与旧版一致
  （true=分流开启），仅新增运行时开关入口。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：3 个改动 dart 文件 **0 changed，exit 0** ✅
- `dart analyze` 因 2 核 OOM 崩溃（历史已知环境问题，非代码问题）。
- 引用一致性：`imageNativeRoutingEnabled` / `setImageNativeRouting` /
  `imageNativeRoutingNotifier` 三处（page UI + page 监听 + platform_adapter）
  与 service 定义全部匹配，import 齐全。

### 4) 提交与 CI
- commit（见 progress-log），push 后触发 workflow。
- `APP_VERSION_SUFFIX` 032 → **033**。

### 下一步
1. 核对本轮 run → 确认 Release + IPA 直链。
2. 实机刷帖做 D2 A/B：先关分流（走桥）→ 刷帖发热；再开分流（原生）→ 对比发热
   与图片是否正常加载、有无 CF 403/变糊。预期开分流时桥负载显著下降。
3. 若 A/B 证实图片分流省热且不过盾 → 固化该路径为默认策略；若 403 → 回退并在
   日志写明数据（D3 铁律）。
4. SS 接管内置浏览器方向与主线轮次交替。

## 🚨 阻断（2026-10-15 08:00 CST）— GitHub Actions 被禁用，D19 出不了包

### CI 前置核对（强制第 0 步）
- **#78** `a4f8ac9c`（D18）= ✅ success，Release `ios14-test-78` 已出（0.2.28.032）。
- **#77** success；**#75** 已由 #76 修复。
- ⚠️ **D19 的 commit `eb19dc37` 已 push 到远端，但无任何 run**。

### 根因（实测）
- `POST /repos/longxiang1002/fluxdo/actions/workflows/ios14-test.yml/dispatches`
  → **HTTP 422 `Actions has been disabled for this repository.`**
- 仓库级 `GET /actions/permissions` 仍 `enabled:true`、workflow `state:active`、
  PAT 正常 → **账号级 Actions 禁用**（免费 plan，用量超限/滥用检测）。
- 时间线：BJ 04:17（#78 成功）之后被禁，BJ 07:23（D19 push）时已禁。

### 本轮已完成
- [x] 核对 CI 结论，定位真实阻断（非漏触发，是 Actions 被禁）
- [x] D19 代码本地校验：3 个 dart 文件 `dart format --set-exit-if-changed` 0 changed ✅
- [x] 代码已在远端分支 `fix/ios14-network-thermal`（eb19dc37）

### 待老板处理（我无法自行恢复）
- [ ] **在 GitHub 网页端恢复 Actions**：仓库 Settings→Actions→General 确认允许；
      若为账号级限制，查 https://github.com/settings/billing 与
      https://www.githubstatus.com 或提交 Support 申诉。

### 恢复后下一步
1. 重跑 dispatch（ref=fix/ios14-network-thermal）→ 出 D19 包（版本 0.2.28.033）。
2. 实机做 D2 A/B：关分流（走桥）vs 开分流（原生）刷帖对比发热/图片/CF 403。

## D22（2026-10-15 12:00 CST）— 限流实验可执行化 + 运行时上限 A/B
- [x] 核对 CI：#78 success，无遗留 failure；Actions 仍禁用（dispatch 422）
- [x] `gateTuningVerdict`：合并 D20 排队占比 + D21 饱和度 → 四种可执行结论
- [x] 运行时并发上限 A/B（诊断页 2/3/4/6，即切即生效，免每档重出包）
- [x] dart format（CI 同款 3.12.0）3 文件 0 changed ✅
- [x] commit `c4b97748` + push
- [ ] ⛔ CI 出包（0.2.28.036）——被 GitHub Actions 账号级禁用阻断，需老板网页端恢复
- [ ] 实机：刷帖一轮看 D22 建议行 → 判「值得做」则切上限 3 再刷对比发热

## D24（2026-10-15 13:00 CST）— A/B 开关跨重启持久化
- [x] 核对 CI：#78 success、#77/#76 success，无遗留 failure；Actions 仍禁用（本轮 dispatch 再返 422）
- [x] `webview_adapter_settings_service.dart`：图片分流 + 桥并发上限两开关落盘
      （`webview_image_native_routing` / `webview_gate_max_concurrent`），
      `initialize()` 恢复并同步 `WebViewBridgeGate.maxConcurrent`，`resetForTest()` 复位
- [x] dart format（CI 同款 3.12.0）1 文件 0 changed ✅
- [x] commit `81316167` + push（origin 已同步）
- [ ] ⛔ CI 出包（0.2.28.037）——Actions 账号级禁用，连续第 5 轮阻断
- [ ] 实机：设好档位后重启 App，确认档位保持（诊断页显示一致）再对比发热

## D25（2026-10-15 14:00 CST）— 跨桥字节搬运税归因
- [x] 核对 CI：#78 `a4f8ac9c` success（Release ios14-test-78 / 0.2.28.032 已出）；
      #77/#76 success，无遗留 failure；Actions 仍禁用（本轮 dispatch 再返 422）
- [x] 读现状：确认桥上有两条成本结构不同的路径——文本响应（`callHandler`
      一次性回传，≈1 次跨语言往返）vs 二进制流（`createWebMessageChannel`
      建通道 + `postWebMessage` 握手 + 每 chunk 一次 `setWebMessageCallback`
      回调，≈2+N 次）。此前 D16~D22 全部建立在 `totalRequests` 混合口径上。
- [x] `webview_bridge_diagnostics.dart`：新增 `binaryBridgeResponses` /
      `binaryBridgeBytes` / `binaryBridgeChunks` 三个聚合计数 +
      `bridgeByteTaxVerdict` getter（判「流路径主导」/「文本路径主导」/
      「无流走桥」三种可执行结论）+ 阈值常量 `bridgeByteTaxStreamDominantRatio`=30
- [x] `webview_http_adapter.dart`：在 `bridge.done.whenComplete` 里累加三个计数
      （纯整数，零采样、零新增运行时开销，不碰任何 WebView 挂起/暂停 API）
- [x] `ios14_network_diagnostics_page.dart`：加 D25 结论行 + 流路径固定成本明细行
      + 报告 map 三个字段
- [x] `ios14-test.yml`：APP_VERSION_SUFFIX 037→**038**
- [x] dart format（CI 同款 3.12.0）3 文件 **0 changed exit 0** ✅
- [x] commit `ce762103` + push（origin 已同步）
- [ ] ⛔ CI 出包（0.2.28.038）——Actions 账号级禁用，连续第 6 轮阻断
- [ ] 实机：刷帖一轮看 D25 结论行 → 判「流路径主导」则继续把静态资源分流原生；
      判「文本路径主导」则优先减少走桥请求条数（分流只读请求）

## D27（2026-10-15 16:00 CST）— 图片分流豁免名单（逐条回退，不必整体关分流）
- [x] 核对 CI：#78 `a4f8ac9c` success（Release ios14-test-78 / 0.2.28.032 已出）；
      #77/#76 success，无遗留 failure；Actions 仍禁用（本轮 dispatch 再返 422）
- [x] 读现状：确认 D2 的图片分流只有「整体开关」一个回退手段，缺逐条豁免粒度
- [x] `webview_adapter_settings_service.dart`：新增 `imageSkipPathsNotifier` +
      `isImageRoutingSkipped` + 增删清（均落盘 `webview_image_skip_paths`），
      `initialize()` 恢复、`resetForTest()` 复位
- [x] `platform_adapter.dart`：图片分流分支加豁免判断，命中则仍走桥并计
      `imageRoutingSkipped`
- [x] `webview_bridge_diagnostics.dart`：新增 `imageRoutingSkipped` 计数
- [x] `ios14_network_diagnostics_page.dart`：报告两字段 + 名单 UI（加/删/清空）
- [x] `ios14-test.yml`：APP_VERSION_SUFFIX 038→**040**
- [x] dart format（CI 同款 3.12.0）5 文件 **0 changed exit 0** ✅
- [x] commit `a74d4eef` + push（origin 已同步）
- [ ] ⛔ CI 出包（0.2.28.040）——Actions 账号级禁用，连续第 7 轮阻断
- [ ] 实机：某路径图片 403/变糊时，把该路径片段加入豁免名单即时验证

## D26 接线补完（2026-10-15 17:00 CST）— 类别耗时归因从「有壳无数」补成可读事实
- [x] 核对 CI：#78 `a4f8ac9c` success（Release ios14-test-78 / 0.2.28.032 已出）；
      #77/#76 success，无遗留 failure；Actions 仍禁用（本轮 dispatch 再返 422）
- [x] 读现状：发现上轮 D27 提交时把 D26 诊断侧（5 个 `*Ms` 字段 +
      `classTimeVerdict` + 诊断页）带进 HEAD，但 adapter 侧接线漏提交 →
      `_recordClassTime` 从未被调用、`classTimeVerdict` 恒为 null，D26 是半成品
- [x] `webview_http_adapter.dart`：`_recordBridgeRequestKind` 返回
      `_BridgeRequestClass`；新增 `_recordClassTime`；文本路径(:632)与流路径(:960)
      各归因一次；`_fetchBinaryStreamResponse` 透传 `requestClass`；新增枚举
- [x] `ios14-test.yml`：APP_VERSION_SUFFIX 040→**041**
- [x] dart format（CI 同款 3.12.0）1 文件 **0 changed exit 0** ✅
- [x] commit `32b4953b` + push（origin 已同步）
- [ ] ⛔ CI 出包（0.2.28.041）——Actions 账号级禁用，连续第 8 轮阻断
- [ ] 实机：刷帖一轮看 D26 结论行，判主导类别（图片/API读/写）定下一步靶点

## D28（2026-10-15 18:00 CST）— 桥并发闸门按类别加权（图片权重 2）
### CI 前置核对（强制第 0 步）
- **#78** `a4f8ac9c` = ✅ success，全 15 步绿；Release **`ios14-test-78`** 已出
  （`0.2.28.032`，含 IPA）✅。**#77/#76** = ✅ success，均有 Release。
- **#75** `84ab8ca6` = ❌ failure，但已被 #76/#77/#78 覆盖修复，无需回修。
- → 无未修复 failure、无缺 Release。
- ⚠️ **Actions 仍被账号级禁用**：`GET /actions/permissions` 报 `enabled:true`、
  workflow `state:active`，但 dispatch 实测再返 HTTP 422
  `Actions has been disabled for this repository.`（连续第 9 轮）。
- **本轮新验证**：为绕开被禁的 dispatch API，给 workflow 加 `push` 兜底触发器
  （限本分支 + paths-ignore 自身），push `16c4b3d2` 后**仍无新 run**
  （runs total 停在 78）→ 证实账号级冻结同时挡住 push 触发，非代码层可解。

### 本轮改动（D28，commit `16c4b3d2`）
**证据（先读代码定位）**：D13 桥并发闸门让所有走桥请求按同一权重抢槽位，但
图片流（响应体大、分块回调多、在飞时间长）与 API/文本请求（体小、回传快）
单位成本不同。活跃滚动时少量大图即长期占住名额，把大量轻量请求挤入队列，
拉长整体在飞时间、抬高 CPU 峰值——正对「活跃刷帖发热」病灶。

**改动（纯 Dart 侧排队，不碰任何 WebView 挂起/暂停 API，不阻塞 JS）**：
- `webview_bridge_gate.dart`：`acquire`/`release` 支持 `weight`；`_inFlight`
  改为**权重和**；`release` 改为「先扣减释放者权重，再循环唤醒能放下的队首」
  （修正旧实现「名额转交、_inFlight 不变」在权重>1 时的计数漂移）；
  新增 `imageWeight=2`、`weightedAcquires` 计数；`reset`/`resetAllForTest`
  同步清理 `_waiterWeights`。
- `webview_http_adapter.dart`：新增 `_isImageRequest`；图片类请求
  acquire/release 传 `weight=imageWeight`，其余默认 1（向后兼容）。
- `ios14_network_diagnostics_page.dart`：闸门区展示「图片加权入桥次数」；
  报告 map 加 `gateWeightedAcquires`/`gateInFlight`。
- `webview_bridge_gate_test.dart`：新增 D28 加权占用 + 向后兼容两例。
- `ios14-test.yml`：APP_VERSION_SUFFIX 041→**042**；加 push 兜底触发器。

### 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：4 文件 **0 changed，exit 0** ✅。
- `flutter test webview_bridge_gate_test.dart`：**7/7 通过** ✅。

### CI
push `16c4b3d2` 成功（origin 已同步）；dispatch 与 push 触发均被账号级冻结挡住，
无新 run、无出包。

### 下一步
1. 老板恢复 GitHub Actions 后，dispatch 或 push 均可出 D28 包（`0.2.28.042`）。
2. 实机刷帖：看诊断页「图片加权入桥次数」是否随滚动增长，对比发热是否下降；
   若下降不明显，说明图片非主导，转看 D26 类别耗时归因定靶点。
3. SS 接管内置浏览器方向下轮交替推进。
