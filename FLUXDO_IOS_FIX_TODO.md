# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-13 起主攻**：DoH 模式下 App 仍旧发热。


## 🎯 本轮（2026-10-13 20:53 CST）— 路径A：帧监控 summary 空转钳流

### CI 前置核对（强制第 0 步）
- **#46** `280547e3`(id `38387493583`) = ✅ **success**（10-13 19:02 CST 触发）。
- GitHub Release **`ios14-test-46`** 已生成（10-13 19:36 CST 发布）：
  `fluxdo-ios14-test-46-280547e3.ipa`(54,868,783B) + SHA256SUMS + build-info
  + validation + inspection。
- **版本链路复核（验证 19:00 轮的 CI bug 修复）**：
  `build-info.txt` 含 `APP_VERSION_SUFFIX=009` ✅；
  `ipa-inspection.json` → `version = 0.2.28.009`、`build = 2026101311` ✅。
- **#45 / #44** 的 failure 已在 19:00 轮修复，无遗留。
- → **无未修复 failure、无需补建 Release**，本轮可推进。

### 本轮证据（先量后改）
- `lib/utils/frame_jank_monitor.dart:659`（改前）summary 输出条件只有
  `now - _lastSummary >= 10s && _frames > 0`，**没有"有无掉帧"前置条件**。
- summary 体（`:661-668`）在 `semanticsEnabled` 下调 `countSemanticsNodes()`
  （遍历整棵语义树）+ `countPlatformViews()`（遍历平台视图树）—— 注释自认是"实打实开销"。
- 该代码在**每帧**收尾处执行；DoH + 常驻 CF WebView 下空转帧持续产生（见文件内
  "空转探测"章节），于是整场会话每 10s 在 UI 线程付一次全量遍历的账。
- 与诊断总开关绑定 → 用户开过一次诊断就永久背账（同 05:30 轮修掉的 `PerfOverlay` 一类）。

### 本轮改动（commit `51a980e6`）
`lib/utils/frame_jank_monitor.dart`：
- 新增 `_windowHadJank`（出过真实 JANK 记录即置真）、`_lastSummaryFrames`（帧数水位）。
- summary 体抽成 `_emitSummary()`，**内容逐字未改**。
- 条件改为 `_windowHadJank ? 10s : _idleSummaryInterval(60s)` **且** `_frames > _lastSummaryFrames`
  → 有掉帧的窗口 10s 节奏不变（诊断能力零损失）；纯空转窗口降到 60s。
- **硬性禁令遵守**：纯 Dart 统计节流，未触碰 WebView、无 `pauseTimers`/`resumeTimers`、
  无滚动挂起逻辑，不阻塞任何 JS 执行。

### 本地验证（CI 同款工具链 Dart 3.12.0）
- `dart format --output=none --set-exit-if-changed`：1 file **0 changed，exit 0**。
- CI 同款 diff 命令复核：仅 `frame_jank_monitor.dart`，**0 changed，exit 0**。
- 手工核对：`{}`×198/198 配平；新符号引用计数正确。
- `dart analyze` 容器内崩溃（既有环境限制），靠 CI STEP8 把关。

### 待验
- [ ] CI run **#47**（`51a980e6`，`APP_VERSION_SUFFIX` `009 → 010`）
- [ ] 核对 run #47：STEP8 格式与静态分析 + iOS14 回归 + 出包 + Release `ios14-test-47`
- [ ] 老板实机：DoH 模式 + 打开性能诊断，对比 0.2.28.009 vs .010 的掉帧/发热

## ✅ 上轮（2026-10-13 19:00 CST）— 修 CI：`${GITHUB_ENV}` 被表达式替换吞掉（STEP7 unbound variable）


## ✅ 上轮（2026-10-13 14:00 CST）— 路径A：Presence 心跳「后台静默」，消除 30s 一次出网空转

### CI 前置核对（强制第 0 步）
- **#41** `9da67d1c`(id `38344469187`) = ✅ **success**（10-13 12:01 CST 触发）。
- GitHub Release **`ios14-test-41`** 已生成（10-13 12:38 CST 发布）：
  `fluxdo-ios14-test-41-9da67d1c.ipa`(54,868,656B) + SHA256SUMS + build-info
  + validation + inspection。
