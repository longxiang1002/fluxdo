# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-13 起主攻**：DoH 模式下 App 仍旧发热。

## 🎯 本轮（2026-10-13 05:30 CST）— 路径 C：干掉常驻悬浮性能面板（每秒重建）

### 证据（先证据后改动）

- `main.dart:289` release 下 `pref_perf_diagnostics` 为真 → `FrameJankMonitor.start()`
- `frame_jank_monitor.dart:247` → `unawaited(PerfOverlay.restoreIfEnabled())`（无条件）
- `PerfOverlay.restoreIfEnabled()` 读 `pref_perf_overlay`，为真即 `show()` 插入根 Overlay
- 面板**插入后永不自行移除**；胶囊态每 1s 重建刷新掉帧率；展开态还有 1Hz CPU 采样
- → 用户开过一次诊断就永久背着它，切页也在合成；低端 iOS 上纯白烧电，
  且与上一轮「后台零唤醒」方向直接抵消。**与 DoH 无关**，DoH 开关不会关掉它。

### 本轮改动（commit `b66b391f`，4 文件 +33/-3）

- `lib/widgets/common/perf_overlay.dart`：`showPersistentPill = false`（const）+
  `show()` 首行早退 → 面板永不插入 Overlay。
- `lib/utils/frame_jank_monitor.dart`：`restoreIfEnabled()` 加 `AppLogger.developerMode`
  门禁 → 只有开发者模式自动恢复；开发者行为不变。
- `lib/services/app_logger.dart`：新增 `developerMode` getter（跟随 `verboseEnabled`）。
- **采集不动**：诊断页仍显示实时掉帧记录；需要看数字时把 `showPersistentPill` 改 `true`。
- 版本 `APP_VERSION_SUFFIX` `002 → 003`（0.2.28.003）。

### 硬性禁令遵守
- **不碰 WebView**：只动 Flutter Overlay + 一个 `if` 门禁，不引
  `pauseTimers/resumeTimers`、不引滚动挂起 → 不阻塞 JS 执行，与白屏回归无关。

### 待验
- [x] `dart format --set-exit-if-changed` 通过（改动文件 0 changed）—— **本地预检漏做，见下**
- [x] push + 触发 CI run 35（ios14-test.yml，05:28 CST）
- [x] ~~核对 run 35 出包~~ → **run 35 FAILURE**：挂在 step7「格式与静态分析」，
      `b66b391f` 未跑本地 Dart 3.12.0 预检，`frame_jank_monitor.dart` +
      `perf_overlay.dart` 格式不合 CI → step 8/9/10/12/13 全 skipped，
      **无 IPA、无 Release、ios14-test-35 不存在**。
- [x] 修复并重跑：`d44e30af` `style(ios14): apply dart format 3.12 to unblock CI run 35`
      （Dart 3.12.0 真实 reflow，37 文件 0 changed，零语义改动）
      → workflow_dispatch 触发 **run #36**（id `38311902068`，05:38 CST，in_progress）
- [ ] 核对 run #36 出包 + 记录 `ios14-test-36` Release / IPA 直链（监工中）

### ⚠️ 流程缺陷（待治）
cron 每轮推完代码**不核对上一轮 run 结论**：run 35 挂了整整一夜没人发现，
TODO 里「核对 run 35」一直空着。需要给 cron 加"开工先查上轮 run 结论、
failure 必须先修再推"的强制步骤。

### 前序里程碑
- run **34**(`66264d5d`) ✅ success，Release `ios14-test-34`：
  IPA `fluxdo-ios14-test-34-66264d5d.ipa`（0.2.28.002）
  SHA256 `3f0c8318d518024f0535b0788b03cdf7efac35e14c1aa7bfec6efb81028c0371`

---

## ✅ 已完成（2026-10-13 05:00 CST）— 路径 A：干掉 SystemProxyService 的僵尸 10s 常驻轮询

### 证据（先证据后改动）

`lib/services/network/system_proxy_service.dart:238`：
```dart
static const _refreshInterval = Duration(seconds: 10);
_refreshTimer = Timer.periodic(_refreshInterval, (_) => refresh());
```
- `main.dart:392`：iOS/Windows **无条件** `SystemProxyService.instance.start()`。
- 每次 tick → `refresh()` → iOS 走 `_refreshIos()` →
  `_iosChannel.invokeMethod('effectiveProxyUrl')`（第 257-263 行）→ 原生
  `AppDelegate.swift:39` → `SystemProxyReader.effectiveProxyUrl`
  → **`CFNetworkCopySystemProxySettings()`（阻塞式 CFNetwork 系统调用）**，
  每 10 秒一次，**永久**，且在平台通道（主线程）上。
