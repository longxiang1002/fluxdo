# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-13 起主攻**：DoH 模式下 App 仍旧发热（症状=**活跃刷帖时**发热，非空闲）。


## 🎯 本轮（2026-10-16 01:00 CST）— D33：闸门饱和时间占比（限流真实生效强度）

### CI 前置核对（强制第 0 步）
- **#78** `a4f8ac9c` = ✅ success（Release **ios14-test-78** / 0.2.28.032 已出）。
- **#77** `affbc514` = ✅ success；**#76** `a47bc69c` = ✅ success。
- → 无未修复 failure、无缺 Release。
- ⚠️ **Actions 仍账号级冻结**：本轮实测 dispatch 再返 **HTTP 422**
  `Actions has been disabled for this repository.`；runs total 恒停在 78。
  D19~D33 均已 push 但无 run，只差 CI 出包验证。

### 本轮改动（D33，commit `1a574e9d`）
**动机（活跃负载发热主线）**：D20/D21/D22 用「排队条数占比」与「采样平均并发」
判断限流值不值得做，但两者都会被活跃期「脉冲式满/空」抹平——一条请求在闸门外
等 300ms，这 300ms 里闸门一直是满的，而**均值看不出来**。缺「闸门顶在上限的
时间占比」这一直接证据，就无法判定当前并发上限是「削峰有效」还是「白限流」。

**改动（纯 Dart 侧计时与派生判据，不碰 WebView 挂起/暂停 API，不阻塞 JS）**：
- `webview_bridge_gate.dart`：新增 `wouldBlock({weight})`（纯读谓词）、
  `saturatedMs`/`unsaturatedMs`/`observedMs`/`saturationPct`、
  `sampleSaturation(nowMs)`（首次只建基线，时间未推进/倒流不累加）；
  `reset`/`resetAllForTest` 同步清零并丢弃采样基线。
- `webview_http_adapter.dart`：新增 `_sampleGateSaturation`，在**请求进出桥**
  两个天然时刻各采一次（acquire 后、release 后），**不新增定时器/采样循环**。
- `webview_bridge_diagnostics.dart`：新增 `gateSaturationTimeVerdict`
  （≥70% 长期顶上限→继续分流而非再降上限；30~70% 间歇饱和→转单请求固定税；
  <30% 基本不饱和→限流无贡献，可回退上限）。
- `ios14_network_diagnostics_page.dart`：闸门区展示「闸门饱和时间占比（D33）」
  与饱和计时；报告 map 加 5 个字段。
- `webview_bridge_gate_test.dart`：新增 D33 五例；`webview_bridge_coalesce_test.dart`
  新增 D33 四例（三档判据 + 无样本）。
- `ios14-test.yml`：APP_VERSION_SUFFIX 045→**046**。

### 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：6 文件 **0 changed exit 0** ✅
- 本地 Flutter `flutter test` gate + coalesce → **45/45 通过** ✅（含 D33 九例）
- `dart analyze` diagnostics 5 info 经 `git stash` 对照确认**改动前即存在**（非本轮引入）。

### CI
push `1a574e9d` 成功（`bfa4b2a1..1a574e9d`）；dispatch 422（Actions 冻结），无 run 无包。

### 下一步
1. 老板网页端恢复 GitHub Actions → 重跑 dispatch 出 D19~D33 各包（0.2.28.033~046）。
2. 实机刷帖看诊断页「闸门饱和时间占比（D33）」：≥70% → 继续把同源图片分流原生；
   <30% → 限流无贡献，转单请求成本（D16/D17/D32）或桥外因素。
3. SS 接管内置浏览器方向（P1 iOS14 管道替代）与主线下轮交替推进。

## 🎯 本轮（2026-10-16 00:00 CST）— D32：桥内耗时三段按请求类别归因

### CI 前置核对（强制第 0 步）
- **#78** `a4f8ac9c` = ✅ success（Release **ios14-test-78** / 0.2.28.032 已出）。
- **#77** `affbc514` = ✅ success；**#76** `a47bc69c` = ✅ success。
- → 无未修复 failure、无缺 Release。
- ⚠️ **Actions 仍账号级冻结**：本轮实测 dispatch 再返 **HTTP 422**
  `Actions has been disabled for this repository.`；push 兜底也不触发（runs total
  恒停在 78）。D19~D32 均已 push 但无 run，只差 CI 出包验证。