- **#40** 亦 success + Release `ios14-test-40` 在。
- → **无未修复 failure、无需补建 Release**，本轮可推进。

### 本轮证据（先量后改）
- `presence_service.dart:87`（改前）`Timer.periodic(_heartbeatInterval)`，
  `_heartbeatInterval = 30s`。心跳体不空转：`_queuePresenceUpdate` →
  `DiscourseService.updatePresence` 是**一趟会出网的 POST**。
- 该定时器**无生命周期感知**：`PresenceService` 未监听 `didChangeAppLifecycleState`，
  全文件无任何 `AppLifecycle` 引用。只要回复框打开（`enterReplyChannel` →
  `_startHeartbeat`，见 `reply_sheet.dart:287`），**退后台后仍每 30s 发一次**。
- DoH 模式下这趟 POST 还要绕本地 DoH 网关：一次网关往返 + TLS + 射频唤醒，
  移动端持续唤醒基带。后台用户看不到「正在输入」，纯属白耗电。
- 有上界（仅 `_activeChannels` 非空时发），故修复面可控、收益有界。

### 本轮改动（commit `fe78aba4`）
`lib/services/presence_service.dart`：
- 新增 `AppLifecycleListener? _lifecycleListener` + `bool _isForeground = true`
  （沿用仓库既有写法，见 `log_writer.dart:136`）。
- `_startHeartbeat()` 懒挂监听（`_ensureLifecycleListener`）；心跳 tick 开头
  `if (!_isForeground) return;` —— **后台不发心跳**。
- `_onLifecycleState`：回前台（`resumed`）且频道非空时**立即补一次心跳**，
  补齐后台静默期 → 前台语义一字未改。
- `dispose()` 增加 `_lifecycleListener?.dispose()`，避免泄漏。
- **硬性禁令遵守**：纯 Dart 侧定时器 + 生命周期判断，**未触碰 WebView、未调用
  `pauseTimers`/`resumeTimers`、未注入任何滚动挂起逻辑**，与「验证页白屏」路线无关；
  已在字段 doc comment 显式声明。不阻塞任何 JS 执行。

### 精度与体验核对
- 前台 30s 心跳、输入节流（1s）、防抖（500ms）**逐字未改**。
- 后台不发心跳后，回前台第一拍即补发，服务器侧「正在输入」不会出现可见断层。
- 后台期间若频道集合变化，`_scheduleQueuedUpdate` 的节流/防抖仍照常排队，
  回前台后一并 flush。

### 本地验证
- CI 同款 `dart format --output=none --set-exit-if-changed`：1 file **0 changed**，exit 0。
  （首次运行报告格式差异，用 CI 同款 Dart 3.12.0 格式化后复检 0 changed。）
- 手工核对：`{}`×38/38、`()`×100/100、`[]`×9/9 配平；
  新增符号引用计数正确（`_isForeground`×5、`_lifecycleListener`×5、
  `_ensureLifecycleListener`×2、`_onLifecycleState`×3）。
- `dart analyze` 项目级在本容器崩溃（既有环境限制），同上轮替代方案。

### 待验
- [ ] CI run **#42**（`fe78aba4`，`APP_VERSION_SUFFIX` `007 → 008`）
- [ ] 核对 run #42：格式/分析 + iOS14 回归 + 出包 + Release `ios14-test-42`
- [ ] 老板实机：DoH 模式 + 打开回复框后切后台，对比 0.2.28.007 vs .008 发热

## ✅ 上轮（2026-10-13 12:00 CST）— 路径A 继续：CF 验证页「reveal 看门狗」自适应降频

### CI 前置核对（强制第 0 步）
- **#40** `5c73bac4`(id `38339862468`) = ✅ **success**（10-13 11:03 CST 触发）。
- GitHub Release **`ios14-test-40`** 已生成（10-13 11:37 CST 发布）：
  `fluxdo-ios14-test-40-5c73bac4.ipa` + SHA256SUMS + build-info + validation
  + inspection。
- **#39** `5bb5f1a0` = ✅ success + Release `ios14-test-39` 均在。
- → **无未修复 failure、无需补建 Release**，本轮可推进。