- 该节拍**没有任何**前台/后台门禁、也没有「值没变就不必再读」的退避：
  就算系统代理设置一整小时没动，仍照读不误 → 纯粹的常驻唤醒（0.1Hz IPC +
  CFNetwork 系统调用），是 DoH 模式下后台/前台都持续的发热/耗电源之一。

补充：`_updateEffective()` 已经做了「值未变则 early-return」，所以**变化检测本身
是廉价的**；真正贵的是那次 CFNetwork 系统调用 + 跨通道 IPC。

### 本轮改动（1 commit）

- `lib/services/network/system_proxy_service.dart`：
  新增**前台门禁 + 懒刷新**：
  - 新增 `pause()` / `resume()`：后台时取消周期定时器，前台恢复时**先立即刷新一次**
    再重挂定时器 → 后台零唤醒；恢复瞬间立即补齐状态，不牺牲正确性。
  - `start()` 保持不变（首次仍会与其它服务并行初始化时读一次真实值）。
  - 轮询周期从 10s 放宽（见改动常量）：iOS 系统代理变化本就有
    `cf_challenge_interceptor` 的显式 `refresh()` 兜底 + 后台/前台风控。
- `lib/main.dart`：在 `didChangeAppLifecycleState` 里接上
  `SystemProxyService.instance.pause()/resume()`（仅 iOS/Windows）。

### 硬性禁令遵守
- **不碰 WebView**：本改动只动系统代理读取节拍，与 WebView JS 执行无关，
  不引 `pauseTimers/resumeTimers`，不引任何滚动挂起逻辑 → 不会重演白屏回归。

### 待验
- [ ] 本地 `dart format` + `dart analyze`
- [ ] push + 触发 CI run（ios14-test.yml）
- [ ] 记录 CI 结果与 Next

---

## 📌 历史里程碑（滚动保留，详见 note/fluxdo-攻坚-progress-log.md）
- `3194ad67` → run 33 ✅ success（app 版本 0.2.28.001，出包链路已通）
- `14022f07` 本地 Rust 网关代理 Shadowsocks（path 前置）
- `d8cd0517` iOS<17 guard 结案：无进程内解

---

## 2026-10-13 05:55 CST — CI 连续两次静默失败修复 + SS 接管诊断（P0）

### CI 连环雷（run 35 → 36）
- **run #35** `b66b391f`：step7 `dart format` 未预检 → 挂，无包无 Release。
- **修复** `d44e30af`：Dart 3.12.0 真实 reflow（37 文件 0 changed）→ 触发 run #36。
- **run #36 又挂**，但**根因换了**：format 已通过（`37 files (0 changed)` ✅），
  卡在同一个 step 的下一步 `dart analyze --fatal-infos`：
  ```
  info - app_logger.dart:82:7  - use_null_aware_elements
  info - app_logger.dart:108:7 - use_null_aware_elements
  2 issues found → exit 1
  ```
  即 `b66b391f` 埋的第二颗雷：collection 字面量里的 `if (x != null) k: x`
  在新 lint 下是 **info 级**，但 CI `--fatal-infos` 让 info 也致命。
  第 7 个文件挂掉，**后 31 个文件未分析**（同类雷未知）。
- **全量排查修复** `c543ea15`：在改动文件集内精确扫出全部同款模式，共修 5 处 / 3 文件：
  | 文件:行 | 改法 |
  |---|---|
  | `app_logger.dart:82,108` | `'tag': ?tag` |
  | `system_proxy_service.dart:133` | `'host': ?e.host` |
  | `system_proxy_service.dart:134` | `'port': ?e.port` |
  | `screen_track.dart:292` | `'screenTrackSourceId': ?debugSourceId` |
  语义等价（null 时同样省略该键）。全量 format 复查 37 文件 0 changed。
- **run #37**（`c543ea15`，id `38313693826`）已触发，监工中。

### SS 接管内置浏览器 — P0 诊断（`f3d5b068`）
已查清全链路**已贯通**，只断在最后一米（详见 cron 提示词「新增并行方向」段）。
本轮落地 **P0 可观测化**：`ios14_network_diagnostics_page.dart` 新增
- 应用内代理配置展示（协议/主机/端口 + 是否启用）
- 配置有效性 + SS 加密算法名（**绝不显示密钥**）
- **网关实际采用的最终上游**（经 `GatewayUpstream.resolve`：应用内代理 > 系统代理 > 直连）
- 显式标注「已启用但配置无效 → 网关仍按直连」
- 显式标注「WebView 未接管时，上游代理对内置浏览器同样无效」
CI 确认该文件 `No issues found!`。报告字段同步扩展 `upstreamConfigured/Protocol/Host/Port/IsValid/Resolved*/Cipher`。

### 本轮结论
两条根因都不是逻辑错，是**工具链纪律**：改完不跑 CI 同款预检（format + analyze --fatal-infos）。
已写入 cron 提示词强制第 0 步 + 第 3 步。