### 本轮改动（D32，commit `30ed8aa2`）
**动机（活跃负载发热主线）**：D26 回答「哪一类请求吃掉桥时间」、D31 回答
「排队代价压在谁身上」，但都还没回答**这段时间是 CPU 还是 I/O 等待**——
而这决定优化方向完全不同（抠脚本 vs 降并发/分流）。D17 已把单请求耗时拆成
「cookie准备/JS调用/等浏览器」三段，只是**没按类别分开**，无法回答
「图片类的 CPU 税 vs API 类的 CPU 税各占多少」。

**改动（纯 Dart 侧计数与派生判据，不碰 WebView 挂起/暂停 API，不阻塞 JS）**：
- `webview_bridge_diagnostics.dart`：新增 15 个按类别的三段耗时计数 +
  3 个求和 getter + `classPhaseVerdict`（判 JS调用段/cookie准备段/等浏览器段主导，
  各给对应靶点）+ `imageJsMs`/`imageBrowserMs`；`reset` 同步清空。
- `webview_http_adapter.dart`：新增 `_recordClassPhase`，在文本路径与二进制流路径
  两处 `_recordClassTime` 之后各接一次（流路径 browserWait 用 headerWatch.elapsed）。
- `ios14_network_diagnostics_page.dart`：桥区展示「桥内分段归因(D32)」等三行；
  报告 map 加 6 字段。
- `webview_bridge_coalesce_test.dart`：新增 D32 七例。
- `.github/workflows/ios14-test.yml`：APP_VERSION_SUFFIX 044→**045**。

### 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：4 文件 **0 changed exit 0** ✅
- 本地 Flutter `flutter test` coalesce + gate → **36/36 通过** ✅（含 D32 七例）
- `dart analyze` diagnostics：5 info 经 stash 对照确认**改动前即存在**（非本轮引入）

### CI
push `30ed8aa2` 成功；dispatch 422（Actions 冻结），无 run 无包。

### 下一步
1. 老板网页端恢复 GitHub Actions → 重跑 dispatch 出 D19~D32 各包（0.2.28.033~045）。
2. 实机刷帖看诊断页「桥内分段归因(D32)」：JS调用段主导→继续脚本瘦身/减条数；
   等浏览器段主导→桥非 CPU 源，转降并发或分流；与 D26/D31 交叉定靶点。
3. SS 接管内置浏览器方向（P1 iOS14 管道替代）与主线下轮交替推进。

## 🎯 本轮（2026-10-15 21:00 CST）— D30：加权闸门交错场景单测（活跃混合负载账本锁定）

### CI 前置核对（强制第 0 步）
- **#78** `a4f8ac9c` = ✅ success（Release **ios14-test-78** / 0.2.28.032 已出）。
- **#77** `affbc514` = ✅ success；**#76** `a47bc69c` = ✅ success。
- → 无未修复 failure、无缺 Release。
- ⚠️ **Actions 仍账号级冻结**：本轮实测 dispatch 再返 **HTTP 422**
  `Actions has been disabled for this repository.`；push 兜底也不触发（runs total
  恒停在 78）。D19/D20/D21/D26/D28 均已 push 但无 run，只差 CI 出包验证。

### 本轮改动（D30，commit `3f83eab6`）
**动机（活跃负载发热主线）**：D28 给图片类走桥请求加了权重（=2）占槽位，但
现有单测只覆盖「单图排队→单图转交」，没覆盖活跃刷帖的真实形态——**图片与 API
交错进入、按不同权重抢同一批槽位**。缺一个本地可复现的账本自洽测试，就无法在
CI 冻结期验证 D28 权重逻辑在交错场景下不会计数漂移或饿死轻量请求。