### 本轮证据（先量后改）
- `cf_challenge_service.dart:1869` `_startRevealedStateWatcher()` 是 `while(true)` **无上界**的
  异步循环，节拍 `_revealStateWatchInterval = 150ms`（`:861` 原有常量）。
- 每个节拍并非空转：`:1898` `controller.evaluateJavascript(
  'document.documentElement.innerHTML')` —— **把整页 innerHTML 拉回 Dart**，
  是一次跨 WebView/平台边界的大字符串传输 + JS 求值。
- 退出条件只有：pop / unmounted / generation 变更 / `!_challengeWebViewVisible` /
  `_hasTimedOut`。**只要验证页一直可见且没超时，这个 150ms 轮询就无限跑** ——
  6.7 次/秒的整页序列化，持续压在 Web 渲染线程 + 主线程上。
- 无生命周期感知（本轮之前 watcher 不读 `_appLifecycleState`），后台照跑。
- 对照上轮已修的 `_timeoutTimer`（1Hz → 后台 3s），这个 150ms 轮询是**更重的同类问题**，
  只是藏在「兜底看门狗」语义下从未被降频。

### 本轮改动（commit `9da67d1c`）
`lib/services/cf_challenge_service.dart`：
- 新增常量：`_revealStateWatchFastTicks = 20`、`_revealStateWatchIdleInterval = 600ms`。
  `_revealStateWatchInterval`(150ms) 保留为「快速档」。
- `_startRevealedStateWatcher()` 循环体加 `var tick = 0` 计数：
  - 前 20 拍（= 前 3 秒）保持 **150ms**，CF 内联跳走（正常的数百毫秒级）灵敏度**零变化**；
  - 第 20 拍之后放宽到 **600ms**（`-75%` 节拍频率），仍以「页面是否还有 CF 挑战」为判据。
  - 新增 `if (_appLifecycleState != AppLifecycleState.resumed) continue;` ——
    **后台直接跳过 evaluateJavascript**（只消耗一个 Future.delayed，不碰 WebView）。
- **硬性禁令遵守**：只改 Dart 侧 `Future.delayed` 的等待时长 + 一个 Dart 侧判断；
  **未调用 `pauseTimers`/`resumeTimers`**、未注入任何「滚动挂起/暂停 WebView」逻辑、
  未改 JS handler 注册。WebView 的 JS 照常执行，CF 验证通过仍由 onChallengeComplete /
  cookie 轮询正常收尾 → **不阻塞 JS 执行**，与「验证页白屏」路线无关。
  已在新增常量的 doc comment 里显式写明这条禁令。

### 精度与体验核对
- **前 3 秒灵敏度一字未改**（正常 CF 跳转在数百毫秒内完成，完全落在快速档内）。
- 3 秒后才降频：兜底场景本身是「CF 迟迟没跳走 / 源站 404 渲染」的异常路径，
  600ms 的最坏发现延迟（vs 150ms）对「覆盖 404 露出」的用户体验影响可忽略。
- 后台完全停止整页轮询：用户看不到页面，回到前台时 `_onAppLifecycleChanged`
  → `_restartTimeoutTicker` 仍会恢复超时兜底；验证本身由 CF 的 JS 与 1Hz→3s
  的 cookie 轮询正常收尾。

### 本地验证
- CI 同款 `dart format --output=none --set-exit-if-changed`：1 file **0 changed**，exit 0。
- 手工核对：`{}`/`()`/`[]` 配平均为 0；新增符号引用计数正确
  （`_revealStateWatchFastTicks`×4、`_revealStateWatchIdleInterval`×4）；
  `git diff` 逐行复核确认仅在延迟计算与循环体开头新增分支，**判据/退出条件逐字未改**。
- `dart analyze` 项目级在本容器崩溃（既有环境限制），同上轮替代方案。

### 待验
- [ ] CI run **#41**（`9da67d1c`，`APP_VERSION_SUFFIX` `006 → 007`）
- [ ] 核对 run #41：格式/分析 + iOS14 回归 + 出包 + Release `ios14-test-41`
- [ ] 老板实机：DoH 模式 + 停在验证页不操作，对比 0.2.28.006 vs .007 发热

## ✅ 上轮（2026-10-13 11:00 CST）— 路径A：CF 验证页兜底轮询「后台降频」