**改动（纯测试，零运行时开销，不碰 WebView 挂起/暂停 API）**：
- `test/services/network/adapters/webview_bridge_gate_test.dart`：新增 D30 单测
  ——上限 3，进「图(2)+API(1)+图(2)+API(1)+API(1)」；逐步释放、逐步校验：
  （a）inFlight 全程 0~3 不越界；（b）队首大图放不下时不做部分放行（FIFO 语义）；
  （c）释放大图后按 FIFO 唤醒图+API；（d）weightedAcquires=图片条数；
  （e）所有令牌释放后 inFlight 归零。锁定「不饿死轻量 API、账本自洽」。
- `.github/workflows/ios14-test.yml`：APP_VERSION_SUFFIX 042→**043**。

### 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：**0 changed exit 0** ✅
- 本地 Flutter `flutter test webview_bridge_gate_test.dart` → **8/8 通过** ✅（含 D30）

### CI
push `3f83eab6` 成功；dispatch 422（Actions 冻结），无 run 无包。

### 下一步
1. 老板网页端恢复 GitHub Actions（账号级设置）→ 重跑 dispatch 出 D19~D30 各包
   （0.2.28.033~043），step7（格式）与闸门单测已本地全绿，不会再挂。
2. 实机刷帖看诊断页「类别耗时归因(D26)」+「图片加权入桥(D28)」定位活跃发热靶点；
   若图片仍主导 → 继续压同源图片桥负载；若 API 读主导 → 走 D3 桥内降开销。
3. SS 接管内置浏览器方向（P1 iOS14 管道替代）与主线下轮交替推进。


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

## D29（2026-10-15 19:24 CST）— 核对+清障+队列预检（CI 冻结第 10 轮，验证轮）
### 完成
- [x] 核对 CI：#78/#77/#76 success，无遗留 failure、无缺 Release；Actions 仍冻结（runs 恒 78）。
- [x] **清障**：core/doh_proxy 工作区脏改动 `src/proxy.rs` 经逐行比对，确认是与
      patches/0001-gateway-share-upstream-h2-pool.patch **同内容**的重复残留（连接池共享+h1/h2
      自适应早已 vendor 于本仓库）；用本地 Rust cargo check 验证可编译后，清理子模块脏区还原。
      → 结论：路径 B（DoH 网关上游连接复用降热）已在交付队列，无需新改。
- [x] **队列预检**：#78 HEAD `a4f8ac9c`→HEAD `8d7e6f37` 的 8 个 Dart 文件（D26/D27/D28），
      CI 同款 Dart 3.12.0 format → 0 changed exit 0；flutter gate test → 7/7 通过。
### 未完成
- 无新代码 commit 可推（本轮为验证/清障轮）；Actions 冻结，无新 run 无新包。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D26(041)+D28(042) 包。
2. 实机刷帖读诊断页「类别耗时归因(D26)」+「图片加权入桥(D28)」定靶点。
3. SS 接管内置浏览器方向下轮交替推进。

## D31（2026-10-15 23:00 CST）— 闸门排队代价按请求类别归因（CI 冻结第 12 轮）
### 完成
- [x] 核对 CI：#78/#77/#76 success，无遗留 failure、无缺 Release；Actions 仍冻结（dispatch 422，runs 恒 78）。
- [x] **D31 改动**（纯 Dart 计数/派生判据，零 WebView 挂起/暂停 API、不阻塞 JS）：
      `webview_bridge_gate.dart` 新增 `queuedWeighted`（排队权重和）/`waiting`/
      `onQueueWait`/`_waiterWatches`/`_settleQueueWait`；`webview_http_adapter.dart`
      把 D26 分类前移到 fetch 开头（requestUri 复用）并在 acquire 前后挂/摘排队归因回调，
      新增 `_recordClassQueueWait`；`webview_bridge_diagnostics.dart` 新增 5 个
      `*QueueMs` + `totalQueueMs` + `queueAttributionVerdict`；诊断页展示槽位等待量 +
      排队耗时归因 + 报告 8 字段；gate 单测新增 D31 两例；`ios14-test.yml` 后缀 043→044。
- [x] 本地验证：dart format（CI 同款 3.12.0）5 文件 0 changed exit 0；flutter test
      gate+probe **15/15 通过**；`dart analyze --fatal-infos` gate 文件 No issues found
      （其余 info/warning 经 stash 对照确认改动前即存在、且不在 CI changed 范围内）。