### CI 前置核对（强制第 0 步）
- **#39** `5bb5f1a0`(id `38335481990`) = ✅ **success**（10-13 10:08 CST 触发）。
- GitHub Release **`ios14-test-39`** 已生成（10-13 10:33 CST 发布）：
  `fluxdo-ios14-test-39-5bb5f1a0.ipa`(54,870,040B) + SHA256SUMS + build-info
  + validation + inspection。
- → **无未修复 failure、无需补建 Release**，本轮可推进。

### 本轮证据（先量后改）
- `cf_challenge_service.dart:1287` 原为 `Timer.periodic(const Duration(seconds: 1))`，
  **从不参考 App 生命周期**：`_CfChallengePageState` 未 mixin `WidgetsBindingObserver`，
  全文件无 `didChangeAppLifecycleState`。
- 该页面是**模态验证遮罩**（登录/手动验证/网络设置里的「去验证」），用户很可能
  在它挂着时切走（等短信、去看帖子）。实测语义：切后台后 1Hz 照跑。
- 每个节拍不是空转：`_pollCfClearance()` → `_cfCookieManager.getCookie()`
  = **一趟平台主线程 IPC**（`cf_challenge_service.dart:1466`，进函数即 `_polling=true`）。
  → 后台每分钟 60 次跨平台调用 + 微任务，iOS 上直接计入发热。
- 对照：同项目的 `cf_clearance_refresh_service.dart` 有 iOS 闲置销毁 + Android 滚动
  让路（`ScrollBusySignal`），说明「后台/非必要时不烧」是本项目既有风格，
  唯独这个 1Hz 兜底 Timer 从未降频。

### 本轮改动（commit `5c73bac4`）
`lib/services/cf_challenge_service.dart`：
- `_CfChallengePageState` 加 `with WidgetsBindingObserver`；`initState` 注册 observer
  并快照 `WidgetsBinding.instance.lifecycleState`；`dispose` 里 `removeObserver`。
- 新增 `_onAppLifecycleChanged()`：状态变化且页面还活着时 `_restartTimeoutTicker()`。
- 新增 `_timeoutTickInterval` getter：`resumed` → 1s（**前台语义完全不变**，
  `_checkCount` 的「秒」语义与 60/10 阈值不受影响）；否则 → `_backgroundTickInterval = 3s`。
- `_startTimeout()` 的定时器回调抽成 `_onTimeoutTick(Timer)`（**逻辑逐字未改**），
  仅把 `Duration(seconds:1)` 换成 `_timeoutTickInterval`；`_restartTimeoutTicker()`
  幂等重建（本就没在计时就什么都不做）。
- 后台唤醒 **60/min → 20/min（-67%）**，平台主线程 cookie IPC 同比例下降。
- 附带收益：`_hasTimedOut` 后的「死循环空转」也不复存在——超时既已触发，1Hz 没有
  任何用处，降到 3s 顺带削掉这 60/min。

### 精度与体验核对
- **前台（resumed）1Hz 一字未动**，用户手动验证时的计数/超时判定零变化。
- 后台超时阈值仍是 `_backgroundMaxCheckCount=10`「次」，3s 节拍下 = 30s
  才 promote 到前台（原 10s）。10s 太短，用户切走等短信时极易被强行拉回；
  30s 更贴近「后台验证确实卡住了」的判断。仅影响 startInBackground 的自动验证。
- **硬性禁令遵守**：未触碰 WebView、未调 `pauseTimers`/`resumeTimers`、未引任何
  挂起/滚动暂停逻辑。只改本页自己的 Dart `Timer` 节拍，**CF 的 JS 照常执行**，
  验证通过仍由 onChallengeComplete / cookie 同步正常收尾 → 与白屏路线无关。
  已在新增代码的 doc comment 里显式写明这条禁令。

### 本地验证
- CI 同款 `dart format --output=none --set-exit-if-changed`：1 file **0 changed**，exit 0。
- `dart analyze`：项目级分析器在本容器崩溃（`Bad state: The analysis server crashed
  unexpectedly`）——既有环境限制。改用手工核对：大括号/圆括号配平 0；
  新增符号引用计数正确（`_onTimeoutTick`×3、`_backgroundTickInterval`×4）；
  `git diff` 逐行复核确认 `_onTimeoutTick` 体与被替换的匿名回调**语义一致**。