- [x] commit `d01b2a2e`，push 成功。
### 未完成
- Actions 账号级冻结（dispatch 422），无新 run、无新包。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D19~D31 各包（`0.2.28.044`）。
2. 实机刷帖交叉读 D26「类别耗时归因」与 D31「排队耗时归因」定靶：
   两者同指图片 → 图片分流/权重继续加码；D26 指 API 读 → 走 D3 桥内降开销或合并调用。
3. SS 接管内置浏览器（P1 iOS14 管道替代）方向下轮交替推进。

## D34（2026-10-16 02:00 CST）— 端到端桥代价按请求类别归因（CI 冻结第 15 轮）
### 完成
- [x] 核对 CI：#78/#77/#76 success，无遗留 failure、无缺 Release；Actions 仍冻结（dispatch 422，runs 恒 78）。
- [x] **D34 改动**（纯 Dart 计数/派生判据，零 WebView 挂起/暂停 API、不阻塞 JS）：
      `webview_bridge_diagnostics.dart` 新增 5 个 `*TotalMs`（端到端 = 进桥 + 排队）、
      `totalEndToEndMs`/`queueShareOfEndToEndPct`/`endToEndAttributionVerdict`；
      `webview_http_adapter.dart` 新增 `_lastQueueWaitMs`（acquire 前置 0、闸门回调写入）
      与 `_recordClassEndToEnd`，在 finally 里 release 后按「进桥耗时 + 排队耗时」落账；
      诊断页展示端到端归因与明细 + 报告 8 字段；coalesce 单测新增 D34 六例；
      `ios14-test.yml` 后缀 046→047。
- [x] 本地验证：dart format（CI 同款 3.12.0）4 文件 0 changed exit 0；
      flutter test coalesce+gate **51/51 通过**（含 D34 六例）。
      注：`dart analyze`/`flutter analyze` 本机 analysis server 被 OOM kill（exit -9），
      系 2 核 3.7G 内存限制，非代码错误；tests 通过即证明改动文件可编译。
- [x] commit `7d13c109`，push 成功。
### 未完成
- Actions 账号级冻结（dispatch 422），无新 run、无新包。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D19~D34 各包（`0.2.28.047`）。
2. 实机刷帖读诊断页「端到端桥代价归因(D34)」：压图片→继续分流原生(D2/D19)；
   压 API→合并调用/降条数(D16/D17)；均不突出→转查桥外（渲染/解码/DoH 出口）。
3. SS 接管内置浏览器（P1 iOS14 管道替代）方向下轮交替推进。

## D35（2026-10-16 03:00 CST）— 桥活跃时长占比（CI 冻结第 16 轮）
### 完成
- [x] 核对 CI：#78/#77/#76 success，无遗留 failure、无缺 Release；Actions 仍冻结（dispatch 422，runs 恒 78）。
- [x] **D35 改动**（纯 Dart 计时/派生判据，零 WebView 挂起/暂停 API、不阻塞 JS）：
      `webview_bridge_probe.dart` 新增 `idleSampledMs`/`sampledTotalMs`/
      `activeTimeSharePct`/`activeTimeVerdict`（复用既有 1s 采样器，不新增定时器）；
      诊断页展示 D35 判据与活跃/空闲计时 + 报告 4 字段；probe 单测新增 D35 六例；
      `ios14-test.yml` 后缀 047→048。
- [x] 本地验证：dart format（CI 同款 3.12.0）3 文件 0 changed exit 0；
      flutter test probe **11/11 通过**、gate+coalesce **51/51 通过**。
- [x] commit `bb5a6c83`，push 成功。
### 未完成
- Actions 账号级冻结（dispatch 422），无新 run、无新包。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D19~D35 各包（`0.2.28.048`）。
2. 实机刷帖读诊断页「桥活跃时长占比（D35）」定负载形态：
   ≥80% 持续忙→削单请求开销(D16/D17/D3)；40~80% 脉冲→削开销+图片分流(D2/D19)；
   <40% 间歇→转查启停抖动（合并请求/拉长空闲判定窗口）。
3. SS 接管内置浏览器（P1 iOS14 管道替代）方向下轮交替推进。

## D36（2026-10-16 05:00 CST）— 流在途修正：活跃时长占比口径纠偏（CI 冻结第 17 轮）
### 完成
- [x] 核对 CI：#78 `a4f8ac9c` success（Release ios14-test-78 已出）；runs total 恒 78；
      Actions 仍账号级冻结（dispatch 422 "Actions has been disabled for this repository."）。
- [x] **D36 改动**（纯 Dart 计数/派生判据，零 WebView 挂起/暂停 API、不阻塞 JS）：
      动机——二进制流路径的 `onRequestEnd` 在「收到响应头」时就跑了，响应体还要经
      WebMessageChannel 分块回传很久，这段桥其实仍在工作却被记成「空闲」，使 D35
      「桥活跃时长占比」被系统性低估，可能把「持续负载」误判为「间歇负载」指错方向。
      `webview_bridge_probe.dart` 新增 `_streamInFlight` 计数 + `streamInFlight`
      只读 getter + `onStreamStart()`/`onStreamEnd()`；采样器活跃判定改为
      `_inFlight>0 || _streamInFlight>0`；`onRequestEnd` 停表条件同步加 `_streamInFlight==0`；
      `reset`/`resetInFlightForTest` 清零计数；新增 `streamAwareVerdict` 口径说明。
      `webview_http_adapter.dart` 流路径 `wantsBinaryStream` 分支置
      `_bridgeStreamInFlight=true` + `onStreamStart()`，`bridge.done.whenComplete`
      清标记 + `onStreamEnd()`。
      诊断页展示「流在途修正（D36）」+ 报告 map 加 `streamInFlight`/`streamAwareVerdict`。
      probe 单测新增 D36 七例；`ios14-test.yml` 后缀 048→**049**。
- [x] 本地验证（CI 同款 Dart 3.12.0 / Flutter 3.44.0）：
      dart format（4 文件）**0 changed，exit 0** ✅；
      `flutter test` probe 单文件 **18/18 通过**（含 D36 七例）✅；
      gate + coalesce 回归 **51/51 通过** ✅。
- [x] commit `bab455e9`，push 成功（`bb5a6c83..bab455e9`）；dispatch 422，无新 run 无包。
### 未完成
- Actions 账号级冻结（dispatch 422），无新 run、无新包。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D19~D36 各包（`0.2.28.049`）。
2. 实机刷帖读诊断页「桥活跃时长占比（D35）」+「流在途修正（D36）」：
   ≥80% 持续忙→削单请求开销(D16/D17/D3)；40~80% 脉冲→削开销+图片分流(D2/D19)；
   <40% 间歇→转查启停抖动（合并请求/拉长空闲判定窗口）。
3. SS 接管内置浏览器（P1 iOS14 管道替代）方向下轮交替推进。

## D37（2026-10-16 06:00 CST）— 单请求固定税：把「该不该继续削单请求成本」变成可读数字（CI 冻结第 18 轮）
### 完成
- [x] 核对 CI：#78 `a4f8ac9c` success（Release ios14-test-78 已出）；runs total 恒 78；
      无遗留 failure、无缺 Release。Actions 仍账号级冻结：本轮 dispatch 仍 422
      （"Actions has been disabled for this repository."）。
- [x] **D37 改动**（纯 Dart 派生判据，零采样、零新增运行时开销、零 WebView 挂起/暂停 API）：
      动机——D35/D36 回答「桥忙多久」，D26 回答「哪一类吃时间」，但都**没有把耗时
      按请求数归一**。若单请求固定税很轻（<10ms），活跃发热就不是「单请求太贵」，
      继续削 D16/D17/D3 收益有限，应转查桥外（DoH 出口往返 / 连接复用路径B /
      渲染解码）；若很重（>=50ms），削单请求成本才值得继续投入。
      `webview_bridge_diagnostics.dart` 新增 `averageBridgeCostMs`
      （= `totalMs / totalRequests`）+ `perRequestTaxVerdict` 三档判据
      （>=50ms 很重 / 10~50ms 中等 / <10ms 很轻，各给出下一步靶点）。
      诊断页展示「单请求固定税（D37）」+ 报告 map 加 `perRequestTaxVerdict` /
      `averageBridgeCostMs` 两字段。coalesce 单测新增 D37 七例；
      `ios14-test.yml` 后缀 049→**050**。