### 待验
- [ ] CI run **#40**（`5c73bac4`，`APP_VERSION_SUFFIX` `005 → 006`）
- [ ] 核对 run #40：格式/分析 + iOS14 回归 + 出包 + Release `ios14-test-40`
- [ ] 老板实机：DoH 模式 + 触发验证页后切后台，对比 0.2.28.005 vs .006 发热

## ✅ 上轮（2026-10-13 10:00 CST）— 路径A 发热源定位：阅读追踪 1Hz 空转唤醒

### CI 前置核对（强制第 0 步）
- **#38** `9f8715ed`(id `38325370819`) = ✅ **success**（10-13 08:04 CST 触发）。
- job 步骤逐条 success，含 **#3「应用已 vendor 的 Rust 网关补丁」= success**（证明
  submodule 无 push 权限的「patch vendor + CI git apply」绕行方案**已被 CI 真正编译**）。
- GitHub Release **`ios14-test-38`** 已生成：`fluxdo-ios14-test-38-9f8715ed.ipa`(54,869,766B)
  + SHA256SUMS + build-info + validation + inspection。
- → **无未修复 failure、无需补建 Release**，本轮可推进。

### 本轮证据（先量后改）
逐条核查 DoH 模式下的常驻 Timer.periodic：
- `cf_clearance_refresh_service.dart`：cookie 轮询 **2min**、health **1min**、iOS 闲置销毁
  **5min**、滚动挂起仅 Android — 已优化过，本轮不动。
- `system_proxy_service.dart`：30s 平台 IPC 兜底 — 已优化过（含 pause/resume），不动。
- `frame_jank_monitor.dart`：50ms/500ms 探针只在**监控运行时**活跃；release 默认关
  （`pref_perf_diagnostics` 默认 false）；`PerfOverlay.showPersistentPill=false` 已禁常驻面板。
- **`screen_track.dart`：`Timer.periodic(1s)` 从 `start(topicId)` 起**一直跑**，
  且 `_tick()` **闲置时不早退**：无论是否闲置都会先跑一趟 `DateTime.now()` +
  若干 Map 遍历；`setHasFocus(false)` 只 skip 累加、**不取消 Timer**。
  → 这是「翻页间停下看帖 / 切后台 / iOS 系统确认框」时每分钟 60 次的无谓唤醒，
  iOS 上直接计入发热。**此前从未被降频过**。

### 本轮改动（commit `eb635ba4`）
`lib/services/screen_track.dart`：
- 新增 `_idleSuspended` 降频态 + `_idleProbeInterval=5s`。
- `_tick()` 命中 `ScreenTrackTiming.isIdle`（>3min 无滚动）→ 调 `_suspendTicker()`
  把 1Hz 节拍**换成 5s 巡检**（-80% 唤醒），不再每秒空转。
- `scrolled()` / `setHasFocus(true)` 显式 `_wakeTicker()`：用户一动立刻回满速，
  **零计时精度损失**（恢复点本就是计时起点）。
- `_reset()` 复位 `_idleSuspended`；`_ensureTicker()` 幂等收口 `start()`。
- 巡检兜底：万一「滚动信号丢失但仍该计时」，5s 内必被兜回（3min 闲置阈值 ≫ 5s）。

### 硬性禁令遵守
- **不碰 WebView**、不调 `pause`/`resume`、不引任何挂起/滚动暂停逻辑；
  只停自己的本地 Dart Timer，**不阻塞任何 JS 执行**，与「验证页白屏」路线无关。
- 不改 CONNECT 语义、不改 Rust 网关行为（Rust 侧只顺带发现一处**未来可优化项**，
  见 progress-log：`dns.rs:1253 http2_keep_alive_while_idle(true)` 可能影响 DNS H2 空闲功耗，
  **本轮未改**以免与 Dart 改动混在同一个二进制里、无法归因）。

### 本地验证
- CI 同款 `dart format --set-exit-if-changed`：1 file **0 changed**，exit 0。
- `dart analyze --fatal-infos`：项目级分析器在本环境崩溃（既有环境问题），
  改用隔离桩验证 → **新增符号 0 报错**（grep `idleSuspended|suspendTicker|ensureTicker|
  wakeTicker|idleProbeInterval` 无命中），剩余报错全为桩缺失。