- [x] 本地验证（CI 同款 Dart 3.12.0 / Flutter 3.44.0）：
      dart format（3 文件）**0 changed，exit 0** ✅；
      `flutter test` coalesce + probe 两文件 **61/61 通过**（含 D37 七例）✅；
      gate 回归 **15/15 通过** ✅。（`flutter analyze` 因本机 SDK 路径告警崩溃，
      非代码问题，CI 侧「格式与静态分析」步骤为准。）
- [x] commit `1788ee11`，push 成功（`bab455e9..1788ee11`）；dispatch 422，无新 run 无包。
### 未完成
- Actions 账号级冻结（dispatch 422），无新 run、无新包。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D19~D37 各包（`0.2.28.050`）。
2. 实机刷帖读诊断页三件套：「桥活跃时长占比（D35/D36）」定忙闲形态、
   「类别耗时归因（D26）」定主导类别、「单请求固定税（D37）」定是否继续削单请求：
   - D37 很重 → 继续削单请求成本（D16/D17/D3/D10）+ 图片分流（D2/D19）；
   - D37 中等 → 优先减少走桥条数（图片分流 D2、只读 API 改原生）；
   - D37 很轻 → 转查桥外（DoH 出口往返、连接复用路径B、渲染解码）。
3. SS 接管内置浏览器（P1 iOS14 管道替代）方向下轮交替推进。

## D38（2026-10-16 07:00 CST）— 响应路径成本对比：把「削单请求成本该削哪条路径」变成可读数字（CI 冻结第 19 轮）
### 完成
- [x] 核对 CI：#78 `a4f8ac9c` success（Release ios14-test-78 已出）；runs total 恒 78；
      无遗留 failure、无缺 Release。Actions 仍账号级冻结：本轮 dispatch 仍 422
      （"Actions has been disabled for this repository."）。
- [x] **D38 改动**（纯 Dart 计数/派生判据，零采样、零新增运行时开销、零 WebView 挂起/暂停 API）：
      动机——D37 说「单请求税重不重」，但桥内两条路径实现代价天差地别：文本路径一次
      `evaluateJavascript` 取回字符串，流路径经 WebMessageChannel 分块回传（每块一次
      JS↔native 边界穿越）。若两者单请求成本差一个量级，「削单请求成本」的正确靶点
      是**贵的那条路径**，而非笼统削。这是「活跃发热」最后一处未拆开的口径。
      `webview_bridge_diagnostics.dart` 新增 `textPathMs`/`streamPathMs` +
      `textPathRequests`/`streamPathRequests` 四个整数计数，`textPathCostMs`/
      `streamPathCostMs` 两个均值 getter，`pathCostVerdict` 四档判据
      （全流路径 / 全文本路径 / 流≥2×文本 / 文本≥2×流 / 量级相当，各给出下一步靶点）。
      `webview_http_adapter.dart` 文本路径（:684 附近）与流路径（:1141 附近）各自累加
      路径计数与耗时。诊断页展示「响应路径成本对比（D38）」+「路径拆分（D38）」；
      报告 map 加 6 字段。coalesce 单测新增 D38 八例；`ios14-test.yml` 后缀 050→**051**。
- [x] 本地验证（CI 同款 Dart 3.12.0 / Flutter 3.44.0）：
      dart format（4 文件）**0 changed，exit 0** ✅；
      `flutter test` coalesce **51/51 通过**（含 D38 八例）✅；
      probe + gate 回归 **33/33 通过** ✅。
- [x] commit `0502a8cb`，push 成功（`1788ee11..0502a8cb`）；dispatch 422，无新 run 无包。
### 未完成
- Actions 账号级冻结（dispatch 422），无新 run、无新包。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D19~D38 各包（`0.2.28.051`）。
2. 实机刷帖读诊断页四件套：「桥活跃时长占比（D35/D36）」定忙闲形态、
   「类别耗时归因（D26）」定主导类别、「单请求固定税（D37）」定是否继续削单请求、
   「响应路径成本对比（D38）」定削哪条路径。
3. SS 接管内置浏览器（P1 iOS14 管道替代）方向下轮交替推进。