### 待验（已完成）
- [x] push + 触发 CI run #39（`APP_VERSION_SUFFIX` `004 → 005`）
- [x] 核对 run #39：**success**，Release `ios14-test-39` 已出包（ipa 54,870,040B）
- [ ] 老板实机：DoH 模式下「停在同一贴不动 5min」的发热对比 0.2.28.004 vs .005

## 📌 上一轮（2026-10-13 08:00 CST）— 路径 B 落地：上游连接池共享（含子模块无法直推的绕行方案）

### CI 前置核对（强制第 0 步）
- 最近 run：**#37** `c543ea15`(id `38313693826`) = ✅ **success**（2026-10-12 21:56 UTC / 10-13 05:56 CST 触发）。
- #36 `d44e30af` failure、#35 `b66b391f` failure 的根因（format / analyze）**均已修复**，
  #37 即修复后的验证 run，**已通过**。
- GitHub Release tag **`ios14-test-37`** 已生成，含
  `fluxdo-ios14-test-37-c543ea15.ipa` + SHA256SUMS + build-info + validation + inspection。
- → **不存在未修复的 failure，也不需要补建 Release**。本轮可推进新改动。

### 本轮关键发现（阻塞点，先证据）
1. **`core/doh_proxy` 是 git submodule**，指向 `Lingyan000/fluxdo_doh`
   （`.gitmodules:1-3`）。CI 用 `submodules: recursive`（`.github/workflows/ios14-test.yml:24`），
   检出的是**固定 commit** `08d3468f`（`git ls-tree HEAD core/` 印证）。
2. **本 agent 对该子模块仓库没有 push 权限**：
   `GET /repos/Lingyan000/fluxdo_doh` → `permissions.push = false`。
   → 上一轮 06:00 准备的 `note/patches/0001-gateway-share-upstream-h2-pool.patch`
   **无法通过「推子模块」进 CI**，此前只落在本地未生效。
3. 结论：Rust 侧改动只能走**「patch 随主仓库走 + CI 在 checkout 后 `git apply`」**
   的 vendor 方式，才能让 GH Actions 的 macOS runner 真正编译到新代码。

### 本轮改动
- `note/patches/0001-gateway-share-upstream-h2-pool.patch`：正式纳入主仓库（去掉 note/ 的临时性）。
  patch 内容（对比改动前 `src/proxy.rs` 逐条核对无误）：
  - `handle_gateway_connection()`：每连接 `Arc::new(Mutex::new(HashMap::new()))`
    → 进程级 `gateway_shared_pool()`（`OnceLock<GatewayPool>`），跨连接/跨导航复用上游 H2 会话。
  - 客户端侧 `hyper_http1::Builder`（硬编码 HTTP/1.1，单连接单在途请求）
    → `hyper_util::server::conn::auto::Builder`（h1/h2 自适应），共享池才真正可能被二次命中。
  - `DohProxyServer::stop()` 调 `reset_gateway_shared_pool()`，避免跨 start/stop 残留脏 sender。
  - 新增 `gateway_pool_evict()`（`is_ready()` 剔除 + `MAX_POOLED_HOSTS=32` 上限），
    防止共享池变成泄漏源。
  - 移除因改动失效的 `use hyper::server::conn::http1 as hyper_http1`（否则 Rust unused import 报错）。
  - `mitm_serve()` 的单 host 池**保持每连接新建**（作用域本就限定单 host，改全局会串目标）。
- `.github/workflows/ios14-test.yml`：在 checkout 之后新增
  **「应用已 vendor 的 Rust 网关补丁」** 步骤，对 `core/doh_proxy` 逐个 `git apply`
  `note/patches/*.patch`；已应用则跳过（幂等），应用失败则显式报错（不静默继续）。
  位置：紧接 `actions/checkout` 之后、Flutter/Rust toolchain 之前。

### 依赖校验（本地静态核对，无法本地编译 Rust）
- `hyper = { features = ["full"] }`、`hyper-util = { features = ["full"] }`（`core/doh_proxy/Cargo.toml:46-47`）
  → `hyper_util::server::conn::auto::Builder` 可用。