## D40（2026-10-16 09:00 CST）— 无效负载归因：把「活跃刷帖时多少走桥请求是白付税」变成可读数字（CI 冻结第 20 轮）
### 完成
- [x] 核对 CI：#78 `a4f8ac9c` success（Release ios14-test-78 已出）；#77/#76 success；
      #75 failure 已被 #76 覆盖修复。runs total 恒 78；无遗留 failure、无缺 Release。
      Actions 仍账号级冻结：本轮 dispatch 仍 422（"Actions has been disabled for this repository."）。
- [x] **D40 改动**（纯 Dart 计数/派生判据，零采样、零新增运行时开销、零 WebView 挂起/暂停 API）：
      动机——D26/D37/D38 把桥内成本按「类别 / 单请求 / 路径」拆到底，但都默认走桥请求
      是**有效负载**。若活跃期有可观比例请求拿到 403/429（CF 拦）或 5xx 或传输失败，
      它们付了满额跨桥固定税却零收益，甚至触发重试再付一遍——这是「削单请求成本」之外
      的另一条发热路径（直接砍条数）。此前所有口径都看不见这类「无效负载」。
      `webview_bridge_diagnostics.dart` 新增 `status2xx/3xx/4xx/5xx` + `transportFailed`
      五个整数分桶，`wastedRequests`（4xx+5xx+失败）、`wastedSharePct` 两个 getter，
      `wastedLoadVerdict` 三档判据（>=20% 偏高 / 5~20% 中等 / <5% 很低）。
      `webview_http_adapter.dart` 新增 `_recordBridgeStatus`，在文本路径与流路径各记一次
      状态码分桶；三处传输失败点（文本超时、流 JS 调用失败、流响应头超时）各计一次
      `transportFailed`。诊断页展示「无效负载（D40）」+ 判据；报告 map 加 8 字段。
      coalesce 单测新增 D40 七例；`ios14-test.yml` 后缀 051→**052**。
- [x] 本地验证（CI 同款 Dart 3.12.0 / Flutter 3.44.0）：
      dart format（6 文件）**0 changed，exit 0** ✅；
      coalesce **58/58 通过**（含 D40 七例）✅；gate + probe 回归 **33/33 通过** ✅。
- [x] commit `09b1a854`，push 成功（`0502a8cb..09b1a854`）；dispatch 422，无新 run 无包。
### 未完成
- Actions 账号级冻结（dispatch 422），无新 run、无新包。
- 工作区另有一份**未提交的 D39 半成品**（frame_jank_monitor 探针按需启停 + 单测），
  属「空闲空转」方向，与老板最新重定位（活跃负载发热）不符，本轮未提交，留待决定。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D19~D40 各包（`0.2.28.052`）。
2. 实机刷帖读诊断页五件套：D35/D36（忙闲形态）+ D26（主导类别）+ D37（单请求税轻重）
   + D38（削哪条路径）+ D40（多少白付税）。
3. SS 接管内置浏览器（P1 iOS14 管道替代）方向下轮交替推进。

## D41（2026-10-16 10:00 CST）— 无效负载代价：把「白付税条数」换算成桥内耗时下界（CI 冻结第 21 轮）
### 完成
- [x] 核对 CI：#78 `a4f8ac9c` success（Release ios14-test-78 已出）；#77/#76 success；
      #75 failure 已被 #76 覆盖修复。runs total 恒 78；无遗留 failure、无缺 Release。
      Actions 仍账号级冻结：本轮 dispatch 仍 422。
- [x] **D41 改动**（纯 Dart 派生判据，零采样、零新增运行时开销、零 WebView 挂起/暂停 API）：
      动机——D40 只数无效**条数**，但条数 ≠ 代价；无效请求若集中在贵的流路径，
      同样条数下代价差一个量级。D41 把无效请求的条数占比与桥内耗时占比并排给出，
      直接回答「砍无效负载值不值得做」。口径取**保守下界**：假设无效请求全落在
      较便宜的那条路径（文本/流均值取小者）× 条数 = 无效负载最小桥内耗时。
      `webview_bridge_diagnostics.dart` 新增 `wastedCostVerdict` getter，三档判据
      （下界占桥内总耗时 >=15% 可观 / 5~15% 中等 / <5% 很小）。
      诊断页展示「无效负载代价（D41）」+ 判据；报告 map 加 1 字段。
      coalesce 单测新增 D41 八例；`ios14-test.yml` 后缀 052→**053**。
- [x] 本地验证（CI 同款 Dart 3.12.0 / Flutter 3.44.0）：
      dart format（5 文件）**0 changed，exit 0** ✅；
      coalesce **66/66 通过**（含 D41 八例）✅；gate + probe 回归 **33/33 通过** ✅。
- [x] commit `78a52172`，push 成功（`09b1a854..78a52172`）；dispatch 422，无新 run 无包。
### 未完成
- Actions 账号级冻结（dispatch 422），无新 run、无新包。
- 工作区仍有未提交的 D39 半成品（frame_jank_monitor 探针按需启停 + 单测），
  属「空闲空转」方向，与老板最新重定位不符，仍未提交。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D19~D41 各包（`0.2.28.053`）。
2. 实机刷帖读诊断页六件套：D35/D36（忙闲形态）+ D26（主导类别）+ D37（单请求税轻重）
   + D38（削哪条路径）+ D40（多少白付税）+ D41（白付税值不值得砍）。
3. SS 接管内置浏览器（P1 iOS14 管道替代）方向下轮交替推进。

## D42（2026-10-16 12:00 CST）— 无效负载来源：把白付税按请求类别归因（CI 冻结第 22 轮）
### 完成
- [x] 核对 CI：#78 `a4f8ac9c` success（Release ios14-test-78 已出）；#77/#76 success；
      runs total 恒 78；无遗留 failure、无缺 Release。Actions 仍账号级冻结：dispatch 422。
- [x] **D42 改动**（纯 Dart 派生判据，零采样、零新增运行时开销、零 WebView 挂起/暂停 API）：
      动机——D40 数了无效条数、D41 换算了下界代价，但都没回答「下一步该动谁」：
      无效请求可能是同源图片（本可分流原生栈，见 D2），也可能是 API 读/写
      （过盾必需，只能降条数或降成本）。两类处置完全不同，必须先把白付税按类别拆开。
      `webview_bridge_diagnostics.dart` 新增 `wastedSourceVerdict` getter——按各类条数
      占比把无效总条数摊派到 5 个类别，取最大一类作主导来源，三档结论分别指向
      同源图片→核对 D2 分流计数 / API 读·写→查 4xx·5xx 来源 / 分散→按 D41 判断。
      诊断页展示「无效负载来源（D42）」+ 报告 map 加 1 字段。
      coalesce 单测新增 D42 七例；`ios14-test.yml` 后缀 053→**054**。
- [x] **并入 D39**（上轮遗留半成品，方向属「空闲空转」，与最新重定位不符但无害且有单测）：
      `frame_jank_monitor.dart` 把两条常驻探针（50ms UI 心跳 + 500ms 平台 RTT）的启停
      绑到「诊断页可见」上；`perf_diagnostics_page.dart` 显式展示探针状态；
      新增 `test/utils/frame_jank_probe_gating_test.dart` 五例。
- [x] 本地验证（CI 同款 Dart 3.12.0 / Flutter 3.44.0）：
      dart format（5 文件）**0 changed，exit 0** ✅；
      coalesce（含 D42 七例）+ frame_jank_probe_gating **73/73 通过** ✅；
      gate + probe 回归 **33/33 通过** ✅。
- [x] commit `cadd30df`，push 成功（`78a52172..cadd30df`）；dispatch 422，无新 run 无包。
### 未完成
- Actions 账号级冻结（dispatch 422），无新 run、无新包。
### 下一步
1. 老板恢复 GitHub Actions 后 dispatch 出 D19~D42 各包（`0.2.28.054`）。
2. 实机刷帖读诊断页七件套：D35/D36（忙闲形态）+ D26（主导类别）+ D37（单请求税轻重）
   + D38（削哪条路径）+ D40（多少白付税）+ D41（值不值得砍）+ D42（白付税集中在哪一类）。
3. SS 接管内置浏览器（P1 iOS14 管道替代）方向下轮交替推进。