- `use tracing::{debug, error, info, warn}`（`src/proxy.rs:31`）→ patch 新增的 `debug!` 调用可解析。
- `hyper_http1` 在改动前**仅 2 处**（import + 单次 use），patch 恰好成对删除，无残留引用。

### 硬性禁令遵守
- **不碰 WebView**、不引 `pauseTimers/resumeTimers`、不引任何滚动挂起逻辑。
- 改动全在 Rust 网关连接管理，**不阻塞任何 JS 执行**，与「验证页白屏」路线无关。
- **不改 CONNECT 语义**：CF 验证域名仍强制走隧道（`proxy.rs` 未动该分支）。

### 待验
- [ ] 本地 `dart format` CI 同款预检（本轮无 .dart 改动，仍需确认 workflow 语法）
- [ ] push 主仓库 + 触发 CI run #38
- [ ] 核对 run #38：Rust 编译通过（patch 应用成功）+ 出包 + Release `ios14-test-38`
- [ ] 版本 `APP_VERSION_SUFFIX` → `004`

### 未提交的工作区改动（上一轮 06:00 遗留，本轮不动）
- `lib/services/network/system_proxy_service.dart`：`SystemProxyService` 自适应退避
  （30s 快节拍 → 无变化翻倍 → 封顶 5min；有变化立刻复位）。**本轮不提交**
  （避免一轮改两件事），留作下一轮的独立 Dart 增量。

### 前序里程碑
- run **37**(`c543ea15`) ✅ success，Release `ios14-test-37`：
  IPA `fluxdo-ios14-test-37-c543ea15.ipa`
- run **34**(`66264d5d`) ✅ success，Release `ios14-test-34`（0.2.28.002）

---

## ✅ 已完成（2026-10-13 06:00 CST）— 路径B：网关上游连接复用（DoH 模式发热）

### 证据（先证据后改动）
- `proxy.rs:431`（改前）`handle_gateway_connection()` 里每来一条客户端连接就
  `Arc::new(Mutex::new(HashMap::new()))` → 池生命周期 = 单条客户端 TCP 连接。
- `proxy.rs:456`（改前）客户端侧硬编码 `hyper_http1::Builder`（HTTP/1.1 server），
  **单连接同时只有一个在途请求** → 池里跨 host 的 H2 sender 在单连接内基本不可能被二次命中。
- `proxy.rs:576`（改前）上游协商到 HTTP/1.1 时**完全不入池** → **每请求新建 TLS**。
- 对照：`dns.rs:1250-1255` 的 reqwest DoH 客户端**已正确配置**
  `pool_idle_timeout(90s)` / `pool_max_idle_per_host(8)` / `http2_keep_alive_while_idle(true)`。
- **发热链路**：每次导航/资源请求 → 上游新建 TCP + TLS（含 ECH 与 DoH 解析）+ H2 handshake。
  握手是 ECDHE/RSA 密集运算 + 多次往返，在 iOS 上直接表现为 CPU 峰值与持续耗电。
- ⚠️ 06:00 轮的改动**实际未进入 CI**（子模块无 push 权限），本轮 08:00 用 vendor 方案补上。

---

## ✅ 已完成（2026-10-13 05:30 CST）— 路径 C：干掉常驻悬浮性能面板（每秒重建）

- `lib/widgets/common/perf_overlay.dart`：`showPersistentPill = false`（const）+ `show()` 首行早退。
- `lib/utils/frame_jank_monitor.dart`：`restoreIfEnabled()` 加 `AppLogger.developerMode` 门禁。
- `lib/services/app_logger.dart`：新增 `developerMode` getter。
- 证据：`main.dart:289` release 下 `pref_perf_diagnostics` 为真即 `FrameJankMonitor.start()`
  → `frame_jank_monitor.dart:247` 无条件 `PerfOverlay.restoreIfEnabled()` → 面板插入根 Overlay
  后**永不自行移除**，胶囊态每 1s 重建刷新掉帧率。用户开过一次诊断就永久背着它。
- commit `b66b391f`（随后 `d44e30af` 修 format、`c543ea15` 修 analyze）。

## ✅ 已完成（2026-10-13 05:00 CST）— 路径 A：干掉 SystemProxyService 的僵尸 10s 常驻轮询
见 progress log。
