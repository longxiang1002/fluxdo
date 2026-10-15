# FluxDO 攻坚 · 进度日志

> 格式：`北京时间 | 本轮改动 | commit | CI 状态 | 下一步`
> 时间一律北京时间（UTC+8）。

## 2026-10-14 01:00 CST | 修复 run #50 format 失败（路径D D1 量化后续）

**CI 前置核对（强制第 0 步）**：
- run **#49**（`4ff93fd2` id `38419132192`）= ✅ success（已出包 `ios14-test-49`）；
- run **#48** = ✅ success；
- run **#50**（`cf917903` id `38429318945`）= ❌ **failure** ← 本轮第一优先级。
  拉 job 日志定位（job `115407026971`）：STEP7「格式与静态分析」dart format 未通过 —
  `Formatted 40 files (1 changed) exit 1`，changed 文件 = `lib/services/network/adapters/webview_bridge_diagnostics.dart`。
  根因：commit `4b29c390`（D1 量化画像）引入该文件时**未跑 dart format 就 push**，
  与历史 lesson（run #35 同理）——格式失败无 IPA 无 Release 且整夜无人发现。

**本轮改动**（commit `5edc50f7`，1 文件 +2/-3，纯格式化）：
- `lib/services/network/adapters/webview_bridge_diagnostics.dart`：用 CI 同款 Dart 3.12.0
  （`/tmp/dartsdk312/dart-sdk/bin/dart format`）格式化 —— 仅 static field 行宽折叠 + 补文件尾换行，
  **零逻辑变更**。
- 修复后 format 预检：`git diff e1bd839e HEAD -- '*.dart'` → 40 files **0 changed exit 0** ✅。

**提交/推送/触发**：
- push `fix/ios14-network-thermal` → 成功（`cf917903..5edc50f7`）。
- 重新触发 workflow（`APP_VERSION_SUFFIX` 仍 `013`）→ run **#51**（`5edc50f7` id `38436258785`）。

**CI 状态**：#51 in_progress（本轮 01:00 触发），**待出包确认** → 期望 Release `ios14-test-50`（`0.2.28.013`）。

**下一步**：#51 出包后，老板实机装包 → 诊断页「重置桥统计」→ 刷帖 5–10 分钟
→ 读「图片同源 vs API」请求数/字节量作为 **D2** 判据；若图片同源为主则试 D2 分流到原生 Dio 直连。

---

## 2026-10-13 05:30 CST | DoH 发热路径 C：干掉常驻悬浮性能面板（每秒重建 + 1Hz CPU 采样）

**结论（先证据后改动）**：上一轮（05:00）修掉 `SystemProxyService` 的 10s 常驻轮询后，
继续按路径 C（"把不必要的常驻采样改为仅诊断页开启时"）排查，发现还有一个**与 DoH
无关、纯粹白烧电**的常驻物：`PerfOverlay` 悬浮性能面板。

证据链：
- `lib/main.dart:289`：release 下只要 prefs `pref_perf_diagnostics` 为真就
  `FrameJankMonitor.start()`；`FrameJankMonitor.start()`（`frame_jank_monitor.dart:247`）
  末尾无条件 `unawaited(PerfOverlay.restoreIfEnabled())` → 再读 `pref_perf_overlay`，
  为真就 `show()` 把面板插进**根 Overlay**。
- 面板一旦插入就**永不自行移除**（只有面板上的"隐藏"按钮会 `hide()`）；
  胶囊态每 `Duration(seconds: 1)` 重建一次刷新掉帧率；
  展开态还有 1Hz 的 `sampleThreadCpu()`。
- 后果：用户开过一次诊断就永久背着这个每秒重建的 Overlay，切到任何页面都在合成
  → 低端 iOS 上是实打实的发热源；而且和上一轮「后台零唤醒」的省电方向直接抵消。
- 关键点：**它和 DoH 一点关系都没有**，DoH 开关只影响网络，不会关掉它。

**本轮改动**（commit `b66b391f`，4 文件 +33/-3）：
- `lib/widgets/common/perf_overlay.dart`：新增 `static const bool showPersistentPill = false`；
  `show()` 首行 `if (!showPersistentPill) return;` → 面板**永不**插入 Overlay。
- `lib/utils/frame_jank_monitor.dart`：`restoreIfEnabled()` 调用加
  `if (AppLogger.developerMode)` 门禁 → 只有开发者模式才自动恢复面板，
  开发者行为不变，普通用户不再为一份看不见的诊断数据付发热代价。
- `lib/services/app_logger.dart`：新增 `static bool get developerMode => LogWriter.verboseEnabled`
  （`setVerbose` 已跟随 `prefs['developer_mode']` 注入，`main.dart:358`）。
- **采集逻辑完全不动**：`FrameJankMonitor` 照样跑，诊断页仍能看到实时掉帧记录；
  只是不再往 Overlay 里插常驻 UI。要看数字时把 `showPersistentPill` 改 `true` 重打包。
- **硬性禁令遵守**：只动 Flutter Overlay 与一个 `if` 门禁，**不触碰 WebView、
  不引 `pauseTimers/resumeTimers`、不引任何滚动挂起逻辑** → 不阻塞任何 JS 执行，
  与白屏回归路线无关。
- 版本：`APP_VERSION_SUFFIX` `002 → 003`（上传 0.2.28.003）。

**本轮 CI**：`b66b391f` → run **35**（05:28 CST 触发，in_progress）。
前序 run **34**(`66264d5d`) = ✅ **success**，GitHub Release tag `ios14-test-34` 已生成：
- IPA：`fluxdo-ios14-test-34-66264d5d.ipa`（54,860,621 B，0.2.28.002）
  `https://github.com/longxiang1002/fluxdo/releases/download/ios14-test-34/fluxdo-ios14-test-34-66264d5d.ipa`
- SHA256：`3f0c8318d518024f0535b0788b03cdf7efac35e14c1aa7bfec6efb81028c0371`

**本地验证**：`dart format --set-exit-if-changed` 通过（改动文件 0 changed）✅；
`dart analyze` 本机分析器对 **HEAD 版本也崩**（`Bad state: The analysis server crashed
unexpectedly`，内存不足），非本轮改动引入——以上线 CI（Flutter 3.44 / Dart 3.12，512MB+
可用）的「格式与静态分析」为准确认。

**下一步**：
1. 核对 run 35 出包，记录 `ios14-test-35` Release 与 IPA 直链。
2. 继续路径 A/C：`cf_clearance_refresh_service` 的 `_healthTimer`(1min) 已做
   stale 门禁（idle < 8min 直接 return），但 `_cookiePollTimer`(2min) 仍无门禁 →
   评估是否加同样的 idle 早退；另查 DoH 生效时是否仍需常驻 Turnstile WebView。
3. 复核 `presence_service._heartbeatTimer`(30s，仅 `_activeChannels` 非空时发包) 是否
   有与之匹配的前后台门禁。

## 2026-10-13 05:00 CST | DoH 发热路径 A：干掉 SystemProxyService 僵尸 10s 常驻轮询

**结论（先证据后改动）**：DoH 模式下的一个持续发热源是
`SystemProxyService` 的周期读取——iOS 上每次 tick 是一趟**平台通道 IPC +
阻塞式 `CFNetworkCopySystemProxySettings()` 系统调用**，此前 **10s 一次、
永久运行、无前后台门禁**。系统代理是低频事件，这个 0.1Hz 常驻唤醒是纯浪费。

证据链：
- `lib/services/network/system_proxy_service.dart:238`（旧）`Timer.periodic(10s)`
- `main.dart:392` iOS 无条件 `start()`
- `refresh()` → `_refreshIos()` → `invokeMethod('effectiveProxyUrl')`
- `ios/Runner/AppDelegate.swift:39` → `SystemProxyReader.effectiveProxyUrl`
  → `CFNetworkCopySystemProxySettings()`（阻塞式系统调用）

**本轮改动**（commit `e2bb57ba`）：
- `pause()`/`resume()`：后台停拍（避免后台窗口白耗电）；回前台**立即刷新一次**
  再重挂拍，正确性不降级。
- `_ensureStarted()` 改用 `_refreshTimer != null` 判重，保证 `resume` 能重挂拍。
- 周期 `10s → 30s`：变化时机已由 `cf_challenge_interceptor` 显式 `refresh()`
  与前台 `resume()` 兜住，周期只作「系统设置里手改代理」这类无进程内事件时的兜底。
- `lib/main.dart` `didChangeAppLifecycleState`：`hidden` → `pause()`，
  `resumed` → `resume()`。
- 新增 `test/services/network/system_proxy_service_lifecycle_test.dart`（3 passed）。
- **硬性禁令遵守**：只动轮询节拍，不触碰 WebView/JS 执行，不引
  `pauseTimers/resumeTimers`，与历史滚动挂起白屏路线无关。

**CI**：`e2bb57ba`+`66264d5d` → run **34**（05:53 CST 触发，pending）。
**版本**：APP_VERSION_SUFFIX `001 → 002`（上传 0.2.28.002）。

**本地验证**：`dart format` 0 changed ✅；`dart analyze` 改动文件 No issues ✅；
新测试 3 passed ✅。

**下一步**：
1. 核对 run 34 出包（约 20~40min）。
2. 继续排查 DoH 模式发热：`cf_clearance_refresh_service` 的 `_healthTimer`(1min)
   / `_cookiePollTimer`(2min) 是否在 DoH 生效时仍高频空转；`probeEffectiveProxy`
   是否在每次导航都触发（当前 `webview_page.dart:93`）→ 改为仅诊断页/低频采样。
3. 确认本轮节拍改动不会让「系统代理中途变化」漏检超过 30s。

## 2026-10-09 06:00 CST | 路径 A/B 根因定论 + WebView 接管失败诊断化

**本轮改动**（commit 见下）：
- `lib/services/network/doh/network_settings_service.dart`：
  把 `_applyWebViewProxy()` / `_clearWebViewProxy()` 里**静默 return** 的
  version guard 提取为 `_requiresUnsupportedProxySkips()`，并在 iOS <17 /
  macOS <14 分支**显式打诊断日志**——原来静默返回会让真机排查误以为
  「设置成功但没用」，现在日志能直接证明「iOS 14 内部浏览器裸连、未走 DoH」。
- 新增 `docs/ios14-webview-doh-handoff.md`：三条路径的源码级可行性矩阵 + 路径 C 设计。
- 重建本日志（此前 `note/` 目录在仓库里**从未存在**，历史各轮要求写到这里的内容
  实际都落在了 `FLUXDO_IOS_FIX_TODO.md`）。

**根因定论（源码级核实）**：
1. `setProxyOverride` 在 iOS 14 **物理不可用**——`ProxyManager.swift:9` 标注
   `@available(iOS 17.0, *)`，`InAppWebViewFlutterPlugin.swift:64-66` 只在
   `#available(iOS 17.0, *)` 分支注册 → MethodChannel 从未注册 → `MissingPluginException`
   被 catch 吞掉。底层 `WKWebsiteDataStore.proxyConfigurations` 是 iOS 17 API。
   **→ 原 guard 正确，不可放宽。**
2. `shouldInterceptRequest` 在 iOS **无实现**——`@SupportedPlatforms` 只列
   Android/Windows/Linux，iOS 原生 swift 中 0 处引用。**→ 路径 B 排除。**
3. `CustomSchemeHandler` 只对自定义 scheme 生效，接管不了 `https://`。

**CI**：本轮触发 run（见 TODO）；本地 `dart format` = 0 changed ✅、
parse-only = total_errors=0 ✅。

**下一步**：
- 核对 CI run `37838762957`（`b1a5e341`）step 9/10 的 IPA 出包。
- 路径 C1：核实 iOS 上 DoH 出站是否经系统代理
  （`_applyProxyState()` 里 `GatewayUpstream.resolve(systemProxyUrl:)` 在 iOS 传的是
  `null`，只有 Windows 才传 `SystemProxyService.effectiveProxyUrl`）。

## 2026-10-09 06:00 CST | 遗留 CI 断点关闭

run `37838762957`（commit `b1a5e341`，iOS 销毁式省电）经 jobs API 核对：
- step 7 格式与静态分析 ✅ / step 8 iOS14 兼容与 CF 回归 ✅
- **step 9 构建未签名 IPA ✅ / step 10 上传已检查的测试包 ✅** —— 全绿，断点关闭。

## 2026-10-09 06:00 CST | 本轮 CI

- commit `0c7aad6d` → run `37844039536`（05:03 CST 触发，pending）
- 另一 run `37841469025`（commit `58a2411e`，上轮发布流程改动）仍 in_progress

## 2026-10-09 06:00 CST | 轮内 CI 核对（诚实标注：未出结论）

轮内多次轮询 run `37844039536`（commit `0c7aad6d`）：**始终 pending**，
GitHub 侧尚未分配 runner（本轮 25min 预算内未进入 build）。
另一 run `37841469025`（commit `58a2411e`）为 in_progress。

→ 本地已过 `dart format`（0 changed）与 parse-only（total_errors=0）。
**下一轮第一件事**：核对 `37844039536` 的 step 7/8/9/10 与是否出 IPA。

## 2026-10-09 06:15 CST | 路径 C1 落地：iOS DoH 出站跟随系统代理

**本轮改动**（commit `cbb44e38`，已 push）：
- `lib/services/network/doh/network_settings_service.dart`：新增
  `_systemProxyUrlForGateway()`，Windows **与 iOS** 都把
  `SystemProxyService.effectiveProxyUrl` 传给 `GatewayUpstream.resolve`。
  **根因**：原先 iOS 恒传 `null` → DoH 出站**直连**，而 WKWebView 跟随系统代理
  → 两通道出口 IP 不一致（过盾失败的出口不一致根源）。
  优先级不变：应用代理 > 系统代理 > 直连；VPN/TUN 下返回 null，行为等价。
- `test/services/network/gateway_system_proxy_source_test.dart`（新增，已加入 CI 列表）：
  锁死优先级契约 + 畸形值拒绝 + socks5 识别。
- `.github/workflows/ios14-test.yml` + `.github/scripts/publish_release.sh`（新增）：
  修 CI **假失败**——Release 步骤 403 `Resource not accessible by integration`
  （`contents:write` 已授予仍**间歇**出现）把构建全绿的 job 拖成 failure
  （run `37841469025` / `37844039536`）。改 `continue-on-error` + `RELEASE_TOKEN` 回退。
- `docs/ios14-webview-doh-handoff.md`、`FLUXDO_IOS_FIX_TODO.md`：记录 C1 已实施。

**上轮 CI 核对（结论修正）**：run `37844039536`(`0c7aad6d`) 与 `37841469025`(`58a2411e`)
**并非 pending，而是 completed failure**——但 step 7 格式✅ / 8 兼容✅ /
**9 构建 IPA ✅ / 10 上传 ✅**，**只有 step 12 发布 Release 403 失败**。
即**构建本身是好的**，此前记为「等 CI 出包」的断点已澄清。

**本地校验**：`dart format --set-exit-if-changed` = **0 changed** ✅；
parse-only `total_errors=0` ✅。`flutter test` 本机跑不动（内存/`dart:ui`）→ 交 CI。

**CI**：commit `cbb44e38` → run **`37852245336`**（2026-10-08T22:14:54Z = 06:14 CST 触发，in_progress）。

**下一步**：核对 run `37852245336` 是否**全绿**（含新 Release 步骤）、
是否产出 `ios14-test-N` Release + IPA 直链；老板实机验证出口一致性。

## 2026-10-09 07:00 CST | WebView 出口采样器（路径 C 的前提实证）+ 上轮 CI 全绿确认

**上轮 CI 核对（结论）**：run `37852245336`（commit `cbb44e38`，路径 C1）
→ **completed success，全绿**（step 7 格式✅ / 8 测试✅ / 9 构建✅ / 10 上传✅ /
**13 发布 Release ✅**）。此前「Release 403 假失败」的修复生效。
产物：**Release `ios14-test-18`**，
IPA `fluxdo-ios14-test-18-cbb44e38.ipa`（54.8 MB）
`https://github.com/longxiang1002/fluxdo/releases/download/ios14-test-18/fluxdo-ios14-test-18-cbb44e38.ipa`

**本轮改动**（commit `abcf9ed5`，已 push）：路径 C 只做了「让 DoH 出站跟随系统代理」，
但**没证明过 WKWebView 真的走系统代理**。`SystemProxyReader` 读的是**系统设置**
（`CFNetworkCopySystemProxySettings`），读得到 ≠ App 进程内出口就被它决定
（PAC-only / 进程内有其它代理配置时都不成立）。本轮把前提做成**可实证的采样**：

- `ios/Runner/SystemProxyReader.swift`：新增 `proxyProbeSnapshot()`，
  用 `CFNetworkCopyProxiesForURL`（CFNetwork 栈同一份求值）读**本 App 进程
  真实生效**的代理字典。只回固定字段：`type`（http/https/socks/pac/pacInline/direct）、
  `host`/`port`、`hasPacScript`/`pacIsRemote`（**不含脚本 URL 与正文**）、
  `consistentWithSystem`（与系统设置 host:port 是否一致）。
- `ios/Runner/AppDelegate.swift`：在原 `com.fluxdo/system_proxy` channel 上加
  `proxyProbe` 方法（**不新增 channel**）。
- `lib/services/network/system_proxy_service.dart`：`SystemProxyProbe` /
  `SystemProxyProbeEntry` 模型 + `probeEffectiveProxy()` + `exportJson()`；
  `effectiveExitIsSystemProxy` 给出判定（全部条目都是同一固定代理且与系统设置一致
  → `true`；有 PAC/直连/不一致 → `false`；无条目 → `null` 不冒充成功）。
  脱敏 `describe()` 串直接进日志。
- `lib/pages/webview_page.dart`：`onLoadStop` 时**每次导航采样一次**，打印
  `[DOH] 内部浏览器出口采样: entries=[...] dohGatewayUpstream=...`；
  前提不成立时额外打 `⚠️ WebView 出口未被系统代理决定`。
- `lib/pages/ios14_diagnostics_page.dart`：复制的脱敏报告附带 `webviewExitProbe`。
- `test/services/network/webview_exit_probe_test.dart`（新增，8 例，**本地全过**）+
  已加入 CI 测试列表；`test/pages/ios14_diagnostics_page_test.dart` 适配。

**本地校验**：`dart format --set-exit-if-changed` 对 CI 全量改动集
（30 个 Dart 文件）**0 changed**；parse-only `total_errors=0`；
`flutter test test/services/network/webview_exit_probe_test.dart` **8/8 通过**；
`flutter test test/pages/ios14_diagnostics_page_test.dart` **1/1 通过**。
（`gateway_system_proxy_source_test.dart` 本地跑不了：缺 `lib/l10n/slang/strings.g.dart`
代码生成产物，与本次改动无关，CI 先跑 `project_prep.dart` 所以 CI 侧正常。）

**测试抓到的两个真实 bug（已修）**：`describe()` 用了
`entries.join(',')` → 打出 `Instance of 'SystemProxyProbeEntry'`
（核心证据串不可读），补 `toString()` 并加 `isNot(contains('Instance of'))` 断言；
`pacIsRemote` 语义在测试里被漏传，补断言后暴露并修正用例。

**CI**：commit `abcf9ed5` → run **`37858290951`**（2026-10-09 07:14 CST 触发，queued）。
按历史经验一次 run 20~40min，本轮 25min 预算内等不到结论。

**下一步**：
1. 核对 run `37858290951` 是否全绿、是否产出 `ios14-test-19` + IPA 直链。
2. 老板实机：开启内部浏览器 → 看 `[DOH] 内部浏览器出口采样` 那行
   `exitIsSystemProxy` 是 true 还是 false。
   - `true` → 路径 C 前提成立，两通道出口同源，过盾应不再因出口 IP 不一致失败；
   - `false`（PAC/直连）→ 路径 C 不足以统一出口，需转 `NEPacketTunnelProvider`
     或改「WebView 侧跟随 DoH 而非反过来」的方向。
3. 该采样仅 iOS 生效、失败不影响导航（不引入任何 iOS 暂停/挂起逻辑）。

## 2026-10-09 08:00 CST | 出口「可验证性」补全 + 上轮 CI 失败根因（未出包）

**上轮 CI 核对（结论修正，重要）**：run `37858290951`（commit `abcf9ed5`）
**completed failure**——但**不是** Release 步骤、也**不是**构建问题：
**step 7「格式与静态分析」就挂了**，step 8/9/10/12/13/14 全部 skipped，
**本轮及上轮都没有产出 IPA / Release `ios14-test-19`**。
日志原文（job logs，时间已换算）：
`warning - system_proxy_service.dart:2:8 - Unused import: 'dart:convert' - unused_import`
→ `1 issue found` → `##[error]Process completed with exit code 2`。
即 `dart analyze --fatal-infos` 对**改动文件**把未使用 import 当**致命**错误，
整个 job 在构建前中止。**上轮进度日志把 `ios14-test-18` 当作「最新出包」是对的，
但 `abcf9ed5` 这一轮实际没有任何产物**，已在本次修正。

**本轮改动**（commit `333cc18a` + `27c2200f`，均已 push）：
两个「让 DoH 接管内部浏览器**可被验证**」的缺口补齐：

1. **`webViewProxyApplied` 单布尔值会撒谎**。iOS 14 上「本系统版本没有接管 API」
   与「有 API 但调用失败」都塌缩成 `false`，真机排查无法区分——这正是历史上
   「设置成功但没用」误判的来源。已拆成：
   - `webViewProxyState`：`unsupported` / `not-running` / `attempting` /
     `failed` / `applied` 五态（`network_settings_service.dart`）；
   - `webViewProxyAttempted`：是否**真的发起过**接管调用（而非被 version guard 短路）；
   - `lastWebViewProxyError` + `lastWebViewProxyErrorWasMissingPlugin`：
     `MissingPluginException` 单独分类 → 一句话定性「原生接口未注册」。
   诊断页 `ios14_network_diagnostics_page.dart` 新增 `webViewProxyStateLabel()`
   与对应文案行，报告 JSON 增加 4 个字段。
2. **`route=gateway` 只证明「交给本地网关」，不证明「出口是 DoH」**。
   新增**三态** `DohRouteDiagnostics.dohEgressVerified`
   （`null` = 未采样，**绝不冒充成功** / `true` / `false`），
   由原生采样 `CFNetworkCopyProxiesForURL`（`SystemProxyProbe`）回填：
   - `webview_page.dart` 每次导航采样后调用
     `NetworkSettingsService.recordWebViewEgressEvidence(probe)`，把前提钉进日志与记录；
   - 逐请求路由记录新增 `dohEgressVerified` 字段（仅 `gateway` 路由有意义，
     其余恒 `null`，避免误读）。
   - 判定刻意保守：非 iOS / 无采样数据 → `null`；PAC、直连、与系统设置
     host:port 不一致 → `false`。

**修复上轮 CI 失败**：删除 `lib/services/network/system_proxy_service.dart` 的
未使用 `import 'dart:convert';`（commit `27c2200f`），使 step 7 能过。

**测试**：新增 `test/services/network/doh_egress_verification_test.dart`（8 例，
**本地全过**），锁死「未采样不冒充成功 / 非 gateway 路由不带结论 / 脏值不残留 /
同值不通知 / 已移除监听器不再回调」；已加入 CI step 8 列表。
既有 `webview_exit_probe_test.dart` 8/8、`ios14_diagnostics_test.dart` 3/3、
`ios14_diagnostics_page_test.dart` 1/1 **本地全过**。

**本地校验**：`dart format --set-exit-if-changed` 对 CI 全量改动集（31 文件）
**0 changed** ✅。`dart analyze` 本机受限：容器 2 核 3.7G、**可用内存仅约 1.2G
且无 swap**，对 `webview_page.dart` / `network_settings_service.dart` 等大文件
分析器 **OOM 崩溃**（`analysis server crashed unexpectedly`）；本次新增/小文件
（`doh_route_diagnostics.dart` / `ios14_diagnostics.dart` / `system_proxy_service.dart` /
新测试）**本地 analyze 均 No issues found**。已人工核对：本轮 diff **未新增任何
import**，故未使用 import 这类致命项不可能由本轮引入。

**CI**：commit `27c2200f` → run **`37864683300`**（2026-10-09 08:25 CST 触发，pending）；
同时 run `37864338117`（`333cc18a`）仍 in_progress。
两个 run 里**只有 `27c2200f` 那个的结果才有意义**（后者缺 import 修复）。

**下一步**：
1. 核对 run `37864683300` 的 step 7/8/9/10 与是否出 `ios14-test-19` + IPA 直链。
   step 7 若再挂，优先看是否又是未使用 import/未格式化。
2. 老板实机（装 IPA 后）开内部浏览器，看两行日志：
   - `[DOH] WebView 代理接管跳过：...` → `webViewProxyState=unsupported`（预期）
   - `[DOH] 内部浏览器出口采样: ... exitIsSystemProxy=...` +
     `[DOH] 内部浏览器出口结论: ... egressVerified=...`
     其中 `egressVerified=true` 才说明「内部浏览器与 DoH 出口已确证一致」；
     `false`（PAC/直连）→ 路径 C 不足，转 `NEPacketTunnelProvider` 方向。
3. 诊断页新增文案可直接截图给老板，无需看日志。

## 2026-10-09 09:00 CST | 打通 CI 卡点 + 修掉「出口一致」假阳性 + 路径 C2 可行性定论

**上轮 CI 真实失败原因（已定位，非 Release/构建问题）**：run `37867764680`
（commit `c076fd62`）step 7「格式与静态分析」`completed failure`，exit code 1，
step 8/9/10/12/13/14 全 skipped → **上一轮没有产出 IPA**。
CI 日志原文（已换算北京时间，`01:11:28Z` = `09:11 CST`）：
`info - network_settings_service.dart:1049:31 - Unnecessary braces in a string
interpolation - unnecessary_brace_in_string_interps` → `1 issue found`。
根因：`dart analyze --fatal-infos` 把 **info 级 lint 当致命错误**，而
`debugPrint` 里 `gatewayMode=$isGatewayMode` 的 `$bool` 被 linter 要求去掉花括号，
与 `"$var"`/`'$var'` 引号风格互相打架（`${verified ?? 'unknown'}` 那种写法则必须留）。

**本轮改动**（3 个 commit，已 push）：
1. `c076fd62`：`network_settings_service.dart` 补
   `import 'package:flutter/services.dart' show MissingPluginException;`
   （`333cc18a` 引入 `on MissingPluginException` 却漏 import → 上上轮 CI 挂在这里，
   报 `non_type_in_catch_clause`）；同一处字符串插值去掉多余花括号。
2. `b45d755d`：**修掉「出口一致」假阳性** ——
   `recordWebViewEgressEvidence()` 原样返回 `probe.effectiveExitIsSystemProxy`，
   于是在 iOS 14 + **DoH 关闭（本地网关没跑）** 时，只要进程内是固定系统代理，
   就报 `egressVerified=true`。但那两个通道**都没走 DoH**，
   「出口一致」是伪结论。改为 `_resolveEgressVerified(probe, isGatewayMode:)`：
   网关未运行时恒 `null`（未知，不冒充）；网关在跑才按采样判 true/false。
   debug 行补打 `gatewayMode`，单看真机日志即可区分「未知/已确证」。
   → `docs/ios14-webview-doh-handoff.md` 增加 **C2 可行性定论**（见下）。
3. `a55c6761`：`gatewayMode=${isGatewayMode.toString()}` —— 修 CI 卡点本身。

**路径 C2 可行性定论（本轮调研，源码级）**：
`NEPacketTunnelProvider` 在 TrollStore 环境下**不成立**：
- `ios/Runner/Runner.entitlements` 只有 `com.apple.developer.web-browser`，
  **没有** `com.apple.developer.networking.networkextension`；
- TrollStore 是永久签名注入、不走 Apple provisioning，
  `nesessionmanager` 校验签名里的 networkextension entitlement 拿不到；
- 工程也**没有** Extension target（`NSExtensionPointIdentifier =
  com.apple.networkextension.packet-tunnel`）；
- 且一旦成立会接管**全机**流量，超出「本 App WebView 走 DoH」范围。
→ **剩余可行方向只有 C1**（DoH 出站跟随系统代理，两通道出口 IP 一致），
  其成立前提由 `SystemProxyProbe.effectiveExitIsSystemProxy` 真机采样判定。
  若设备无可用系统代理，则 C1 不成立，只能走「明示未覆盖」等产品层决策。

**CI**：commit `a55c6761` → run **`37868810324`**（09:14 CST 触发，in_progress）。
上一批：`37867764680`（`c076fd62`）failure@step7；`37864683300`（`27c2200f`）
failure@step7（`non_type_in_catch_clause`）。

**下一步**：
1. 核对 run `37868810324` step 7（关键）/8/9/10，确认出 `ios14-test-*` 与 IPA 直链。
   step 7 若再挂，**第一件事**就是拉 job logs 看 `info -`/`error -` 原始行，
   本地只能兜底到 format + parse，`--fatal-infos` 的 lint 本机跑不了
   （`analysis server crashed unexpectedly`，容器可用内存约 1.2G 无 swap）。
2. 老板实机（装 IPA）开内部浏览器，看两行日志：
   - `[DOH] 内部浏览器出口采样: ... exitIsSystemProxy=...`
   - `[DOH] 内部浏览器出口结论: ... egressVerified=? gatewayMode=?`
   只有 `gatewayMode=true` 且 `egressVerified=true` 才说明「两通道同经系统代理」；
   `egressVerified=unknown` = 网关没跑（无意义）；`false` = PAC/直连 → 转产品层决策。

---

## 2026-10-09 10:00 CST · 第 N 轮（DoH 接管内部浏览器）

**方向**：DoH 接管内部浏览器（WebView）。本轮聚焦「解开 CI step7 死循环」+「永久关掉
D 路径（https scheme handler）」。

### 1. 找到 CI step7 连续失败的**真正根因**（此前 4 轮都在治错地方）

- `37868810324`(`a55c6761`) step7 唯一报错：
  `network_settings_service.dart:1057:31 - unnecessary_brace_in_string_interps`
- 上一轮我改的是 **1059 行的 `gatewayMode`**（把双引号换单引号）——**改错了行**，
  所以 `37872559447`(`1e0bc30a`) step7 **一模一样地再挂**
  （日志逐字相同：`1057:31`）。
- 用 Python 逐字符定位 1057 行第 31 列：
  ```
  1057: '[DOH] 内部浏览器出口结论: state=${webViewProxyState} '
                                 ^ col 31 是 $，紧跟的 { 在 col 32
  ```
  → 命中的是 **`${webViewProxyState}`**：内层是**裸标识符**，这正是该 lint 的定义
  （裸标识符不该加花括号）。与 `gatewayMode` 那行无关。
- **教训**：lint 报的是 `line:col`，必须按行列精确定位，不能靠"最近我改过的那行"
  猜。上一轮凭印象改，白烧一个 run。

### 2. 本轮改动（1 commit，已 push）

- `6819d488` `fix(ios14): drop braces around bare identifier interpolation`
  → `state=${webViewProxyState}` 改为 `state=$webViewProxyState`
  （与相邻的 `$probe` / `$_webViewProxyAttempted` 风格一致，日志输出完全不变）

### 3. 本地全量自查（覆盖 CI step7 会 lint 的全部 31 个文件）

- `git diff --name-only --diff-filter=ACMR <step7 基线 e1bd839e> HEAD -- '*.dart'` =
  **31 个文件**（CI 脚本就是这么取的）
- `dart format --output=none --set-exit-if-changed <31 files>` → **0 changed** ✅
- 正则扫 `\$\{裸标识符\}` → **全仓 0 命中** ✅
- 正则扫「单引号串内插值里含双引号字面量」→ 19 处，但 **1059 行已被上轮改成
  单引号**、其余是既有且一直是绿的写法 → 判断为安全
- ⚠️ 本地仍跑不了 `dart analyze`（容器约 1.2G 内存，analysis server 崩），
  lint 只能靠 CI 日志复核

### 4. 路径 D 永久排除（源码级 + Apple 文档级，不再重复调研）

**结论：iOS 上任何 WKWebView 都**不可能**用 `setURLSchemeHandler` 接管 `https`。**
这不只是"本库没实现"，而是 WebKit 的硬约束：

1. **Apple 官方文档**（`WKWebViewConfiguration.setURLSchemeHandler(_:forURLScheme:)`）：
   > It is a programmer error to register a handler for a scheme WebKit already
   > handles, such as `https`, and this method raises an `NSException`
   > (`invalidArgumentException`) if you try to do so.
   → 对 `https` 调该方法 = **直接抛异常崩溃**，不是静默失败。
2. **Dart 侧本库主动 assert 拦截**（`in_app_webview_settings.dart:3487`，两个类各一处）：
   `assert(!resourceCustomSchemes.contains("http") && !contains("https"))`
   → 作者已知此约束，**绝不能绕过**。
3. **iOS 原生侧无过滤**（`InAppWebView.swift:703-706`）：scheme 直接透传给
   `setURLSchemeHandler` → 绕过 Dart assert 必然触发证据 1 的 NSException。
4. **本库自带判定入口印证**（`InAppWebViewManager.swift:36-42`）：暴露
   `WKWebView.handlesURLScheme(urlScheme)`；`https` 恒 true =「WebKit 自己处理」。

→ 路径 B（把 WebView 请求交 Dart 经本地 DoH 代发）在 iOS 上**架构性不成立**：
   WebKit 不提供任何 App 可挂载的 `https` 请求钩子
   （`shouldInterceptRequest` 无 iOS 实现、scheme handler 对 `https` 非法、
   `WKContentRuleList` 只阻断不改写、`proxyConfigurations` 是 iOS 17 API）。
→ 已写入 `docs/ios14-webview-doh-handoff.md`「D 路径定论」章节。
→ **剩余唯一路径仍只有 C1**（DoH 出站跟随系统代理 → 两通道出口 IP 一致）。

### 5. 本轮 CI

- commit `6819d488` → run **`37873771518`**（10:16 CST 触发，in_progress）
- 已挂（待本轮修复验证）：`37872559447`(`1e0bc30a`) / `37868810324`(`a55c6761`)
  / `37869683410`(`0c90792f`) 均 **failure@step7**

### 下一步

1. 核对 run `37873771518` step7 是否终于转绿；绿则等 step 8/9/10/13 出包，
   确认 `ios14-test-*` tag 与 IPA 直链。
2. step7 若**再**挂：先拉 `actions/jobs/<id>/logs`，用**行列号精确**定位新报错
   （本轮教训），别再凭印象改行。
3. 出包后交老板实机：装 IPA → 开内部浏览器 → 看
   `[DOH] 内部浏览器出口结论: ... egressVerified=? gatewayMode=?`，
   需 `gatewayMode=on` 且 `egressVerified=true` 才算「两通道同经系统代理」。

### ✅ step7 破冰（10:26 CST 确认）

run `37873771518`(`6819d488`) **step 7「格式与静态分析」= completed success**，
step 8 已 in_progress —— 连续 4 个 run 卡在这里（`37858290951` / `37864338117` /
`37864683300` / `37867764680` / `37868810324` / `37872559447`）的 CI 死循环**已解开**。
根因就是 `${webViewProxyState}` 裸标识符花括号（1057:31），非 `gatewayMode` 行。
→ 继续等 step 8/9/10/12/13/14，出包后记录 `ios14-test-*` 与 IPA 直链。

---

## 2026-10-09 11:00 CST · 第 N+1 轮（DoH 接管内部浏览器）

**方向**：DoH 接管内部浏览器（WebView）。本轮**首次走到 step 9**，暴露出真正的出包阻塞
（此前 6 个 run 都停在 step 7，误以为 step 7 修好就万事大吉）。

### 1. 事实修正：09:00 轮的「破冰」结论过早

run `37873771518`(`6819d488`) 最终 **failure**：

| step | 名称 | 结果 |
|---|---|---|
| 7 | 格式与静态分析 | ✅ success（裸标识符花括号根因确已修复） |
| 8 | iOS14 兼容与 CF 回归测试 | ✅ success |
| 9 | **构建未签名 IPA** | ❌ **failure** |
| 10/12/13/14 | 上传/重命名/发布 Release | skipped |

→ **仍未出包**。09:00 轮日志「step 8 已 in_progress，等出包」的判断是**基于中间态
的乐观推断**，应记为「待观察」而非「已破冰出包」。

### 2. step 9 真根因：`SystemProxyReader.swift` 两个 Swift 编译错误

日志原文（`actions/jobs/113637504100/logs` 第 1643-1650 行）：

```
Swift Compiler Error (Xcode): 'nil' is not compatible with expected argument type 'CFDictionary'
  .../ios/Runner/SystemProxyReader.swift:67:6
Swift Compiler Error (Xcode): Cannot use optional chaining on non-optional value of type 'Unmanaged<CFArray>'
  .../ios/Runner/SystemProxyReader.swift:68:5
```

出错代码（09:00 轮新加的 `proxyProbeSnapshot()` 内）：

```swift
guard let entries = CFNetworkCopyProxiesForURL(
  probeURL as CFURL,
  nil                       // ← 错 1
)?.takeRetainedValue() as? [[String: Any]] else {   // ← 错 2
```

**因果链**：`CFNetworkCopyProxiesForURL` 的第二个参数在 Swift 里是
**Autorelease 的 `CFDictionary`（非可选）**。传字面量 `nil` 时 Swift 把它桥接成
非可选 `CFDictionary` → 报「'nil' is not compatible」。由于参数已非法，编译器把
**返回值也推断成非可选** `Unmanaged<CFArray>` → 后面跟 `?.` 就报
「Cannot use optional chaining on non-optional value」。
**两个错是同一处写法引发的，不是两个独立缺陷。**
（另注：`CFNetworkCopyProxiesForURL` 标注 `CF_RETURNS_RETAINED`，所以
`takeRetainedValue()` 本身没错，错在 `?.` 与非可选返回值的组合。）

### 3. 本轮改动（1 commit，已 push）

- `b3b2029a` `fix(ios14): make SystemProxyReader compile on iOS 14 (build step9 blocker)`

```swift
// 第二个参数是 Autorelease 的 proxySettings；本项目一律用系统级设置，
// 传 kCFAllocatorDefault 交给 CFNetwork 自己取系统配置。
let entries = CFNetworkCopyProxiesForURL(probeURL as CFURL, kCFAllocatorDefault)
  .takeRetainedValue() as? [[String: Any]]

guard let entries else {
  return [
    "count": 0,
    "systemProxyUrl": systemProxyUrl as Any,
  ]
}
```

- `nil` → `kCFAllocatorDefault`（CFNetwork 自行取系统级代理设置，语义等价且类型合法）
- 返回值显式 `as? [[String: Any]]` → 变成可选，`guard let` 处理空值
- **JSON 输出字段（`count` / `systemProxyUrl` / `entries` / `type` / `probeHost` /
  `host` / `port` / `hasPacScript` / `consistentWithSystem`）全部不变**，纯编译修复，
  Dart 侧 `SystemProxyProbe.fromChannel` 无需改动
- ⚠️ 本地**无 Swift 工具链**（已确认容器无 `swiftc`、无 CoreFoundation 头文件），
  只能靠 CI 验证 → 每次改 Swift 都要预留一个 run 的验证成本
- iOS 14 目标不变（`IPHONEOS_DEPLOYMENT_TARGET = 14.0`、`platform :ios, '14.0'`、
  `SWIFT_VERSION = 5.0`），本改动不含任何需要更高部署目标的 API

### 4. 本轮 CI

- commit `b3b2029a` → run **`37877390735`**（11:02 CST 触发，in_progress）
- 关键观察点：**step 9**。绿 → 等 10/12/13/14 出 `ios14-test-*` + IPA 直链；
  红 → 立刻 `actions/jobs/<id>/logs`，**按 `file:line:col` 精确定位**。

### 下一步

1. 轮内轮询 `37877390735`（最多等到接近 timeout）。
2. 出包后交老板实机：装 IPA → 开内部浏览器 → 看
   `[DOH] 内部浏览器出口结论: ... egressVerified=? gatewayMode=?`，
   需 `gatewayMode=on` 且 `egressVerified=true` 才算「两通道同经系统代理」。
3. 若 step 9 再挂：优先怀疑另外几个自建 Swift 文件
   （`DohProxyCertHandler.swift` / `MediaTranscodeHandler.swift` / `PublicFileHandler.swift`），
   同样拉全文日志按行列号定位。

---

## 2026-10-09 12:00 CST · 第 N+2 轮（DoH 接管内部浏览器）

**方向**：DoH 接管内部浏览器（WebView）。本轮修 **step 9 Swift 编译阻塞的第二轮**——
11:00 轮的修法本身是错的，本轮给出真根因。

### 1. 事实修正：11:00 轮把 `nil` 换成 `kCFAllocatorDefault` 是错的

run `37877390735`(`b3b2029a`) 最终 **failure@step 9**（不是 11:00 轮预估的「可能出包」）：

| step | 名称 | 结果 |
|---|---|---|
| 7 | 格式与静态分析 | ✅ success |
| 8 | iOS14 兼容与 CF 回归测试 | ✅ success |
| 9 | **构建未签名 IPA** | ❌ **failure** |
| 10/12/13/14 | 上传/重命名/发布 Release | skipped |

日志原文（`actions/jobs/113649001266/logs` 第 1685-1686 行）：

```
Swift Compiler Error (Xcode): Cannot convert value of type 'CFAllocator' to expected argument type 'CFDictionary'
  /Users/runner/work/fluxdo/fluxdo/ios/Runner/SystemProxyReader.swift:67:64
```

**真根因**：`CFNetworkCopyProxiesForURL(_:proxySettings:)` 的第二个参数类型是
**`CFDictionary`（代理设置字典）**；`kCFAllocatorDefault` 是 **`CFAllocator`**。
两者名字相似但类型无关，Swift 直接拒绝。
11:00 轮注释里写的「用 kCFAllocatorDefault 替掉 nil：CFNetwork 自行取系统级代理设置，
语义与 CFNetwork 默认 allocator 一致」——**这个判断是错的**：那个位置根本不是 allocator
形参，`kCFAllocatorDefault` 只适用于 `CFXxxCreate(allocator, ...)` 这类显式带 allocator
的构造器。

**同时修正 11:00 轮的第二个误判**：报错只有 **1 个**。此前记的「两个 Swift 编译错误
（`nil` 不兼容 + 可选链用在非可选上）」是把 09:00 轮 `nil` 桥接失效引发的**连带**推断
错误当成了独立缺陷；换成 `kCFAllocatorDefault` 后连带错误自动消失，只剩类型不匹配。

### 2. 本轮改动（1 commit，已 push）

- `ff87b235` `fix(ios14): pass nil as CFDictionary? to CFNetworkCopyProxiesForURL (step9)`

```swift
// 第二个参数是 `CFDictionary?` 的 proxySettings（可空）。
// 显式声明为可选 `CFDictionary?` 再传 nil，既满足类型要求，
// 又让 CFNetwork 自行取当前进程生效的系统级代理配置。
let proxySettings: CFDictionary? = nil
let entries = CFNetworkCopyProxiesForURL(probeURL as CFURL, proxySettings)
  .takeRetainedValue() as? [[String: Any]]
```

- 显式 `CFDictionary?` + `nil` → 类型合法，语义正是本探针想要的
  「本进程真实生效的代理设置」
- **JSON 输出字段全部不变**，Dart 侧 `SystemProxyProbe.fromChannel` 零改动
- `kCFAllocatorDefault` 现在只出现在**注释**里（告诫后来者别再用），调用处已无
- 本地无 Swift 工具链，只能靠 CI 验证（已第三次确认：容器无 `swiftc`）

### 3. 本轮 CI

- commit `ff87b235` → run **`37882148105`**（12:04 CST 触发，in_progress）
- 关键观察点：**step 9**。绿 → 等 10/12/13/14 出 `ios14-test-*` + IPA 直链

### 下一步

1. 轮内轮询 `37882148105`（最多等到接近 timeout）。
2. step 9 若**再**挂：拉 `actions/jobs/<id>/logs`，按 `file:line:col` 精确定位；
   优先怀疑其余自建 Swift 文件（`DohProxyCertHandler.swift` / `MediaTranscodeHandler.swift`
   / `PublicFileHandler.swift`），注意 CI 报的行号可能与本地行号有偏移（本轮即是：
   CI 报 67，本地对应代码在 68-69），**以报错类型为准、别死抠行号**。
3. 出包后交老板实机：装 IPA → 开内部浏览器 → 看
   `[DOH] 内部浏览器出口结论: ... egressVerified=? gatewayMode=?`，
   需 `gatewayMode=on` 且 `egressVerified=true` 才算「两通道同经系统代理」。

---

## 2026-10-09 13:00 CST · 第 N+3 轮（DoH 接管内部浏览器）

**方向**：DoH 接管内部浏览器（WebView）。本轮修 **step 9 Swift 编译阻塞第三轮**——
12:00 轮的修法同样是错的，本轮给出**参数可选性的最终定论**。

### 1. 事实修正：12:00 轮「显式 `CFDictionary?` 传 nil」也是错的

run `37882148105`(`ff87b235`) 最终 **failure@step 9**：

| step | 名称 | 结果 |
|---|---|---|
| 7 | 格式与静态分析 | ✅ success |
| 8 | iOS14 兼容与 CF 回归测试 | ✅ success |
| 9 | **构建未签名 IPA** | ❌ **failure** |
| 10/12/13/14 | 上传/命名/发布 Release | skipped |

日志原文（job `113663990117`，第 1688-1690 行）：

```
Swift Compiler Error (Xcode): Value of optional type 'CFDictionary?' must be unwrapped to a value of type 'CFDictionary'
  /Users/runner/work/fluxdo/fluxdo/ios/Runner/SystemProxyReader.swift:72:64
```

**真根因（第三次踩同一处）**：`CFNetworkCopyProxiesForURL(_:proxySettings:)` 的第二个参数在
Swift 导入时是**非可选**的 `CFDictionary`。三次尝试，三种报错，全部指向同一事实：

| 尝试 | 传法 | CI 报错 | 轮次 |
|---|---|---|---|
| 1 | 字面量 `nil` | `'nil' is not compatible with expected argument type 'CFDictionary'` | 09:00 轮 |
| 2 | `kCFAllocatorDefault` | `Cannot convert value of type 'CFAllocator' to expected argument type 'CFDictionary'` | 11:00 轮 |
| 3 | `let x: CFDictionary? = nil` | `Value of optional type 'CFDictionary?' must be unwrapped to a value of type 'CFDictionary'` | 12:00 轮 |

→ 形参**不可选**，三次「用 nil 表达不指定」的写法在类型系统上全部非法。**必须给真实字典。**

### 2. 本轮改动（1 commit，已 push）

- `64ddaaa0` `fix(ios14): pass empty CFDictionary as proxySettings to CFNetworkCopyProxiesForURL (step9)`

```swift
// 形参非可选；传空字典 → CFNetwork 回落到进程/系统默认代理配置
let proxySettings = [String: Any]() as CFDictionary
let entries = CFNetworkCopyProxiesForURL(probeURL as CFURL, proxySettings)
  .takeRetainedValue() as? [[String: Any]]
```

- **语义论证**：空字典 = 「不指定额外设置」→ CFNetwork 回落到**进程/系统默认**
  代理配置（与 `CFNetworkCopySystemProxySettings` 同源）。这正是本探针要的
  「本进程真实生效的代理」，**不削弱证据强度**
- 文件内写入**三次踩坑注释**，阻止下一个人重复
- **JSON 输出字段全部不变**，Dart 侧 `SystemProxyProbe` 零改动
- 本地无 `swiftc`（已第四次确认），只能靠 CI 验证

### 3. 本轮 CI

- commit `64ddaaa0` → run **`37886570564`**（run #29，13:01 CST 触发，in_progress）

### 下一步

1. 轮内轮询 `37886570564`：关键点仍是 **step 9**。
2. step 9 若**第三次**挂在同一文件：`CFNetworkCopyProxiesForURL` 这条路就地放弃，
   改走**纯 Swift 无 CF 依赖**的等价实现（直接解析 `CFNetworkCopySystemProxySettings`
   返回的字典，字段已由 `effectiveProxyUrl` 证明可用），保证本探针不再阻塞出包。
3. 出包后交老板实机：看 `[DOH] 内部浏览器出口结论: ... egressVerified=? gatewayMode=?`。

---

## 2026-10-09 14:00 CST · 第 N+3 轮（DoH 接管内部浏览器）— 路径 A 结案

**方向**：DoH 接管内部浏览器（WebView）。本轮不再猜 guard，而是把
**路径 A / B / C 全部判死或标注前提未验证**，把可行空间收敛到唯一一条。
期间顺手修掉一处**代码与文档不符**（`probeEffectiveProxy` 的平台门禁）。

### 1. 路径 A 结案：iOS<17 的 `setProxyOverride` guard **必须保留**（三个独立证据）

**(1) 插件原生侧根本没有 iOS<17 实现**
`flutter_inappwebview_ios-1.2.0-beta.3/ios/.../InAppWebViewFlutterPlugin.swift:64`
```swift
if #available(iOS 17.0, *) { proxyManager = ProxyManager(plugin: self) }
```
`ProxyManager.swift:10` 整个类是 `@available(iOS 17.0, *)`；
`setProxyOverride` 的唯一实现是
`WKWebsiteDataStore.default().proxyConfigurations = ...`（ProxyManager.swift:45-49）——
该 Apple API 本身就是 iOS 17 引入（platform_interface 里
`IOSPlatform(apiName: 'WKWebsiteDataStore.proxyConfigurations', available: '17.0')` 明确标注）。
→ iOS 14 上 channel `com.pichillilorenzo/flutter_inappwebview_proxycontroller`
**从未注册**。**放宽 guard 的"收益"是零**：调用必抛 `MissingPluginException`
（正好就是 issue pichillilorenzo/flutter_inappwebview#2265 报的那个）。

**(2) 路径 C 的替代（让 WebView 跟随本 App 自己写的系统代理）在 iOS 上不成立**
本仓库 `ios/Runner/SystemProxyReader.swift` 用 `CFNetworkCopySystemProxySettings()`
/ `CFNetworkCopyProxiesForURL()` —— 这两个读的是**系统全局代理设置**。
iOS 上第三方 App **无权写它**（只有 MDM/描述文件、或 App 自带设置界面的
VPN App 能改）。因此「把 `127.0.0.1:<port>` 塞进系统代理让 WKWebView 跟随」
在 iOS 14 上**没有任何进程内 API 可用**。

**(3) 路径 B（`shouldInterceptRequest` 代发）在 iOS 上不可行**
`flutter_inappwebview_platform_interface-1.4.0-beta.3/lib/src/in_app_webview/platform_webview.dart:1687-1707`
的 `@SupportedPlatforms` 只列 **Android / Windows / Linux**；
`grep -rn "shouldInterceptRequest" flutter_inappwebview_ios-1.2.0-beta.3/ios/`
**0 处命中**——Dart 侧虽有 `"shouldInterceptRequest"` 事件分发
（in_app_webview_controller.dart:555），但 iOS 原生从不发送该事件。
`decidePolicyFor navigationAction` 只给 allow/cancel，**不能改请求**
（InAppWebView.swift:1917 `shouldOverrideUrlLoading`，回调只有 policy）。

### 2. 本轮改动（1 commit `d8cd0517`，已 push）

- `lib/pages/webview_page.dart`：`_logWebViewExitConsistency()` 的采样条件
  由 `Platform.isIOS` 放宽为 `iOS || macOS`。理由：`_systemProxyUrlForGateway()`
  本来就是 **Windows + iOS** 两平台都走「让网关出站跟随系统代理」，
  而 `probeEffectiveProxy()` 的原生实现（CFNetwork 两个 Copy 系列）iOS/macOS 都有
  → macOS 的同一前提此前**没有证据点**。**iOS 行为完全不变**（只是不再早退）。
- `lib/services/network/system_proxy_service.dart`：修正 `probeEffectiveProxy()` 的 doc
  —— 它写「非 iOS 平台返回 null」，但代码是 `if (!Platform.isIOS && !Platform.isMacOS)`
  **代码与文档不符**。改为准确描述 iOS+macOS 门禁，并写明它与
  `_resolveEgressVerified`（**只判 iOS**，因 macOS 走的是 `proxyConfigurations`
  之外的路径）的分工，避免后人把「证据」当「结论」。
- **明确不做**：不放宽 guard、不引 `pauseTimers/resumeTimers`（硬禁令）、
  不在 iOS 侧伪造 `shouldInterceptRequest`。

### 3. 本轮 CI

- commit `d8cd0517` → run **`37891602300`**（14:03 CST 触发，pending）
- 前序 run **`37886570564`**(`64ddaaa0`) = ✅ **success**（13:01 CST，已出 IPA）
  —— step9 CF 签名问题在 13:00 轮由 `64ddaaa0` 修好，**出包链路已通**
- run `37887902403`(`64ddaaa0`) 在本轮开工时仍 in_progress（重复触发，无关紧要）

### 4. 下一步（留给下一轮 / 老板拍板）

1. 等 `37891602300` 结果（按 runner 速度，约 20~40min，基本要下轮核对）。
2. 把路径 A 的**三层结论**固化进
   `lib/services/network/doh/network_settings_service.dart` 里
   `_requiresUnsupportedProxySkips()` 的 doc（现在只写「本函数没法解决」，
   升级为「全平台层面无解 + 唯一替代路径清单」）。
3. 在 `ios14_diagnostics_page.dart` 加一行结论文案：iOS<17 用户必须把
   Clash/代理设为**系统代理**（不只是 TUN 模式），或直接 TUN 全域接管，
   否则内部浏览器一定与 rhttp/Dio 出口不同源。
4. **需老板拍板**：若坚持「进程内接管」，唯一路线是自写
   `WKURLSchemeHandler` 把 `https://` 整页代发（成本高、易破坏登录态）
   或换支持 iOS14 的 webview fork。建议先不做，优先用系统代理保证出口一致。

---

## 2026-10-13 08:00 CST | 路径B 落地：上游连接池共享 —— 并解决「子模块无 push 权限」的绕行

### 0. CI 前置核对（强制第 0 步）
- **#37** `c543ea15`(id `38313693826`) = ✅ **success**；
  #36/#35 failure 的根因（format/analyze）**均已修复**。
- GitHub Release **`ios14-test-37`** 已生成，含 IPA + SHA256SUMS + build-info + validation + inspection。
- → **无未修复 failure、无需补建 Release**，本轮可直接推进。

### 1. 本轮关键发现（此前 06:00 轮改动其实没进 CI）
- `core/doh_proxy` 是 **submodule** → `Lingyan000/fluxdo_doh`（`.gitmodules:1-3`）；
  CI `submodules: recursive`（workflow:24）检出**固定 commit** `08d3468f`。
- `GET /repos/Lingyan000/fluxdo_doh` → **`permissions.push = false`**：
  本 agent **无法推送子模块**。→ 06:00 轮准备的
  `0001-gateway-share-upstream-h2-pool.patch` 一直只躺在本地，**从未被编译**。
- 结论：Rust 改动只能走 **「patch vendor 进主仓库 + CI checkout 后 `git apply`」**。

### 2. 本轮改动（commit `9f8715ed`）
- **新增 `patches/0001-gateway-share-upstream-h2-pool.patch`**（纳入主仓库）：
  - `handle_gateway_connection()`：每连接新建池 → 进程级
    `gateway_shared_pool()`（`OnceLock<GatewayPool>`），跨连接/跨导航复用上游 H2。
  - 客户端侧 `hyper_http1::Builder`（硬编码 H1、单连接单在途）
    → `hyper_util::...::auto::Builder`（h1/h2 自适应）。
  - `stop()` 调 `reset_gateway_shared_pool()`；新增 `gateway_pool_evict()`
    （`is_ready()` 剔除 + `MAX_POOLED_HOSTS=32`），防共享池泄漏。
  - 移除失效的 `hyper_http1` import（否则 unused import 报错）。
  - `mitm_serve()` 单 host 池保持不变（作用域限定单 host，改全局会串目标）。
- **workflow 新增步骤「应用已 vendor 的 Rust 网关补丁」**：checkout 后、
  toolchain 前，对 `patches/*.patch` 逐个 `cd core/doh_proxy && git apply`；
  已应用则跳过（`--reverse --check` 幂等），失败显式报错。
  `APP_VERSION_SUFFIX` `003 → 004`。

### 3. 本地验证（无法编译 Rust，做力所能及的静态核对）
- 用 pin 住的 `08d3468f` 真身 clone 到 `/tmp/patchtest` 模拟 CI：
  `git apply` → **Applied patch src/proxy.rs cleanly**；
  再 `--reverse --check` → 通过（证明 CI 幂等跳过逻辑成立）。
- `Cargo.toml:46-47`：`hyper`/`hyper-util` 均 `features=["full"]` → auto builder 可用。
- `src/proxy.rs:31` 已 `use tracing::{debug,...}` → patch 新增 `debug!` 可解析。
- 改动前 `hyper_http1` 仅 2 处（import + 单次 use），patch 成对删除，无残留引用。
- `dart format` CI 同款预检：37 文件 **0 changed**，exit 0。workflow YAML 解析正常，
  新步骤位于 index 1（checkout 之后）。

### 4. 本轮 CI
- `9f8715ed` → run **38**（id `38325370819`，08:04 CST 触发，in_progress）。
- 若 Rust 编译通过 + 出包 → Release `ios14-test-38`。

### 5. 意外损失（如实记录）
- 本轮开工时工作区有一份 **06:00 轮遗留的未提交 WIP**：
  `system_proxy_service.dart` 自适应退避（30s 快节拍、无变化翻倍、封顶 5min、有变化复位）。
  我在 `git checkout --` 时**误把它一并丢弃**（该 WIP 从未 commit，无法从 git 恢复）。
- 已按当时 diff **逐字重建为 `patches/WIP-0002-system-proxy-adaptive-backoff.txt`**
  （`.txt` 后缀，不会被 CI 的 `*.patch` 误应用），留待后续轮次正式落地。
- 教训：清理工作区前先确认哪些改动是「本轮不要提交」而非「可以删除」，
  应改用 `git stash` 而非 `git checkout --`。

### 6. 下一步
1. 核对 run #38：重点看新步骤「应用已 vendor 的 Rust 网关补丁」是否成功、
   Rust 编译是否通过、是否出 Release `ios14-test-38`。
2. 后续轮次：把 `WIP-0002` 的自适应退避正式实现为 Dart 改动 + 补单测。
3. 老板实机验证：DoH 模式下发热是否下降（对比 0.2.28.004 与 0.2.28.003）。

---

## 2026-10-13 10:00 CST | 路径A 发热源定位 —— 阅读追踪 1Hz 空转唤醒降频

### 0. CI 前置核对（强制第 0 步）
- **#38** `9f8715ed`(id `38325370819`) = ✅ **success**（08:04 CST 触发）。
  - job 步骤 #3「应用已 vendor 的 Rust 网关补丁」= **success** →
    子模块无 push 权限的「patch vendor + CI `git apply`」方案**已被真正编译验证**。
  - 全部 15 步 success，含构建 IPA / 发布 Release。
- Release **`ios14-test-38`** 已生成：
  `fluxdo-ios14-test-38-9f8715ed.ipa`(54,869,766B) + SHA256SUMS + build-info
  + validation + inspection。
- → 无未修复 failure、无需补建 Release，本轮直接推进新改动。

### 1. 本轮排查（先证据，逐条核对常驻 timer）
| 文件 | 周期 | 结论 |
|---|---|---|
| `cf_clearance_refresh_service.dart` | cookie 2min / health 1min / iOS 闲置销毁 5min / 滚动挂起仅 Android | 已优化，不动 |
| `system_proxy_service.dart` | 30s 平台 IPC 兜底 + pause/resume | 已优化，不动 |
| `frame_jank_monitor.dart` | 50ms/500ms | 仅监控运行时活跃；release 默认关；`showPersistentPill=false` |
| **`screen_track.dart`** | **1Hz 常驻** | **问题所在（见下）** |

**`screen_track.dart` 的缺陷（本轮定位）**：
- `Timer.periodic(_tickInterval=1s)` 从 `start(topicId)` 起**一直跑**，
  直到 `stop()`/`abandon()`；
- `_tick()` **命中闲置时不早退**——`isIdle` 只让 `elapsed()` 返回零，
  但之前的 `DateTime.now()`、`_lastFlush += diffDuration`、`rush` 的 Map 遍历
  每秒照跑；
- `setHasFocus(false)`（切后台）只 skip 累加段，**不取消 Timer**。

→ 结果：**翻页间停下看帖 / 切到后台 / iOS 弹出系统确认框**时，
每分钟 60 次无谓唤醒 + 微任务，iOS 上直接计入发热。
对照组：同类的 `frame_jank_monitor` 探针都知道「监控关了就不跑」，
唯独阅读追踪**从未降频**。

### 2. 本轮改动（commit `eb635ba4`）
`lib/services/screen_track.dart`（+/- 见 git）：
- 新增字段 `bool _idleSuspended`、常量 `_idleProbeInterval = Duration(seconds: 5)`。
- `_tick()`：命中 `ScreenTrackTiming.isIdle`（>3min 无滚动）→ `_suspendTicker()`，
  把 1Hz 节拍**降为 5s 巡检**（**唤醒 -80%**）。
- 新增 `_suspendTicker()` / `_wakeTicker()` / `_ensureTicker()`，均幂等。
- `scrolled()` 与 `setHasFocus(true)` 显式 `_wakeTicker()` → 用户一动**立即回满速**，
  **零计时精度损失**（恢复点即计时起点，无补算需求）。
- `_reset()` 复位 `_idleSuspended`；`start()` 用 `_ensureTicker()` 收口。

### 3. 硬性禁令遵守（逐条核对）
- 未触碰 WebView；未调用 `pauseTimers`/`resumeTimers`；未引任何滚动挂起逻辑。
  仅停/建**本对象自己的 Dart `Timer`**，不影响任何 JS 执行 → 与「验证页白屏」无关。
- `_updateScrollPause()` 仍只在 `io.Platform.isAndroid` 生效（已复核 `:732` 早退），
  iOS 路径零改动。
- 未改 CONNECT 语义、未改 Rust 网关。

### 4. 本地验证
- CI 同款 `dart format --output=none --set-exit-if-changed`：**1 file, 0 changed**, exit 0。
- `dart analyze --fatal-infos`：**项目级分析器在本容器崩溃**
  （`Bad state: The analysis server crashed unexpectedly`）——既有环境限制，
  非本轮引入。改用「隔离桩 + 单文件」分析：剩余报错**全是桩缺失**
  （缺 flutter package / 路径桩），grep 新增符号
  `idleSuspended|suspendTicker|ensureTicker|wakeTicker|idleProbeInterval` → **0 报错**。

### 5. 本轮 CI
- 触发 run **#39**（`eb635ba4` + `5bb5f1a0`，`APP_VERSION_SUFFIX` `004 → 005`）。
- 待核对：格式/分析 → iOS14 回归 → 构建 → Release `ios14-test-39`。

### 6. 本轮顺带发现（**未改，留给后续轮**）
- `core/doh_proxy/src/dns.rs:1253` `http2_keep_alive_while_idle(true)` +
  `:1254` `http2_keep_alive_timeout(10s)`：DNS 解析用的 H2 通道在**空闲时仍每 30s
  发 keep-alive PING**。DNS 查询是低频事件，这个空闲心跳可能让 DoH 连接永不回收、
  持续小功耗。**本轮不顺手改**：Dart 改动与 Rust 改动若混进同一个二进制，
  老板实机测出发热变化将**无法归因**是哪一个起效。留作下一轮单独立项的候选。
- 教训延续：同一轮只动「一类改动」，保证变量可归因。

### 7. 下一步（下一轮候选）
1. 核对 run #39 出包 + Release `ios14-test-39`。
2. 若 #39 绿：立项「DNS H2 keep-alive 空闲心跳」单独一轮（Rust patch，可归因）。
3. 继续扫 `cf_challenge_service.dart:1287` 的 1s 超时轮询
   （`_pollCfClearance()` 每秒一趟）——验证期外是否也可能常驻。

---

## 2026-10-13 11:00 CST — 路径A：CF 验证页兜底轮询「后台降频」

**CI 前置核对**：run #39 `5bb5f1a0`(id `38335481990`) = ✅ success；
Release `ios14-test-39` 已发布（10-13 10:33 CST，ipa 54,870,040B + 四个附件）。
无未修复 failure、无需补建 Release。

**本轮改动** | commit `5c73bac4` | `lib/services/cf_challenge_service.dart` +
`.github/workflows/ios14-test.yml`（`APP_VERSION_SUFFIX` 005 → 006）

**证据（先量后改）**
- `cf_challenge_service.dart:1287` 原 `Timer.periodic(const Duration(seconds:1))`，
  `_CfChallengePageState` **没有** `WidgetsBindingObserver`、全文件无
  `didChangeAppLifecycleState` → 切后台后 1Hz 照跑。
- 每个节拍不空转：`_pollCfClearance()`(`:1466`) → `_cookieManager.getCookie()`
  = 一趟**平台主线程 IPC**。后台 60 次/分 + 微任务，iOS 计入发热。
- 验证页是模态遮罩（登录 / 手动验证 / 网络设置），用户极易挂后台 → 命中率高。

**改动**
- 加 `with WidgetsBindingObserver` + `initState` 注册 / `dispose` 反注册；
  `_appLifecycleState` 快照 `WidgetsBinding.instance.lifecycleState`。
- `_timeoutTickInterval`：`resumed` → **1s（前台一字未改）**，否则 → **3s**
  （`_backgroundTickInterval`）。后台唤醒 60/min → **20/min（-67%）**。
- 定时器回调从匿名闭包抽成 `_onTimeoutTick(Timer)`，**逻辑逐字未改**；
  `_restartTimeoutTicker()` 幂等重建；`_startTimeout()` 只换节拍常量。
- 附带：`_hasTimedOut` 之后的「死循环空转」一并削掉（超时后 1Hz 毫无用处）。

**精度/体验**：前台 1Hz 零变化；后台超时由 10s → 30s 才 promote
（10s 太短，切走等短信会被强行拉回，30s 更合理）。仅影响 `startInBackground`。

**硬性禁令**：未碰 WebView；未调 `pauseTimers`/`resumeTimers`；未引滚动挂起。
只改本页自己的 Dart Timer，**不阻塞任何 JS 执行**，与「验证页白屏」路线无关。

**本地验证**：CI 同款 `dart format --set-exit-if-changed` → **1 file 0 changed**
exit 0；`dart analyze` 项目级分析器在本容器崩溃（既有环境限制），
改以括号配平 + 新增符号引用计数 + `git diff` 逐行复核代替。

**本轮 CI**：触发 run **#40**（`5c73bac4`，`APP_VERSION_SUFFIX` `005 → 006`）。

**下一步**
1. 核对 run #40 出包 + Release `ios14-test-40`。
2. 老板实机：DoH + 触发验证页后切后台，对比 0.2.28.005 vs .006。
3. 仍未动的候选（留后续单轮）：
   - `cf_challenge_service.dart:1811` `_startRevealedStateWatcher` 的
     `while(true)` + 150ms `evaluateJavascript` 常驻（仅 iOS/Android 有用，
     且没有「切后台降频」）——**注意：改 JS 探测频率属于触碰 WebView 交互，
     需单独论证不阻塞 JS，且要用页面可见性而非挂起**。
   - `cf_challenge_service.dart:1857` `_startChallengeRevealProbe` 的 250ms 轮询
     （有 20 次硬上界，风险低）。
   - `dns.rs:1253` `http2_keep_alive_while_idle(true)`（Rust，单独一轮，便于归因）。

---

## 2026-10-13 12:00 CST（北京时间）｜路径A：CF 验证页 reveal 看门狗自适应降频

**CI 前置核对（强制第 0 步）**
- **#40** `5c73bac4`(id `38339862468`) = ✅ **success**；Release `ios14-test-40`
  已发布（`fluxdo-ios14-test-40-5c73bac4.ipa` + SHA256SUMS + build-info +
  validation + inspection）。#39 亦 success + Release 在。
- → **无未修复 failure、无需补建 Release**，可推进。

**证据（先量后改）**
- `cf_challenge_service.dart:1869` `_startRevealedStateWatcher()` = `while(true)`
  **无上界**异步循环，节拍 `_revealStateWatchInterval = 150ms`（`:861`）。
- 每拍 `:1898` `controller.evaluateJavascript('document.documentElement.innerHTML')`
  —— **整页 innerHTML 跨边界拉回 Dart**（大字符串 JS 求值 + 传输），
  **6.7 次/秒**。只要验证页可见且未超时，就无限跑，且无生命周期感知（后台照跑）。
- 比上轮修的 `_timeoutTimer`(1Hz) 更重：同源同类问题，只是藏在「兜底看门狗」语义下。

**改动（commit `9da67d1c`，`lib/services/cf_challenge_service.dart` + workflow）**
- 新增 `_revealStateWatchFastTicks = 20`、`_revealStateWatchIdleInterval = 600ms`；
  循环加 `tick` 计数：前 20 拍（≈3s）保持 **150ms**（正常 CF 跳转在数百 ms 内，
  灵敏度零变化），之后放宽到 **600ms（-75%）**。
- 新增 `if (_appLifecycleState != AppLifecycleState.resumed) continue;`：
  **后台不跑 evaluateJavascript**（回到前台由 `_onAppLifecycleChanged` 恢复兜底）。
- **禁令遵守**：仅改 Dart 侧 `Future.delayed` 时长 + Dart 侧判断；
  **无 `pauseTimers`/`resumeTimers`**、无滚动挂起、未改 JS handler 注册。
  WebView 的 JS 照常执行 → 不阻塞 JS，与白屏路线无关。已在 doc comment 显式声明。

**本地验证**：CI 同款 `dart format --set-exit-if-changed` → 1 file **0 changed**，exit 0；
括号配平 0；新增符号引用计数正确；`git diff` 复核判据/退出条件逐字未改。
`dart analyze` 项目级仍在本容器崩溃（既有环境限制），沿用替代核对。

**本轮 CI**：触发 run **#41**（`9da67d1c`，`APP_VERSION_SUFFIX` `006 → 007`）。

**下一步**
1. 核对 run #41 出包 + Release `ios14-test-41`。
2. 老板实机：DoH + 停在验证页不操作，对比 0.2.28.006 vs .007 发热。
3. 仍未动的候选（留后续单轮）：
   - `cf_challenge_service.dart` `_startChallengeRevealProbe` 的 250ms 轮询
     （有 20 次硬上界，风险低，收益也小）。
   - `presence_service.dart:87` 30s 心跳（`_queuePresenceUpdate`，含网络上报）
     —— 值得单轮量一下 DoH 模式下是否必要。
   - `dns.rs:1253` `http2_keep_alive_while_idle(true)`（Rust，单独一轮，便于归因）。

---

## 2026-10-13 14:00 CST（北京时间）｜路径A：Presence 心跳「后台静默」

**CI 前置核对（强制第 0 步）**
- **#41** `9da67d1c`(id `38344469187`) = ✅ **success**；
  Release `ios14-test-41` 已发布（10-13 12:38 CST，ipa 54,868,656B + 四附件）。
  #40 亦 success + Release 在。→ **无未修复 failure、无需补建 Release**，可推进。

**证据（先量后改）**
- `presence_service.dart:87`(改前) `Timer.periodic(_heartbeatInterval)`，
  `= 30s`。心跳体是**一趟会出网的 POST**（`_queuePresenceUpdate` →
  `DiscourseService.updatePresence`）。
- **无生命周期感知**：`PresenceService` 不监听 App 生命周期、全文件无
  `AppLifecycle` 引用；只要回复框打开（`reply_sheet.dart:287`
  `enterReplyChannel` → `_startHeartbeat`），**退后台后仍每 30s 发一次**。
  DoH 模式下该 POST 还要绕本地网关（网关往返 + TLS + 射频唤醒）。
- 有上界（仅 `_activeChannels` 非空时发）→ 修复面小、收益有界。

**改动（commit `fe78aba4`，`lib/services/presence_service.dart` + workflow）**
- 加 `AppLifecycleListener? _lifecycleListener` + `bool _isForeground`
  （沿用 `log_writer.dart:136` 既有写法）；`_startHeartbeat` 懒挂监听；
  心跳 tick 开头 `if (!_isForeground) return;` → **后台不发心跳**。
- `_onLifecycleState`：回前台且频道非空时**立即补一次**，补齐静默期；
  `dispose()` 增加 listener 释放。前台 30s / 1s 节流 / 500ms 防抖**逐字未改**。
- **禁令遵守**：纯 Dart 定时器 + 生命周期判断，**不碰 WebView、无
  `pauseTimers`/`resumeTimers`、无滚动挂起**，与「验证页白屏」路线无关。

**本地验证**：CI 同款 `dart format --set-exit-if-changed`（Dart 3.12.0）→
先报格式差异，用 CI 同款 SDK 格式化后 **0 changed**，exit 0；
`{}`×38/38、`()`×100/100、`[]`×9/9 配平；新增符号引用计数正确。
`dart analyze` 项目级仍在本容器崩溃（既有环境限制），沿用替代核对。

**本轮 CI**：触发 run **#42**（`fe78aba4`，`APP_VERSION_SUFFIX` `007 → 008`）。

**下一步**
1. 核对 run #42 出包 + Release `ios14-test-42`。
2. 老板实机：DoH + 打开回复框后切后台，对比 0.2.28.007 vs .008 发热。
3. 仍未动的候选（留后续单轮）：
   - `cf_challenge_service.dart` `_startChallengeRevealProbe` 250ms 轮询
     （20 次硬上界，收益小）。
   - `dns.rs:1253` `http2_keep_alive_while_idle(true)`（Rust，单独一轮便于归因）。
   - 路径B：DoH 通道连接复用（rhttp/Dio 是否每请求新建连接）。
   - SS 代理接管内置浏览器（并行方向 P0：能力诊断可观测化）。

---

## 2026-10-13 15:00 CST（北京时间）｜CI 修复：版本后缀被表达式替换吞掉（卡死 008 → 009）

**CI 前置核对（强制第 0 步）**
- **#43** `befa861c`(id `38356207263`) = ✅ **success**（10-13 14:21 CST 触发）。
  Release **`ios14-test-43`** 已发布（14:57 CST）：`fluxdo-ios14-test-43-befa861c.ipa`
  (54,868,793B) + SHA256SUMS + build-info + validation + inspection（5 附件齐）。
- **#42** `fe78aba4` = ❌ failure（**已修复**，非新问题）：step8「格式与静态分析」
  里 `dart analyze --fatal-infos presence_service.dart` 报
  `unnecessary_import`（`import 'package:flutter/foundation.dart'` 冗余），
  `befa861c` 已删除该导入并通过 → **无未修复 failure**。
- 无需补建 Release。→ 本轮可推进。

**本轮发现（核对过程中挖出的系统性缺陷）**
- 核对 #41/#43 的 `app 显示版本` 日志行与 Release 里的 `ipa-inspection.json`：
  | run | 声称版本 | 实际 version | 结论 |
  |-----|---------|-------------|------|
  | #39 | .005 | 0.2.28.005 | ✅ |
  | #41 | .007 | 0.2.28.007 | ✅（suffix 恰为 007，未暴露）|
  | #42 | — | 无包（step8 挂） | — |
  | #43 | .008 | 0.2.28.008 | ✅ 但**本应为 009** |
- 根因：`.github/workflows/ios14-test.yml` 第 113 行（改前）
  `APP_VERSION_SUFFIX="${APP_VERSION_SUFFIX:-008}"`，与第 148 行
  `NEWNAME="fluxdo-ios14-test-${{ github.run_number }}-${SHORT}.ipa"` **同在
  「构建未签名 IPA」这一个 run 块内**。GitHub 对含 `${{ }}` 字面量的 run 块
  整体做表达式替换时，会连带吞掉同一块里未被保护的花括号变量引用 →
  `${APP_VERSION_SUFFIX:-008}` 退化成纯文本 `APP_VERSION_SUFFIX:-008`，
  于是**静默取默认值 008**；`${SHORT}` 同样被吞成空串（由紧随其后的 `sed`
  兜回 commit 短 hash 才没暴露）。
- **后果**：只要不改，后续每一轮的版本后缀都会被压回 `008`，老板**无法区分
  新旧安装**——这正是「版本号递增小版本」规则想解决却实际失效的地方。
- 教训：靠人肉读日志核对版本号是不可靠的（我此前几轮都只看了 `dart format`
  与 `conclusion`，没对 `ipa-inspection.json` 的 `version` 字段）。

**本轮改动（commit `f98045d3`，仅 CI，2 文件）**
- `.github/workflows/ios14-test.yml`：
  1. `APP_VERSION_SUFFIX` 改为**纯字面量** `"009"`，彻底不依赖 `:-` 默认值语法。
  2. 「项目准备及工具信息」步骤增写 `echo "APP_VERSION_SUFFIX=..." >> dist/build-info.txt`
     —— 版本号从「日志里的一句话」变成**随 Release 发布的 artifact 字段**，可核对。
  3. 在 suffix 步骤与重命名步骤加注释标记该 run 块的花括号陷阱，防回归
     （注释里刻意不写 `${{ }}` 字面量——见下方事故）。
- `.gitignore`：追加 `*_TODO.md`（session 本地计划文件不入库）。

**⚠️ 本轮一次自伤事故（已修复，如实记录）**
- 首次 push 的 `a0995972` **把 workflow 改坏了**：我在注释里写了
  `${{ }}` 字面量，被 GitHub 当成表达式解析，dispatch 直接 422
  `An expression was expected`，run #44 随之 failure（无包、无 Release）。
- 修复方式：把注释里的 `${{ }}` 全部去掉，改用「双花括号表达式」等文字描述；
  并用正则全量扫描文件，确认剩余的 `${{ }}` **全部是合法表达式**（21 处，
  均为 `github.*` / `env.*` / `secrets.*`），再 `--amend` 重推 + 重新 dispatch。
- 教训已落进代码注释：**给 GitHub Actions 写注释也不能出现 `${{ }}` 字面量**。

**硬性禁令遵守**：本轮**未触碰任何 `.dart` 文件、未触碰 WebView**，
无 `pauseTimers`/`resumeTimers`、无滚动挂起逻辑 → 与「验证页白屏」路线无关。

**本地验证**
- `python3 -c "yaml.safe_load(...)"` → YAML OK，14 个 step；正则扫描 `${{ }}` 全合法。
- 真实校验：GitHub dispatch 返回 **HTTP 204**（YAML 通过 GitHub 自身解析器）。
- CI 同款 `dart format --set-exit-if-changed`（Dart 3.12.0，对 base 差异的 38 个
  .dart 文件）→ **0 changed**，exit 0。

**本轮 CI**：触发 run **#45**（`f98045d3`，`APP_VERSION_SUFFIX` `008 → 009`）。

**下一步**
1. 核对 run #45：`app 显示版本: 0.2.28 -> 0.2.28.009`；Release `ios14-test-45` 的
   `ipa-inspection.json` 里 `version == 0.2.28.009`、`build-info.txt` 含
   `APP_VERSION_SUFFIX=009`（本轮新加的字段，第一次生效）。
2. **回到降发热主线**（本轮只修了 CI，未动 Dart）：下一轮从候选里挑一个——
   - `cf_challenge_service.dart` `_startChallengeRevealProbe` 250ms 轮询（收益小、
     有 20 次上界，风险低）；
   - `dns.rs` `http2_keep_alive_while_idle(true)`（Rust，单独一轮便于归因）；
   - 路径B：DoH 通道连接复用（rhttp/Dio 每请求是否新建连接）。
3. SS 代理接管内置浏览器（并行方向 P0：能力诊断可观测化）。

---

## 2026-10-13 19:00 CST | 核对 run45 + 修 CI：`${GITHUB_ENV}` 被表达式替换吞掉（STEP7 unbound variable）

**开工核对（强制流程 0）**：最近 3 次 run = #45(failure) / #44(failure) / #43(success)。
**必须先修 failure 才能推新代码** → 本轮全部时间用于修 run45 的失败点。

**run45（`f98045d3`）失败定位（先证据）**
- job 日志：`STEP 7 项目准备及工具信息 -> failure`，STEP 8~15 全 skipped，**无包无 Release**。
- 关键行：`.../19d92432-....sh: line 8: APP_VERSION_SUFFIX: unbound variable`
  （该步骤 `set -euo pipefail` → 直接整 job 挂）。
- 根因：上一轮 `f98045d3` 在「项目准备及工具信息」的 run 块里新加了
  `echo "APP_VERSION_SUFFIX=${APP_VERSION_SUFFIX}" >> "$GITHUB_ENV"`，
  **但该 run 块内存在合法的 `${{ github.* }}` 表达式**，GitHub 做表达式替换时
  会把同类写法里**未被保护的花括号变量引用一起吞成空串** —— `"$GITHUB_ENV"`
  被吃掉 → 变成 `echo ... >> ""`（静默失败），文件里从未写入 suffix；
  STEP 7 自身因 `${APP_VERSION_SUFFIX}` 也在后续行被吞而报 unbound。
  **与 run41/42/43「suffix 卡死 008」是同一个表达式替换陷阱，只是换了个受害者。**
- ⚠️ 反直觉点：`"$GITHUB_ENV"`（无花括号）也被吞 —— 该替换针对**取值引用本身**，
  所以「改用 `$GITHUB_ENV` 规避」是**无效方案**。

**本轮改动（commit `280547e3`，仅 CI 单文件）**
- `.github/workflows/ios14-test.yml`：
  1. 版本后缀改为**经文件传递**：`printf '%s\n' "$APP_VERSION_SUFFIX" > dist/app-version-suffix.txt`；
     打包步骤 `APP_VERSION_SUFFIX=$(cat dist/app-version-suffix.txt)` 读回。
     **彻底不写 `GITHUB_ENV`**，绕开表达式替换陷阱。
  2. 注释补第 2 条血泪教训：**run 块内不得出现 `"$GITHUB_ENV"`/`"${GITHUB_ENV}"`**。
  3. 打包步骤增 `echo "APP_VERSION_SUFFIX=..."` 便于日志核对。
- suffix 保持 **009**（run45 未出包，009 未被消耗，不递增）。

**验证**
- `yaml.safe_load` → OK，14 个 step 解析正常。
- `grep GITHUB_ENV`：剩余唯一一处是「为 Release 重命名」步骤的
  `echo "RELEASE_IPA_NAME=${NEWNAME}" >> "$GITHUB_ENV"`。**该步骤 run 块不含任何
  `${{ }}` 字面量**（已逐行确认），故安全，**不动**（避免无关改动）。
- 触发 run **#46**（`280547e3`），dispatch HTTP 204。

**硬性禁令遵守**：本轮**未触碰任何 `.dart` / WebView 文件** → 与「验证页白屏」路线无关。

**下一步**
1. 核对 run #46：期望 `app 显示版本: 0.2.28 -> 0.2.28.009` 且 Release `ios14-test-46`
   的 `ipa-inspection.json` `version == 0.2.28.009`。**若仍 no Release，先补 Release**。
2. 回降发热主线（本轮未动 Dart）：挑一个低风险增量，候选按序——
   - `cf_clearance_refresh_service.dart` iOS 前台闲置销毁延时 `_iosIdleDisposeDelay`
     5min → 收紧（证据：前台静默期常驻 Turnstile JS 把平台线程烧到 60%+，是老设备发烫主因）；
   - `cf_challenge_service.dart` `_startChallengeRevealProbe` 250ms 轮询；
   - 路径B：DoH 通道连接复用。
3. SS 代理接管内置浏览器（并行方向 P0：能力诊断可观测化）。

---

## 2026-10-13 21:00 CST | 路径A：帧监控 summary 空转钳流（去掉空转期的语义树/平台视图全量遍历）

**开工核对（强制流程 0）**
- 最近 3 次 run = **#46**(`280547e3`, success) / #45(failure, 已在 19:00 轮修复) / #44(failure, 同批修复)。
- **#46 = ✅ success，且 Release `ios14-test-46` 已生成**（10-13 19:36 CST 发布）：
  `fluxdo-ios14-test-46-280547e3.ipa`(54,868,783B) + SHA256SUMS + build-info + validation + inspection。
- 核对版本链路（19:00 轮修的 CI bug 是否真修好）：
  - `build-info.txt` 含 **`APP_VERSION_SUFFIX=009`** ✅（dist 文件传递方案生效，run45 的
    `GITHUB_ENV` 被吞问题确认修复）
  - `ipa-inspection.json` → **`version = 0.2.28.009`**、`build = 2026101311` ✅
  - tag `ios14-test-46` 指向 `e1bd839e`（注：tag 对象是 softprops 复用的旧 tag 对象，
    但 Release 的 published_at = 10-13 19:36 CST、资产是 `280547e3` 的 IPA，确认是新发）。
- → **无未修复 failure、无需补建 Release**，本轮可推进主线。

**本轮证据（先量后改）——路径A：定位常驻 CPU 消耗**
- `lib/utils/frame_jank_monitor.dart:659`（改前）：summary 输出条件仅为
  `now - _lastSummary >= _summaryInterval`（10s）+ `_frames > 0`。**没有"有无掉帧"的前置条件。**
- 该 summary 体（`:661-668`）不是轻活：`SemanticsBinding.instance.semanticsEnabled` 为真时
  调 `countSemanticsNodes()`（**遍历整棵语义树**）+ `countPlatformViews()`（**遍历平台视图树**）。
  注释里已标注这两笔是"实打实开销"。
- 关键放大效应：`_emitSummary` 位于**每帧**都会走的 `_onFrameTiming` 收尾处。DoH 模式 + 常驻
  CF WebView 的场景下，就算没有掉帧，**空转帧也会持续产生**（与"空转探测"章节描述一致），
  于是整场会话每 10s 就要在 UI 线程上付一次全量遍历的账 —— 空转期纯烧电。
- 该开销与诊断总开关 `_started`（`pref_perf_diagnostics`）绑定，**用户开过一次诊断就永久背账**，
  与 05:30 轮修掉的 `PerfOverlay` 是同一类"常驻采样"问题。

**本轮改动（commit `51a980e6`）**
`lib/utils/frame_jank_monitor.dart`：
- 新增 `_windowHadJank`（本窗口是否出过真实 JANK 记录，在 `jankRecords.add(record)` 处置真）与
  `_lastSummaryFrames`（上次输出时的 `_frames` 水位）。
- 把 summary 体抽成 `static void _emitSummary()`，**内容逐字未改**（日志格式/字段/统计口径不变）。
- 输出条件改为：
  `now - _lastSummary >= (_windowHadJank ? _summaryInterval(10s) : _idleSummaryInterval(60s))`
  `&& _frames > _lastSummaryFrames`
  → **有掉帧的窗口保持 10s 节奏（诊断能力零损失）；纯空转窗口拉宽到 60s，日志仍证明监控活着。**
- 新增常量 `_idleSummaryInterval = Duration(seconds: 60)`。
- 判据兼用"帧数水位是否前进"，画面全程静止无新帧时不产生任何输出。

**预期收益**：诊断开启且画面空转时，语义树+平台视图遍历频率降到 **原来的 1/6**；
有掉帧时行为完全不变。老设备（iOS14）上这是稳定的 UI 线程负载削减。

**硬性禁令遵守**：纯 Dart 侧统计节流，**未触碰任何 WebView 文件、未调用
`pauseTimers`/`resumeTimers`、无任何滚动挂起逻辑**，不阻塞任何 JS 执行。

**本地验证（CI 同款工具链）**
- `dart format --output=none --set-exit-if-changed lib/utils/frame_jank_monitor.dart`
  → **0 changed, exit 0**（Dart 3.12.0，/tmp/dartsdk312/dart-sdk）。
- 用 CI 同款 diff 命令复核：`git diff --name-only --diff-filter=ACMR HEAD~1 HEAD -- '*.dart'`
  → 仅 `frame_jank_monitor.dart`，format **0 changed, exit 0**。
- 手工核对：`{}`×198/198 配平；新符号引用计数正确
  （`_windowHadJank`×5、`_lastSummaryFrames`×3、`_emitSummary`×4、`_idleSummaryInterval`×3）。
- `dart analyze` 项目级在本容器崩溃（既有环境限制，`Bad state: The analysis server crashed
  unexpectedly`），同上轮替代方案：靠 format + CI STEP8 的 analyze 把关。

**CI 触发**：run **#47**（`51a980e6`，`APP_VERSION_SUFFIX` `009 → 010`），dispatch HTTP 204，
启动即 in_progress。

**下一步**
1. 核对 run #47：期望 STEP8 格式与静态分析通过 + 出包 + Release `ios14-test-47`，
   且 `ipa-inspection.json` `version == 0.2.28.010`。**若 STEP8 失败（analyze --fatal-infos 拦下），
   下一轮第一优先级修它。**
2. 回降发热主线候选（按序）：
   - `cf_clearance_refresh_service.dart` iOS 前台闲置销毁延时 `_iosIdleDisposeDelay`
     5min → 收紧（证据：前台静默期常驻 Turnstile JS 把平台线程烧到 60%+）；
   - 路径B：DoH 通道连接复用（rhttp/Dio 是否每请求新建连接）；
   - `cf_challenge_service.dart` `_startChallengeRevealProbe` 250ms 轮询。
3. SS 代理接管内置浏览器（并行方向 P0：能力诊断可观测化）。

---

## 2026-10-13 23:00 CST | 路径A：CF 前台闲置销毁后「真休眠」（取消 dispose 尾部原地重建）

**CI 前置核对**：#48 `6637ee87` = ✅ success + Release `ios14-test-48`
（`version=0.2.28.011`、`build=2026101314`）；#47 `51a980e6` 的 failure 根因
已定位为 STEP8 `frame_jank_monitor.dart:707:18 Undefined name 'budgetUs'`，
且**已被 #48 修复**（`6637ee87`）→ 无未修复 failure、无缺 Release，本轮可推进。

**本轮改动**：`cf_clearance_refresh_service.dart` 新增 `_idleDisposed` 休眠标记。
iOS 前台闲置销毁路径置位；`_disposeWebViewImpl` 尾部原本无条件「期望态重建」
（`:656`），会让闲置销毁原地重建 = 省电收益归零。现加 `&& !_idleDisposed`，
休眠由真实需求路径（`updateSitekey` 撞盾 / `resume` 前台恢复 / `start` 显式）
清除标记并按需重建。不用 `_shouldBeRunning=false` 表达休眠（撞盾分支依赖它为 true）。
休眠期 `_cancelRuntimeTimers` 已停 cookie/health 轮询，无空转。
**未触碰任何 WebView 挂起 API，无 pauseTimers/resumeTimers、无滚动挂起，不阻塞 JS。**

**本地验证**：Dart 3.12.0（CI 同款）`dart format --set-exit-if-changed` → 1 file 0 changed；
CI 同款 diff 预检（base `e1bd839…`）→ 38 files 0 changed。
Rust 侧比对确认本地 `proxy.rs` 脏状态 == `patches/0001-*.patch`（路径B 已交付），无未交付 Rust 改动。

**commit**：`b82150ae`（代码）、`4ff93fd2`（APP_VERSION_SUFFIX 011 → 012）

**CI**：run **#49**（`4ff93fd2`，id `38419132192`）23:06 CST dispatch（HTTP 204），
启动即 in_progress；轮内轮询至 STEP7。回报时仍未出包 → 交下一轮核对。

**下一步**
1. 核对 run #49：期望 STEP8 通过 + 出包 + Release `ios14-test-49`（`0.2.28.012`）。
2. 降发热主线候选（按序）：
   - `cf_challenge_service.dart` `_startChallengeRevealProbe` 250ms 轮询；
   - `_iosIdleDisposeDelay` 5min → 收紧（现有更安全基础：休眠不再原地重建）；
   - DoH 出口探针（`probeEffectiveProxy` / `dohEgressVerified`）采样频率。
3. SS 代理接管内置浏览器（并行方向；`patches/WIP-0002-system-proxy-adaptive-backoff.txt` 为在途草稿）。

---

## 2026-10-14 02:00 CST — 修复 run#52 step8 analyze failure（路径D D1 量化遗留）

### CI 前置核对（强制第 0 步）
最近 3 个 run 全部 failure：
- **#52** `5edc50f7`(id 38439814173) STEP8 **dart analyze** 挂：
  `webview_http_adapter.dart:514:25`、`:764:23` 两处 `unnecessary_null_comparison`
  （"The operand can't be 'null', so the condition is always 'true'"），`--fatal-infos` → failure。
  注意 `dart format` 实际已 0 changed 通过，失败点是 analyze，不是 format。
- **#51** `5edc50f7`(id 38436258785) 同样 analyze 挂。
- **#50** `cf917903`(id 38429318945) STEP7 format 挂（已被 5edc50f7 修 format）。
→ 存在未修复 failure，本轮第一优先级修 analyze。

### 本轮改动 commit `043f0d71`
`webview_http_adapter.dart` 删掉 2 处冗余 `if (jsEvalElapsed != null)` 判断
（flow analysis 证明该分支非 null：赋值在 try 内 evaluateJavascript 成功后、catch rethrow，
到计数行必非 null）。纯删死代码，不改分流/桥行为，D1 画像语义不变。

### 本地验证
- CI 同款 diff 预检（base e1bd839e → HEAD）：40 files **0 changed，exit 0** ✅
- 本地 dart analyze 容器内崩溃（既有 2C/3.7G 限制），靠 CI STEP8 把关。

### CI
push `043f0d71` 成功；dispatch run（`APP_VERSION_SUFFIX` 保持 `013`）→ **#53**，待出包。

### 下一步
1. 核对 run **#53**：期望 STEP8 通过 + 出包 + Release `ios14-test-53`（`0.2.28.013`）。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 读图片同源 vs API 请求/字节量 → **D2 判据**。
3. 若图片同源占多数 → 试 D2 图片分流（skipWebViewAdapter → 原生直连，验证 CF 403 是否升高）。

---

## 2026-10-14 05:00 CST — onResponse 响应 cookie 批量 sweep（D3 活跃负载降开销）

### CI 前置核对（强制第 0 步）
- **#54** `4dd74f36`(id 38466065999) 启动即 in_progress，本轮回报时仍未出包 → 交下一轮核对。
- **#53** `043f0d71` = ✅ **success**；Release **`ios14-test-53`** 已在
  （`fluxdo-ios14-test-53-043f0d71.ipa` 54,879,229B，`0.2.28.013`）✅。
- **#52** = ❌ failure（analyze，已被 #53 修复）。
- → 无未修复 failure、无缺 Release；#54 未失败，本轮可推进。

### 本轮改动（commit `90e2fa42`）
新增 `SessionCookieSentinel.sweepMany(url, targets, {force})`：
- 语义与逐个 [sweep] **完全一致**（1s 节流 / per-name 锁 / delete 分支全保留），
  唯一区别 = **变体计数批量预取**：一次 `countCookiesByNames`（原生一次
  `getAllCookies` 枚举）注入各 name 的 `variantsBeforeOverride`。
- 只对「非节流命中的 ensureUnique」name 预取，贴近原语义。

`app_cookie_manager.dart` `onResponse`：把「逐 cookie `sweep` + `Future.wait`」
改为一次 `sweepMany`。证据：活跃刷帖时每个响应带若干 Set-Cookie
（session-token / _t / LDC …），逐个 sweep = 「响应 cookie 数」次全量枚举 +
跨语言往返，同步阻塞在响应路径上 → 与请求本身无关的固定桥开销。

### 本地验证（CI 同款工具链 Dart 3.12.0）
- `dart format --set-exit-if-changed`（HEAD）：2 files **0 changed，exit 0** ✅。
- 语义核对：`variantsBeforeOverride` 为 null（节流/未预取）时 sweep 内部自行读，
  行为等价；批量成功且计数为 0 时传 0，正确不触发多余枚举。

### CI
push `90e2fa42` 成功；dispatch（`APP_VERSION_SUFFIX` 014→**015**）→ **#55**，待出包。

### 下一步
1. 核对 run **#54** / **#55**：期望 STEP8 通过 + 出包 + Release（`0.2.28.014` / `0.2.28.015`）。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 读图片同源 vs API 请求/字节量 → **D2 判据**。
3. 若图片同源占多数 → 试 D2 图片分流（skipWebViewAdapter → 原生直连，验证 CF 403 是否升高）。

## 2026-10-14 06:00 CST — 路径D2：同源图片分流原生直连（活跃负载降开销）

### 开工核对（强制）
- #55 `90e2fa42` = ✅ success，Release `ios14-test-54` 已出（0.2.28.014）✅
- #54 `4dd74f36` = ✅ success，Release `ios14-test-53` 已出 ✅
- 无未修复 failure、无缺 Release → 可推进。

### 本轮改动（commit `e35f7aae`）
D2 落地：同源静态图片（resourceKindImage）从 WebView 桥分流到原生 Dio 直连。
- `platform_adapter.dart`：新增顶层开关 `imageNativeRoutingEnabled`（默认 true）；
  `requestCanUseWebViewAdapter` 的 image 分支在开关开启时直接 `return false`
  （→ 走 `_inner` 原生栈），并 `WebViewBridgeDiagnostics.imageRoutedNative++` 计数。
- `webview_bridge_diagnostics.dart`：新增 `imageRoutedNative` 计数 + reset 清零。
- `ios14_network_diagnostics_page.dart`：report 增 `imageRoutedNative`；界面在 >0 时
  显示「同源图片已分流原生直连：N 次」。
- 回退路径：置 `imageNativeRoutingEnabled = false` 即恢复旧行为（一行，无需改调用方）；
  `skipWebViewAdapter` 仍是最高优先级强制原生开关。

### 依据
- 图片是刷帖时体量最大的走桥负载：每响应经「JS fetch → WebMessageChannel 分块回传」
  跨桥（:605 sendBuffer / :1182 fallback base64）。CF Bot Management 拦的是
  导航/API 的 challenge，静态图片不参与指纹判定 → 分流不破坏过盾。
- ⚠️ 待实机验证：若出现 CF 403/拦截率升高，立即回退开关并在日志写明数据。

### 本地验证（CI 同款工具链 Dart 3.12.0）
- `dart format --set-exit-if-changed`：3 files **0 changed，exit 0** ✅。
- `dart analyze`：本地 analysis server 对两文件崩溃（**基线同样崩溃**，属本机环境问题，
  非改动引入；webview_bridge_diagnostics.dart 单独 analyze 通过）。CI 侧为准。

### CI
push `e35f7aae` 成功；dispatch（`APP_VERSION_SUFFIX` 015→**016**）→ **#56**（pending）。

### 下一步
1. 核对 run **#56**：期望 success + Release `ios14-test-56`（0.2.28.016）。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 看「同源图片已分流原生直连 N 次」
   与发热是否下降；同时留意 CF 403/拦截率。
3. 若 403 升高 → 回退 `imageNativeRoutingEnabled=false`；否则继续 D3（桥内降开销）。

## 2026-10-14 07:00 CST — 路径D3：变体计数缓存复用（活跃负载降开销）

### 开工核对（强制）
- #56 `e35f7aae` = ✅ success（全 15 步绿），Release `ios14-test-56` 已出（0.2.28.016）✅
- #55 `90e2fa42` = ✅ success；#54 `4dd74f36` = ✅ success。
- 无未修复 failure、无缺 Release → 可推进。

### 本轮改动（commit `a10b2e85`）
D3：同一批 sweep 内复用「刚读到的」变体计数，省掉重复的全量枚举。
- `webview_bridge_diagnostics.dart`：新增 `_variantCounts` 缓存（name→int）+ 
  `cachedVariantCount`/`rememberVariantCount`/`invalidateVariantCounts` +
  `variantCountCacheHits` 计数；`markWvCookieMutated`/`resetCookieBoundarySync`
  内部一并作废缓存。
- `session_cookie_sentinel.dart`：`sweepAll`/`sweepMany` 批量取数后
  `rememberVariantCount`；`_sweepInternal` 优先读缓存（命中 `++`），未命中才
  原生读取；收敛后 `after` 写回缓存；`_executeDelete` 删到 cookie 时作废缓存。
- `ios14_network_diagnostics_page.dart`：report + 界面显示「变体计数缓存复用 N 次」。
- 正确性：任何 WV cookie 集合变更都作废缓存，未命中路径与旧行为逐字一致。
- 硬性禁令遵守：无 pauseTimers/resumeTimers，无滚动挂起。

### 依据
`sweepAll` 先 `countCookiesByNames`（1 次全量枚举）拿 N 个计数，随后
`_sweepInternal` 对每个 name **又**各读一次 `countCookiesByName`（iOS 原生 =
又一次 `getAllCookies` 全量枚举 + 跨语言序列化）→ 同一批 name 枚举两遍。

### 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：3 files **0 changed，exit 0** ✅。

### CI
push `a10b2e85` 成功；dispatch（`APP_VERSION_SUFFIX` 016→017）→ **#57**（pending）。

### 下一步
1. 核对 run #57：期望 success + Release `ios14-test-57`（0.2.28.017）。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 看图片分流 N 次 + 缓存复用 N 次 + 发热。
3. 若 D2 图片分流致 CF 403 升高 → 回退 `imageNativeRoutingEnabled=false`。

## 2026-10-14 10:00 CST — 路径D4：边界同步延后收敛（活跃请求路径摘掉 sweepAll）

### 开工核对（强制第 0 步）
- **#59** `41258cd6`(id 38487988910) = ✅ **success**，全 15 步绿；
  Release **`ios14-test-59`** 已出（0.2.28.017，IPA 54.9MB）✅。
- **#58** `950fba59` = ❌ failure（step8 analyze：`session_cookie_sentinel.dart:583`
  裸 `stats`）→ **已被 #59 修复**（`41258cd6` 显式 instance），无遗留。
- **#57** = ❌ failure（同类 analyze，已被 #58 修）→ 无未修复 failure、无缺 Release。
- → 本轮可推进。

### 本轮改动（commit `98f27565`）
D4：把「WV cookie 变化 → 立刻作废边界同步状态 → 下一个走桥请求在**自身请求
路径上**同步跑 sweepAll」改成「变化只标记待收敛，由已在跑的 500ms debounce
在请求路径之外统一 sweep」。
- `cookie_store_observer.dart`：`_onCookiesChanged()` 不再直接 `markWvCookieMutated()`
  （那会立刻把 `cookieBoundarySynced` 置 false），改为
  `WebViewBridgeDiagnostics.instance.markResyncPending()`；`_doSweep()` 开头
  无条件 `clearResyncPending()`（debounce 到期即视为已收敛）。
- `webview_bridge_diagnostics.dart`：新增 `cookieResyncPending` 状态 +
  `cookieSweepsDeferred` 计数 + `markResyncPending()`/`clearResyncPending()`；
  `resetCookieBoundarySync()` 一并复位；`reset()` 一并清零。
- `webview_http_adapter.dart`：`!cookieBoundarySynced` 分支里，若
  `cookieResyncPending` 为真 → `cookieSweepsDeferred++` 并**跳过** sweepAll
  （变化由 debounce 收敛）；否则维持原行为。
- `ios14_network_diagnostics_page.dart`：report + 界面显示「边界同步延后收敛 N 次」。
- **正确性**：sweep 本就是最终一致的兜底，延后一个 debounce 窗口不改变任何
  同步/删除语义；窗口内请求用的仍是 jar↔WV 已就绪的 cookie 集（prime 幂等）。
- **硬性禁令遵守**：未触碰任何 WebView 挂起/暂停 API，无 pauseTimers/resumeTimers，
  不阻塞 JS 执行。

### 依据
`AppDelegate.swift:856 cookiesDidChange` → channel `onCookiesChanged` →
`cookie_store_observer.dart:_onCookiesChanged()`。改前它直接
`markWvCookieMutated()` → `cookieBoundarySynced=false` → **下一个走桥请求**
在请求路径上跑 `sweepAll`（O(cookie 数) 次 `getAllCookies` 全量枚举 + 跨语言
往返）。刷帖时 CF 持续轮换/下发 cookie，等于每个请求都背一次边界同步——
这是活跃负载下与请求本身无关的固定桥开销。

### 本地验证（CI 同款工具链 Dart 3.12.0）
- `dart format --output=none --set-exit-if-changed`：4 files **0 changed，exit 0** ✅。
- `dart analyze`：本机 analysis server 对 3/4 文件崩溃（**基线同样崩溃**，
  已用 `git stash` 对照验证，属本机环境问题，非改动引入）。CI 侧为准。

### CI
push `98f27565` + `483a18f1`（`APP_VERSION_SUFFIX` 017→**018**）→ **#60**（in_progress，id 38501025713）。

### 下一步
1. 核对 run **#60**：期望 success + Release `ios14-test-60`（0.2.28.018）。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 看「边界同步延后收敛 N 次」+
   「同源图片已分流原生直连 N 次」+ 发热是否下降。
3. 若 D2 图片分流致 CF 403 升高 → 回退 `imageNativeRoutingEnabled=false`。

---

## 2026-10-14 12:00（北京时间）· 轮次：修 run#60 → 出包 #61

### 0) 上轮 CI 核对（强制）
- 查最近 3 次 run：
  - **#60** `483a18f1` — **failure**（2026-10-14 10:26 北京）→ 本轮第一优先级修复。
  - #59 `41258cd6` — success（有 Release）。
  - #58 `950fba59` — failure（已修）。
- **#60 失败定位**（拉 job 日志 `/tmp/run60.log`）：
  - 失败 step = **8「格式与静态分析」**，exit code 2。
  - `dart format` 通过（45 files, **0 changed**）；失败在 `dart analyze --fatal-infos`：
    `warning - cookie_store_observer.dart:52:25 - The value of the field '_resyncWindow' isn't used. - unused_field`
  - 即上一轮 D4 改动删掉了 `_resyncWindow` 的**全部引用**，但常量声明本身没删（工作区已删，未提交）。
  - 无 IPA、无 Release（step 10~15 全 skipped）。

### 2) 本轮改造
- **修复**：提交工作区已就绪的删除——`cookie_store_observer.dart` 移除未引用的
  `static const Duration _resyncWindow = Duration(milliseconds: 500);`
  （收敛窗口统一用 `_debounceWindow`，注释已同步说明）。
- 本地预检（CI 同款 Dart 3.12.0）：`dart format --output=none --set-exit-if-changed` → **0 changed, exit 0** ✅。
- `dart analyze` 本机 analysis server 崩溃（`git stash` 对照确认**基线同样崩溃**，属本机环境问题），以 CI 为准。

### 3) 提交与 CI
- commit `a2066c6c`：`fix(ios14): 修复 run#60 step8 analyze——移除未被引用的 _resyncWindow 常量（unused_field）`
- push → `fix/ios14-network-thermal`（`483a18f1..a2066c6c`）
- 触发 workflow → **run #61**（id `38509271673`，`APP_VERSION_SUFFIX` 仍为 018）。
- 轮内实测：**step 8 格式与静态分析 success ✅**，**step 9 iOS14 兼容与 CF 回归测试 success ✅**，
  step 10 构建 IPA 进行中。

### 下一步
1. 等 #61 出包 → 确认 Release `ios14-test-61`（0.2.28.018）+ IPA 直链。
2. 老板实机验证 D4（边界同步延后收敛）+ D2（同源图片分流原生）对活跃发热的影响。
3. 若 #61 成功，下一轮回到主线：继续找「活跃负载」发热源（D1 量化走桥请求数/字节量）。

---

## 2026-10-14 13:00（北京时间）· 轮次：D5 响应体免二次转义

### 0) 上轮 CI 核对（强制）
- 查最近 3 次 run：**#61** `a2066c6c` = ✅ success（全绿，Release `ios14-test-61` / `0.2.28.018` 已出，
  IPA 54,890,000B）；#60 `483a18f1` = ❌ failure（已修）；#59 = ✅。
- → 无未修复 failure、无缺 Release，本轮可推进主线。

### 1) 状态基线
- 分支 `fix/ios14-network-thermal`，HEAD `8d07817a`。工作区仅 `core/doh_proxy` 子模块脏（历史遗留，未动）。

### 2) 本轮改造 —— D5：文本响应体「免二次 JSON 转义」（活跃负载降 CPU）
**证据（先读代码定位，非猜测）**：
- 文本响应路径（`webview_http_adapter.dart` 旧 :388-401）JS 侧：
  `const result = JSON.stringify({ok,status,headers, body: bodyData})` —— body 被转义**第一次**；
  再 `callHandler('fetchResult', {requestId, result})`。
- 插件侧（`flutter_inappwebview_web` 的 `web_support.js:82`）对参数做
  `_JSON_stringify(_Array_slice.call(arguments, 1))` —— 整包（含已转义的 body）被转义**第二次**。
- Dart 侧：插件先 `jsonDecode` 反转义一次，我们的 `jsonDecode(resultStr)` 再反转义一次。
- 结论：**每条文本响应，body 被整包转义 2 次 + 反转义 2 次**，全部在主 isolate。
  刷帖时话题列表/详情 JSON 动辄数十~数百 KB → 这正是「活跃使用时发热」的固定桥开销。

**改动（commit `b44a8357`）**：
- JS 成功/错误路径改为把 `body` 与元数据作**平级字段**传回（`{requestId, ok, status, statusText, headers, body}`），
  不再嵌进 `result` 字符串 → body 只经插件序列化**一次**。
- Dart handler 改为把收到的对象**直接**解析成 `Map` 并 `complete(parsed)`；保留旧 `result` 字符串形态的
  兜底解析（兼容未更新的 JS / 缓存页面）。
- `_pendingRequests` 类型 `Completer<String>` → `Completer<Map<String,dynamic>>`；调用方去掉
  自身的 `jsonDecode(resultStr)`。
- 二进制流 fallback 的 `callHandler('fetchResult', …)` 同步改为平级字段。
- `webview_bridge_diagnostics.dart` 新增 `textBodyUnescaped` / `textBodyUnescapedBytes` 计数；
  诊断页新增「响应体免二次转义：N 次（约 N B）」。
- **硬性禁令遵守**：未触碰任何 WebView 挂起/暂停 API，无 pauseTimers/resumeTimers，不阻塞 JS。

### 3) 本地验证（CI 同款工具链 Dart 3.12.0）
- `dart format --output=none --set-exit-if-changed`：3 files **0 changed，exit 0** ✅。
- `dart analyze` 本机 analysis server 崩溃（`git stash` 对照确认**基线同样崩溃**，属本机环境问题），以 CI 为准。

### 4) 提交与 CI
- commit `b44a8357`，push `8d07817a..b44a8357`。
- `APP_VERSION_SUFFIX` 018 → **019**。
- 触发 workflow → **run #62**（id `38515163353`，in_progress）。

### 下一步
1. 等 #62 出包 → 确认 Release `ios14-test-62`（`0.2.28.019`）+ IPA 直链。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 看「响应体免二次转义 N 次 / 约 N B」+ 发热是否下降。
3. 若 #62 成功，下一轮继续找活跃负载发热源（候选：请求体 base64 fallback 频率、桥并发上限）。

---

## 2026-10-14 15:00 CST — D6：WebView 桥跨配置变更复用（活跃负载降重建开销）

### 0) CI 前置核对
- **#62** `b44a8357` = ✅ success，Release **`ios14-test-62`** 已出（D5+D4+D2，`0.2.28.019`），
  IPA：`https://github.com/longxiang1002/fluxdo/releases/download/ios14-test-62/fluxdo-ios14-test-62-b44a8357.ipa`
- **#61** = ✅ success；**#60** = ❌ failure（已被 #61 修复，无遗留）→ 无未修复 failure、无缺 Release。

### 1) 证据
- `platform_adapter.dart:651-663`（改前）：`_ensureDelegate()` 的 `configChanged` 分支
  **无条件** `close(force:false)` 全部 delegate 并 `_delegates.clear()`。
- `WebViewHttpAdapter` 构造**不依赖** DoH/proxy/rhttp 设置，只依赖
  `WebViewAdapterSettingsService.effectiveEnabled`（开关变化由
  `_handleWebViewSettingChanged` → `disposeWhenIdle()` 单独管理）。
- `close(force:false)` 在 `_activeFetches==0` 时**立即 dispose 隐藏 WKWebView** →
  下次走桥请求从零重建（run + loadData + 等加载 + 全量重灌 cookie）+ 作废边界同步标记。
- 活跃刷帖期间任何无关设置版本 bump（DoH 应用/代理刷新/rhttp/CF 降级翻转）都会触发该重建
  → 活跃负载下的固定 CPU/耗电源。

### 2) 改动
- `platform_adapter.dart`：`configChanged` 分支只拆非 webview delegate，`AdapterType.webview` 保留复用。
- `webview_bridge_diagnostics.dart`：新增 `webViewPreservedOnConfigChange` + `markWebViewPreservedOnConfigChange()`，`reset()` 复位。
- `ios14_network_diagnostics_page.dart`：snapshot + UI 显示「WebView 桥跨配置变更复用：N 次」。
- 禁令遵守：无 pauseTimers/resumeTimers、无滚动挂起、不阻塞 JS。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --output=none --set-exit-if-changed`：3 files **0 changed，exit 0** ✅。

### 4) 提交与 CI
- `APP_VERSION_SUFFIX` 019 → **020**。
- commit 与 run 号见下方追加。

### 下一步
1. 等本轮 run → 确认 Release + IPA 直链。
2. 老板实机验证 D6（诊断页看计数）+ 活跃发热变化。
3. 下一轮继续找活跃负载发热源。

---

## 2026-10-14 16:00 CST — D7：重复 cookie 重灌去抖（活跃负载削峰）

### 0) CI 前置核对
- **#63** `6856d6d5` = ✅ success，Release **`ios14-test-63`** 已出（D6，`0.2.28.020`），
  IPA：`https://github.com/longxiang1002/fluxdo/releases/download/ios14-test-63/fluxdo-ios14-test-63-6856d6d5.ipa`
- **#62** = ✅ success；**#61** = ✅ success → 无未修复 failure、无缺 Release。

### 1) 证据
- `cf_clearance_refresh_service.dart:345` 与 `webview_session_cookie_refresh_service.dart:317`：
  每次重建隐藏 WebView 前都 `WebViewCookiePriming.instance.invalidate()` + `await prime(baseUrl)`。
- `webview_cookie_priming.dart` 改前：`invalidate()` 只置 `_isPrimed=false`；`prime()` 唯一短路是 `if (_isPrimed) return`。
  → 活跃刷帖时 CF 持续触发刷新，每次刷新都强制一次全量 prime。
- `_primeInternal` 每个 cookie 走 `_writeCookieWithVariantCleanup`：先 `sweep(delete)` 再 `setRawCookie`
  再 `countCookiesByName`，即 **O(cookie 数) 次原生 cookie 库往返**（iOS = `WKHTTPCookieStore` 全量枚举 + 跨语言序列化）。
- → 活跃负载下的固定 CPU 源：CF 刷新频率 × 全量 cookie 重灌成本。

### 2) 改动
- `webview_cookie_priming.dart`：新增 `_lastPrimeCompletedAt` + `_primeDedupWindow = 2s`；
  `prime()` 在 `_isPrimed` 短路后新增「距上次成功 prime 不足窗口 → 直接短路」分支（`markPrimingDeduped()`）；
  `_primeInternal` 成功时记录完成时间；`invalidate()` 一并清时间戳（显式失效必须允许真 prime）。
- `webview_bridge_diagnostics.dart`：新增 `primingDeduped` 计数 + `markPrimingDeduped()`，`reset()` 复位。
- `ios14_network_diagnostics_page.dart`：snapshot + UI 显示「重复 cookie 重灌去抖：N 次」。
- 禁令遵守：无 pauseTimers/resumeTimers、无滚动挂起、不阻塞 JS。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --output=none --set-exit-if-changed`：3 files **0 changed，exit 0** ✅。

### 4) 提交与 CI
- commit `d6f89f87`，push `6856d6d5..d6f89f87`。
- `APP_VERSION_SUFFIX` 020 → **021**。
- 触发 workflow（HTTP 204）→ run 号见下轮核对。

### 下一步
1. 核对本轮 run → 确认 Release `ios14-test-<n>`（`0.2.28.021`）+ IPA 直链。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 看「重复 cookie 重灌去抖 N 次」+ 发热变化。
3. 下一轮继续找活跃负载发热源（候选：CF 刷新 WebView 重建频率、桥并发上限）。

---

## 2026-10-14 18:00 CST — D8：只读图片请求跳过 sweepAll 边界同步（活跃负载削峰）

### 0) CI 前置核对
- **#64** `d6f89f87` = ✅ success，Release **`ios14-test-64`** 已出（D7，`0.2.28.021`），
  IPA：`https://github.com/longxiang1002/fluxdo/releases/download/ios14-test-64/fluxdo-ios14-test-64-d6f89f87.ipa`
- **#63** = ✅ success；**#62** = ✅ success → 无未修复 failure、无缺 Release。

### 1) 证据
- `dio_http_client.dart:131-136 / 210-215`：主域图片（`send` / `fetchBytes`）打
  `resourceKindImage` + `cookieModeReadOnly`。
- `webview_http_adapter.dart:288` 改前：`prepareAppCookies = cookieMode != none`，
  只读图片也进完整 prepare 块；只读图片从不往 WV 侧写 cookie，`sweepAll` 对其无意义。
- 活跃刷帖时同源图片是桥负载大头，每张图都背一次 cookie 准备开销面。

### 2) 改动
- `webview_http_adapter.dart`：新增 `isReadOnlyImageRequest`（readOnly + image）；
  prepare 块内 `else if (isReadOnlyImageRequest)` 显式跳过 sweepAll + 计数。
- `webview_bridge_diagnostics.dart`：新增 `cookieSweepsSkippedForImage` + reset 复位。
- `ios14_network_diagnostics_page.dart`：snapshot + UI「只读图片跳过边界同步：N 次」。
- 禁令遵守：无 pauseTimers/resumeTimers、无滚动挂起、不阻塞 JS。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --output=none --set-exit-if-changed`：45 files **0 changed，exit 0** ✅。
- `dart analyze`：本机内存不足致 analysis server 崩溃（环境限制）；formatter 解析三文件均通过。

### 4) 提交与 CI
- commit `33741cac`，push `d6f89f87..33741cac`。
- `APP_VERSION_SUFFIX` 021 → **022**。
- 触发 workflow（HTTP 204）→ run 号见下轮核对。

### 下一步
1. 核对本轮 run → 确认 Release `ios14-test-<n>`（`0.2.28.022`）+ IPA 直链。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 看「只读图片跳过边界同步 N 次」+ 发热变化。
3. 下一轮继续找活跃负载发热源（候选：CF 刷新 WebView 重建频率、桥并发上限）。

---

## 2026-10-14 19:00 CST — D9：写请求不再各自强制全量边界回同步（活跃负载削峰）

### 0) CI 前置核对
- **#66** `33741cac` = ✅ success，Release **`ios14-test-66`** 已出（D8，`0.2.28.022`），
  IPA：`https://github.com/longxiang1002/fluxdo/releases/download/ios14-test-66/fluxdo-ios14-test-66-33741cac.ipa`
- **#65** = ❌ failure，但失败在 **step4「固定 Xcode 与 Flutter」**（GitHub checkout/环境抖动，
  非代码），同 commit 的 #66 已全绿出包 → 无需修复。
- 结论：无未修复 failure、无缺 Release，可推进新工作。

### 1) 证据
- `webview_http_adapter.dart:534`（改前）响应侧回同步调用：
  `force: trustsWebViewSession || (method != 'GET' && method != 'HEAD')`
  → **每个写请求都绕过 800ms 去抖窗口**，强制跑一次 `_syncCriticalCookiesBackToJar`。
- 该方法 → `BoundarySyncService.syncFromWebView` → `_strategy.readCookiesFromWebView`
  → iOS `cookieManager.getCookies(url:)` = **`WKHTTPCookieStore` 全量枚举 + 跨 method
  channel 序列化**。活跃刷帖时点赞/回复/浏览上报等写请求密集 → 每个写请求一次全量枚举。
- 正确性依据：WV 侧 cookie 变化已由 `CookieStoreObserver`（native
  `WKHTTPCookieStoreObserver` 推送）的 **500ms debounce** 在请求路径之外统一收敛
  （`cookie_store_observer.dart:28/113`），写请求响应 cookie 不比 observer 更早/更全。
  因此写请求可与读请求共用同一去抖快路径，不漏任何 cookie 变化。

### 2) 改动
- `webview_http_adapter.dart:534`：`force` 判定收窄为 `trustsWebViewSession`
  （仅「服务端已确认登录态」这一强信号保留 force，auth cookie 立即落 jar 不可延后）。
- `webview_http_adapter.dart:_syncCriticalCookiesBackToJar`：去抖命中分支新增
  `cookieBackSyncDeduped++` 计数。
- `webview_bridge_diagnostics.dart`：新增 `cookieBackSyncDeduped` 字段 + reset 复位。
- `ios14_network_diagnostics_page.dart`：report map + UI「响应侧边界回同步去抖合并：N 次」。
- 禁令遵守：无 pauseTimers/resumeTimers、无滚动挂起、不阻塞 JS。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --output=none --set-exit-if-changed`：3 files **0 changed，exit 0** ✅。

### 4) 提交与 CI
- commit `ec3dcae1`，push `33741cac..ec3dcae1`。
- `APP_VERSION_SUFFIX` 022 → **023**。
- 触发 workflow（HTTP 204）→ **run #67**（`38553727443`，in_progress）。

### 下一步
1. 核对 run#67 → 确认 Release `ios14-test-67`（`0.2.28.023`）+ IPA 直链。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 看「响应侧边界回同步去抖合并 N 次」+ 发热变化。
3. 下一轮继续找活跃负载发热源（候选：桥并发上限、CF 刷新 WebView 重建频率）。

---

## 2026-10-14 20:00 CST — D10：小请求体内联，砍掉 base64 整包往返（活跃负载削峰）

### 0) CI 前置核对
- **#67** `ec3dcae1` = ✅ success，Release **`ios14-test-67`** 已出（D9，`0.2.28.023`），
  IPA：`https://github.com/longxiang1002/fluxdo/releases/download/ios14-test-67/fluxdo-ios14-test-67-ec3dcae1.ipa`
- **#65** = ❌ failure，失败在 step4「固定 Xcode 与 Flutter」（checkout 网络抖动，非代码），
  同 commit #66 已全绿出包 → 无需修复。结论：无未修复 failure / 无缺 Release。

### 1) 证据
- `webview_http_adapter.dart:1215`（改前）非流式请求体一律 base64：
  `base64Encode(bytes)` → `jsonEncode(base64)` → JS `atob` → `Uint8Array.from(x, cb)` 逐字符回调。
  两端各一份完整副本 + 逐字节回调，是桥里最重的请求侧序列化路径。
- 活跃刷帖时写请求（点赞/回复/浏览上报/CSRF 表单）密集且体量仅几十~几百字节
  → 每个写请求都为这点数据付一次整包 base64 往返。
- 已有内联出口 `_buildDirectBodyScript` 只覆盖「JSON 对象体」，
  **经 `_readRequestBytes` 的流式/字节体此前没有内联出口**。

### 2) 改动
- `webview_http_adapter.dart`：新增 `_buildInlineSmallBodyScript`——
  ≤4KB 且「严格 UTF-8 解码 + 再编码字节完全一致」→ 直接内联
  `fetchOptions.body = <jsonEncode(text)>`；否则回退 base64，语义不变。
- 新增 `_BodyShape.inlineSmall` + 计数分支。
- `webview_bridge_diagnostics.dart`：`requestBodyInlineSmall` + `requestBodyInlineMaxBytes=4096` + reset 复位。
- `ios14_network_diagnostics_page.dart`：report map + UI 两处展示。
- 禁令遵守：无 pauseTimers/resumeTimers、无滚动挂起、不阻塞 JS。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --output=none --set-exit-if-changed`：3 files **0 changed，exit 0** ✅。

### 4) 提交与 CI
- commit `2cfa57d0`，push `ec3dcae1..2cfa57d0`。
- `APP_VERSION_SUFFIX` 023 → **024**。触发 workflow（HTTP 204）→ run 号下轮核对。

### 下一步
1. 核对本轮 run → 确认 Release `ios14-test-<n>`（`0.2.28.024`）+ IPA 直链。
2. 老板实机：诊断页「重置桥统计」→ 刷帖 → 看「小请求体内联 N 次」+ 发热变化。
3. 下一轮继续找活跃负载发热源（候选：桥并发上限、CF 刷新 WebView 重建频率）。

---

## 2026-10-14 21:00 CST — D11：帧监控全树遍历按需化（活跃负载 CPU 源）

### 0) CI 前置核对
- **#68** `2cfa57d0` = ✅ success，Release **`ios14-test-68`** 已出（D10，`0.2.28.024`），
  IPA：`https://github.com/longxiang1002/fluxdo/releases/download/ios14-test-68/fluxdo-ios14-test-68-2cfa57d0.ipa`
- **#67** `ec3dcae1` = ✅ success（D9，`0.2.28.023`）；**#66** = ✅ success。
- 结论：无未修复 failure、无缺 Release，可推进新工作。

### 1) 证据（活跃负载路径，非空转）
- `frame_jank_monitor.dart:_emitSummary`（改前）每个 summary 窗口无条件执行两笔
  **O(树大小)** 递归：
  - `countSemanticsNodes()`（:858）——遍历整棵语义树；
  - `countPlatformViews()`（:887）——遍历整棵渲染树（`visitChildren` 全递归）。
- 窗口节流规则（:680-687）：`_windowHadJank ? 10s : 60s`。**活跃刷帖时掉帧频繁
  → `_windowHadJank` 恒真 → 窗口恒为 10s**，于是整场刷帖会话每 10 秒就在 UI 线程上
  遍历两棵树。这与「活跃使用时发热」的症状精确吻合。
- 这两个数字的唯一消费方是**诊断页 UI / 导出报告**（给人看）；普通用户路径
  纯浪费。release 下 `debugPrint` 已被置空（main.dart:236），但 `_emitSummary`
  的实参在**调用前**就已求值 → 遍历照跑，debugPrint 置空救不了它。

### 2) 改动
- `frame_jank_monitor.dart`：新增 `_diagViewCount` / `hasDiagnosticsViewer` /
  `setDiagnosticsViewerVisible(bool)`；`_emitSummary` 改为仅当
  `hasDiagnosticsViewer` 时才做全树遍历，否则输出
  `tree stats: skipped (no diagnostics viewer)`（O(1)，日志仍证明监控活着）。
- `perf_diagnostics_page.dart`：`initState` 置位 / 新增 `dispose` 撤销。
- `perf_overlay.dart`：`_PerfPanelState` 新增 `initState` 置位 / `dispose` 撤销。
- 计数用加减而非布尔，天然支持「诊断页 + 悬浮面板同时打开」。
- **硬性禁令遵守**：无 pauseTimers/resumeTimers，无滚动挂起，不阻塞/不改变 JS 执行。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --output=none --set-exit-if-changed`：3 files **0 changed，exit 0** ✅。

### 4) 提交与 CI
- commit `4acb7cc9`，push `2cfa57d0..4acb7cc9`。
- `APP_VERSION_SUFFIX` 024 → **025**。触发 workflow（HTTP 204）→ run 号下轮核对。

### 下一步
1. 核对本轮 run → 确认 Release `ios14-test-<n>`（`0.2.28.025`）+ IPA 直链。
2. 下一轮继续找活跃负载发热源（候选：桥并发上限、CF 刷新 WebView 重建频率、
   响应侧大文本体分块策略）。

---

## 2026-10-14 22:00 CST | D12 活跃期桥负载探针（先量后改）

### 0) CI 前置核对
- **#70** `96bbfeea`（已读上报四计数）= in_progress，**卡在 step8「格式与静态分析」**
  （22:00 已约 25 分钟；该步逐文件跑 `dart analyze --fatal-infos`，2 核慢属正常）。
  **无 conclusion=failure，无需先修。**
- **#69** `4acb7cc9` = ✅ success（D11，`0.2.28.025`）；
  **#68** = ✅ success（D10，`0.2.28.024`），Release `ios14-test-68` 已出。
- 结论：无未修复 failure，可推进新工作。

### 1) 证据
- D1 `WebViewBridgeDiagnostics` 只有总量画像（请求数/字节/累计耗时），
  无法回答「活跃刷帖时桥是持续并发还是偶尔突发」「单次固定跨语言税多贵」。
- 老板实测 test-48 后空闲不热、刷一会仍发热 → 需先量出桥的**并发**与**单次成本**，
  否则下一轮改并发限流/D3 仍是盲改。

### 2) 改动
- 新增 `webview_bridge_probe.dart`：`concurrencyPeak`（并发峰值）、
  `concurrencySamples`/`idleSamples`（1s 采样→忙碌占比）、
  `inFlightMs`/`completedRequests`（平均在飞时长）；采样器仅在「有请求在飞」时启动，
  归零即停，空闲零开销；常开零日志。
- `webview_http_adapter.dart`：fetch 进入 `onRequestStart()`，finally
  `onRequestEnd(totalWatch.elapsed)`（成功/失败/取消都收敛）。
- `ios14_network_diagnostics_page.dart`：新增「活跃期桥负载探针（D12）」区块 + 清零按钮。
- 无 pauseTimers/resumeTimers、无滚动挂起、不改请求行为、不阻塞 JS。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：4 files **0 changed，exit 0** ✅。
- `flutter test webview_bridge_probe_test.dart`：**5 项全过** ✅。

### 4) 提交与 CI
- commit `1cba3697`，push `96bbfeea..1cba3697`。
- `APP_VERSION_SUFFIX` 025 → **026**。触发 workflow（HTTP 204）→ run 号下轮核对。

### 下一步
1. 核对 #70 与本轮 run → 确认 Release + IPA 直链。
2. 实机刷帖后看 D12：并发峰值高+忙碌占比高 → 下一轮做桥并发限流；
   平均在飞时长 ≫ 原生 → 走 D3 桥内降开销；两者都不高 → 转查 CF 刷新重建频率。
3. SS 接管内置浏览器方向与主线轮次交替。

---

## 2026-10-14 23:00 CST | D13 桥并发闸门（先量已备，本轮开始治）

### 0) CI 前置核对
- **#71** `1cba3697`（D12 探针）= **in_progress**，step1–9 全 success，
  当前跑 step10「构建未签名 IPA」（23:00 时约 54 分钟，正常编译耗时）。
  **无 conclusion=failure，无需先修。**
- **#70** `96bbfeea` = ✅ success；**#69** `4acb7cc9` = ✅ success（D11）。
- Release 已到 `ios14-test-70`。结论：无未修复 failure，可推进新工作。

### 1) 证据
- D12 探针已能测「并发峰值 / 忙碌占比 / 平均在飞时长」，但**只能测不能治**。
- 桥是**共享资源**：单个隐藏 WKWebView + 单条 JS 线程。无上限并发不会提高
  总吞吐——所有请求挤在一条 JS 线程上互相排队，每个都在飞更久，
  且每个在飞请求都持有桥回调与分块缓冲，CPU 峰值叠加、上下文切换与
  分块回调次数随并发数增长 → 总 CPU 时间不减反增。

### 2) 改动
- 新增 `lib/services/network/adapters/webview_bridge_gate.dart`
  （`WebViewBridgeGate`）：纯 Dart 有界信号量，默认 `maxConcurrent=4`，
  记录 `peakWaiting` / `queuedTotal`；等待用 `Completer` 队列，
  不轮询、不 Timer、空闲零开销；`release()` 名额转交（FIFO），
  `reset()` 只清统计不丢弃等待者。
- `webview_http_adapter.dart`：`fetch` 进入后 `await gate.acquire()`，
  `finally` 里 `gate.release()`（放在 `onRequestEnd` 之后，
  保证在飞时长统计包含排队时间）。
- `webview_bridge_diagnostics.dart`：新增 `imageResponseBytes`
  （同源图片走桥响应字节，D2 分流收益对比用），`reset()` 一并清零。
- `ios14_network_diagnostics_page.dart`：新增「桥并发闸门（D13）」区块
  （当前在飞/上限、排队峰值、累计排队）+ 判读 + 重置按钮。
- **硬性禁令遵守**：等待只发生在 Dart 侧，不碰 `pauseTimers`/`resumeTimers`，
  无滚动挂起，不阻塞 JS 执行。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：3 files **0 changed，exit 0** ✅。
- `flutter test webview_bridge_gate_test.dart webview_bridge_probe_test.dart`：
  **10 项全过** ✅。

### 4) 提交与 CI
- commit `0c371a61`，push `1cba3697..0c371a61`。
- `APP_VERSION_SUFFIX` 026 → **027**。触发 workflow（HTTP 204）→ **run #72**。

### 下一步
1. 核对 #71 / #72 → 确认 Release + IPA 直链。
2. 实机刷帖后看 D13：累计排队 > 0 且平均在飞时长下降 → 限流生效，
   可下调上限 4→3→2 找最优；排队为 0 → 并发本就不高，转查 CF 刷新重建频率。
3. SS 接管内置浏览器方向与主线轮次交替。

## 2026-10-15 00:00 CST | D14 JS 侧分块合并（活跃负载削峰·响应侧）

### 0) CI 前置核对
- **#72** `0c371a61`（D13 桥并发闸门）= ✅ success，Release **`ios14-test-72`** 已出
  （`fluxdo-ios14-test-72-0c371a61.ipa`，`0.2.28.027`）。
- **#71** `1cba3697`（D12）= ✅ success，Release `ios14-test-71` 已出。
- **#70** `96bbfeea` = ✅ success。
- 结论：无未修复 failure，Release/IPA 齐全，可推进新工作。

### 1) 证据：为什么做响应侧合并
- 二进制流响应路径（`_fetchBinaryStreamResponse`）里，JS 对 `response.body`
  逐 chunk `reader.read()`，**每个 chunk 各发一次 `postMessage`** 跨桥回传。
- 每个 `postMessage` 都要跨一次 JS↔native 边界（结构化克隆/转移 +
  Dart 侧 `setWebMessageCallback` 回调派发 + `_binaryMessageBytes` 分派 +
  `StreamController.add`）。活跃刷帖时大图以许多小 chunk 到达，
  边界穿越次数与 chunk 数同阶 → CPU 峰值叠加，属活跃期发热的结构性来源。
- D2 已把「同源图片」分流走原生，但**跨域图片与其它二进制流仍走桥**，
  且分流开关一旦因 CF 403 回退，全部图片又会回到这条逐 chunk 路径——
  所以把这条路径本身做轻，是无论分流与否都成立的收益。

### 2) 改动
- `webview_http_adapter.dart`（JS 脚本内）：新增 `pushChunk` / `flushPending`，
  把 reader 的小 chunk 攒进 64KB（`COALESCE_TARGET`）缓冲，
  满则一次性 `sendBuffer` 发出，流结束时 flush 余量。
  - **关键正确性**：`flushPending` 必须让 `out` 独占一块恰好 `pendingLen`
    的 ArrayBuffer（`new Uint8Array(pendingLen)` + `set`），因为
    `postMessage(buffer, [buffer])` 转移的是**整个** buffer，
    若沿用 64KB 大缓冲会把尾部未用字节一并送出 → 已按此实现。
  - 字节序与语义完全不变（仍是同一段连续字节，只是分批粒度更粗）。
  - 新增 `coalesceStats` 消息（rawChunks / sentMessages）回传统计。
- `webview_bridge_diagnostics.dart`：新增 `streamRawChunks` /
  `streamCoalescedMessages` 计数与派生 `streamMessagesSaved`；`reset()` 清零。
- `webview_http_adapter.dart`（Dart 侧）：消息处理器新增 `coalesceStats` 分支，
  累加两个计数。
- `ios14_network_diagnostics_page.dart`：新增「JS 侧分块合并（D14）」区块
  （原始 chunk → 合并后消息、省下的跨桥消息数）+ 判读；JSON report 增三字段。
- **硬性禁令遵守**：合并只发生在 JS 侧内存里，不碰 `pauseTimers`/`resumeTimers`，
  无滚动挂起，不阻塞 JS 执行。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：3 个改动 dart 文件 **0 changed，exit 0** ✅
  （新增测试文件亦 0 changed）。
- `flutter test`（gate + probe + 新增 coalesce）：**13 项全过** ✅。
- 注：本地 `flutter analyze` 因 2 核/3.7G 机器 OOM（analysis server exit -9），
  非代码问题；CI 在 macOS runner 上跑 analyze。

### 4) 提交与 CI
- commit `226c36f9`，push `0c371a61..226c36f9`。
- `APP_VERSION_SUFFIX` 027 → **028**。触发 workflow（HTTP 204）→ **run #73**（in_progress）。

### 下一步
1. 核对 #73 → 确认 Release + IPA 直链。
2. 实机刷帖后看 D14：原始 chunk 远多于合并后消息 → 合并生效；
   两者接近 → 响应 chunk 本就大或走 base64 fallback，转查响应侧序列化。
   可与 D13 排队数据交叉判读：若并发被闸门限住但发热仍在，
   说明单次在飞成本（含跨桥批数）才是主项 → D14 方向正确。
3. SS 接管内置浏览器方向与主线轮次交替。

## 2026-10-15 01:00 CST — D15 活跃发热归因速判
- 前置核对：#73 `226c36f9` success + Release `ios14-test-73` 已出；#72/#71 均 success，无未修复 failure。
- 排查（先证据）：帧监控 release 默认不跑、日志内存缓冲、DoH 解析有 TTL 缓存+socket 复用、
  iOS14.8 WebView 未进网关（MissingPluginException）→ 均非活跃发热主因。
- 改动：`webview_bridge_diagnostics.dart` 加派生 getter `activeLoadVerdict`（零开销速判）；
  诊断页展示速判行 + JSON report 增 `imageResponseBytes`/`activeLoadVerdict`；新增 5 个判据用例。
- 本地：dart format 3 文件 0 changed exit 0；判据分支独立脚本复刻跑通。
- commit `6e18e87a` + `c6843a49`；APP_VERSION_SUFFIX 028→029；触发 run #74（in_progress）。
- 下一步：核对 #74 出包；实机刷帖看 D15 速判定位真凶（桥 vs 渲染/解码/DoH 出口）。

## 2026-10-15 02:00 CST — D16 桥单位成本速判
- 前置核对：#74 `c6843a49` success + Release `ios14-test-74` 已出；#73/#72/#71/#70 均 success，无未修复 failure。
- 判断：D15 只答「桥搬了多少」，无法区分「字节总量」与「每请求固定税」。老板实测刷帖仍热 → 需单位成本判据。
- 改动：`webview_bridge_diagnostics.dart` 加派生 getter `bridgeCostVerdict`（零采样、零新增开销），
  三档阈值 250ms/125ms + 最少 8 样本；诊断页展示 + JSON report 增 `bridgeCostVerdict`/`avgInFlightMs`；
  新增 5 个判据用例。未触碰任何 WebView 挂起/暂停 API。
- 本地：dart format 3 文件 0 changed exit 0；判据分支独立脚本（含边界）跑通。
- commit `84ab8ca6`；APP_VERSION_SUFFIX 029→030；触发 run #75。
- 下一步：核对 #75 出包；实机刷帖看 D16——判「固定税主导」则做走桥请求条数瘦身。
- ⚠️ run #75 = ❌ failure：step8 报 `webview_bridge_diagnostics.dart:321 Undefined name 'WebViewBridgeProbe'`
  （D16 引用了未 import 的类，且 probe 反向 import diagnostics 会成环）。
- 修复 commit `a47bc69c`：去掉跨文件引用，判据只用 totalMs/totalRequests/jsEvalMs；
  本地 `dart analyze --fatal-infos webview_bridge_diagnostics.dart` = No issues found ✅；
  dart format 51 文件 0 changed exit 0。重触发 → run #76。
- 教训：新增对其它诊断类的引用前先确认已 import；本地必跑 dart analyze --fatal-infos。

## 2026-10-15 03:00 CST — D17 桥固定税拆解（回答「税花在哪」）
- 前置核对：#76 `a47bc69c` success（D16 修复生效）；#75 failure 已由 #76 修复，
  无未修复 failure；#74/#73/#72 均 success。
- 判断：D16 只答「桥单位成本贵不贵」，判贵了也不知道砍哪段。老板实测刷帖仍热，
  需把每请求耗时拆成三段定位靶点。
- 改动（纯累加/派生，零采样、零新增运行时开销、不碰任何 WebView 挂起 API）：
  - `webview_bridge_diagnostics.dart`：新增 `cookiePrepMs`/`browserWaitMs`/`cookieBackSyncMs`
    三个累加字段 + `bridgeTaxBreakdownVerdict` 派生 getter（三段占比 + 主导段判定，
    阈值 `bridgeTaxDominantRatio=50`）；reset 清零。
  - `webview_http_adapter.dart`：`_recordTimings` 里把 cookiePrep/browserWait/cookieBackSync
    三段耗时累加进 diagnostics（原本只写 per-request 日志字段，未聚合）。
  - `ios14_network_diagnostics_page.dart`：展示 D17 速判行 + JSON report 增 4 字段。
  - `test/.../webview_bridge_coalesce_test.dart`：新增 D17 判据 6 个用例。
- 本地：dart format 4 文件 0 changed exit 0；判据分支独立脚本复刻跑通（含 sum=0 边界）✅；
  `dart analyze --fatal-infos` 对 diagnostics/test 两文件 No issues（adapter/page 因 2 核 OOM 崩溃，非代码问题）。
- commit `affbc514`；APP_VERSION_SUFFIX 030→031；触发 run #77（in_progress）。
- 下一步：核对 #77 出包；实机刷帖看 D17 三段拆解——cookie 主导→砍 sweepAll；
  JS 主导→砍脚本体积/调用次数；等浏览器主导→转查 DoH 出口/渲染。

## 2026-10-15 04:00 CST — D18 走桥请求脚本瘦身（砍每请求 JS 解析固定税）
- 前置核对：#77 `affbc514` success + Release `ios14-test-77` 已出；#76 success；
  #75 failure 已由 #76 修复，无未修复 failure。
- 判断：D15/16/17 诊断侧已补齐（负载量/单位成本/成本拆解），但老板实测仍热 →
  需真正动手砍 D17 拆出的固定税。代码证据：每个走桥请求的 JS 脚本都重复内联
  与请求无关的 abort 辅助声明（`__fluxdoFetchAborters` + `__fluxdoAbortFetch`
  函数体 6 行），幂等却每请求重解析一遍 → 抬高 D17「JS 调用」段固定税。
- 改动（零语义变化，不碰 WebView 挂起 API）：
  - `webview_http_adapter.dart` 新增 `_installFetchHelpers(controller)`，
    `initialize()` 在 bootstrap 之后一次性把两个 abort 辅助装到 window。
  - 文本路径脚本 + 二进制流路径脚本：删掉重复的 `__fluxdoAbortFetch` 函数体声明，
    只保留 `__fluxdoFetchAborters = ... || {}` 一行兜底。
  - 安装失败只记日志，abort 退化为 no-op（`_abortWebViewFetch` 有存在性守卫），
    fetch 的 cookie/凭据/CF 指纹路径完全不变（过盾不受影响），不会白屏。
- 本地：dart format 1 文件 0 changed exit 0 ✅；dart analyze 因 2 核 OOM 崩溃
  （历史已知环境问题，非代码问题）；结构核对 `__fluxdoAbortFetch` 声明 3→1。
- commit `a4f8ac9c`；APP_VERSION_SUFFIX 031→032；触发 run #78（in_progress）。
- 下一步：核对 #78 出包；实机刷帖看 D17 的 `jsEvalMs` 是否下降（若 D17 判 JS 主导，
  本改动即直接命中靶点）。SS 接管方向与主线交替。

## 2026-10-15 04:00 CST — D19：同源图片分流做成诊断页运行时 A/B 开关
- 前置核对：#78 `a4f8ac9c` success，Release `ios14-test-78` 已出（版本 0.2.28.032）；
  #77 success；#75/76 已处理，无未修复 failure，可推进。
- 判断：上轮已把 D2「同源图片分流」静态开关提升为 service 运行时 ValueNotifier 并
  接线 platform_adapter 走桥判据，但**诊断页只有监听、无 A/B 切换 UI（半成品）**。
  图片是活跃刷帖时最大走桥负载（JS fetch + 分块 base64 跨桥回传），分流到原生 Dio
  是降活跃发热的直接命中点。本轮补齐 SwitchListTile 让实机即切即做 A/B。
- 改动（零行为变化基线，不碰 WebView 挂起 API；默认 true=分流开启，行为同旧版）：
  - `webview_adapter_settings_service.dart`：新增 imageNativeRoutingNotifier(true)/
    imageNativeRoutingEnabled getter/setImageNativeRouting()。
  - `platform_adapter.dart`：走桥判据改用 service 动态开关，删旧顶层静态 bool。
  - `ios14_network_diagnostics_page.dart`：同源图片分流说明下方加 SwitchListTile，
    initState/dispose 监听 notifier 驱动刷新。
  - `ios14-test.yml`：APP_VERSION_SUFFIX 032→033。
- 本地：dart format 3 文件 0 changed exit 0 ✅；dart analyze 因 2 核 OOM 崩溃
  （历史已知环境问题）；引用一致性核实（page UI/page 监听/platform_adapter 三处
  与 service 定义+import 全部匹配）。
- commit `见下`；触发 workflow。
- 下一步：核对本 run 出包；实机做 D2 A/B（先关分流刷帖对比，再开分流对比发热/
  图片加载/CF 403）；A/B 证实省热且不过盾则固化默认，若 403 则回退并写明数据。
  SS 接管方向与主线交替。

## 2026-10-15 08:00 CST — 阻断：GitHub Actions 被禁用，D19 无法出包
- 前置核对：#78 `a4f8ac9c` success（BJ 04:17），#77 success，#75 已修；
  但**最新 commit `eb19dc37`（D19，BJ 07:23 推送）没有任何对应 run** →
  不是漏触发，是触发被拒。
- 根因（已实测）：`POST .../actions/workflows/ios14-test.yml/dispatches`
  返回 **HTTP 422 `Actions has been disabled for this repository.`**
  矛盾点：仓库级 `GET /actions/permissions` 仍报 `enabled:true`、
  workflow `state:active`；PAT 正常（rate 4989/5000）。
  → 判定为**账号级 Actions 禁用**（longxiang1002 为免费 plan，通常因
  用量超限/滥用检测触发），仓库级 API 不会反映，网页端才会显示。
- 时间线：Actions 在 BJ 04:17（#78 成功）之后、BJ 07:23（D19 push）之前被禁。
- 本轮动作：D19 代码本地校验通过（git diff 3 个 dart 文件，
  `dart format --set-exit-if-changed` = 0 changed exit 0 ✅），代码已在远端
  `fix/ios14-network-thermal`（eb19dc37），**只差 CI 出包**。
- 阻断性质：非代码问题，需老板在 GitHub 网页端恢复 Actions
  （Settings→Actions→General 或账号 Billing/Support 申诉），我无法用 PAT 自行恢复。
- 下一步：老板恢复 Actions 后，重跑本 dispatch 即可出 D19 包；在此之前
  后续轮次只能做本地代码改造与静态验证，无法出 IPA。

## 2026-10-15 10:00 CST — D20：活跃发热归因（闸门排队 vs 单请求固定税）+ 阻断未解
- 前置核对：#78 `a4f8ac9c` success（Release ios14-test-78 / 0.2.28.032），
  #77 success，#76 已修；**Actions 仍被禁用**（本轮 dispatch 实测再返
  HTTP 422 `Actions has been disabled for this repository.`），D19(eb19dc37)
  与 D20(0135b9ec) 均无对应 run。阻断性质同上轮，需老板网页端恢复。
- 本轮判断：D15/D16/D17 只回答「桥搬了多少 / 贵不贵 / 贵在哪段」，但活跃
  刷帖发热有两种**互斥**成因，优化方向相反：(a) 并发洪峰排队（闸门满，CPU 花在
  等待/唤醒/分块回调）→ 对策=下调并发上限或继续分流；(b) 单请求固定税
  （几乎不排队，但每请求都付跨语言 evaluateJavascript + 分块回传）→ 对策=砍
  脚本体积/合并调用/减少走桥条数，限流无收益。缺一个把两者分开的判据。
- 改动（纯派生只读计数，零采样、零新增运行时开销，不碰任何 WebView 挂起 API）：
  - `webview_bridge_diagnostics.dart`：新增 `gateVsTaxVerdict` getter
    （排队占比 ≥20% 判「闸门排队主导」；否则平均在飞 ≥250ms 判「固定税主导」；
    再否则判「桥非主因」）+ 阈值常量 `gateQueueDominantRatio=20`；加
    `library;` 与 import gate/probe（无环）。
  - `webview_bridge_probe.dart`：删掉未实际使用的 import（原为文档交叉引用），
    避免与 diagnostics 反向引用形成循环 import。
  - `ios14_network_diagnostics_page.dart`：诊断页加 D20 一行展示 + 报告 map 加
    `gateVsTaxVerdict` 字段。
  - `ios14-test.yml`：APP_VERSION_SUFFIX 033→**034**。
- 本地：dart format（CI 同款 3.12.0）3 文件 **0 changed exit 0** ✅；
  dart analyze 因 2 核 OOM 崩溃（历史已知环境问题）。
- commit `0135b9ec`；push 成功；dispatch 被 422 拒（Actions 禁用）。
- 下一步：老板恢复 Actions 后重跑 dispatch 出 D20 包（0.2.28.034）；实机刷帖
  前后各看一次诊断页，用 D20 判据决定下一步是「下调并发上限」还是「砍脚本」。

## 2026-10-15 11:00 CST — D21：闸门饱和度归因（活跃并发量化）+ 阻断未解
- 前置核对：#78 `a4f8ac9c` success（Release ios14-test-78 / 0.2.28.032），
  #77/#76 success；**Actions 仍被禁用**（本轮 dispatch 实测再返 HTTP 422
  `Actions has been disabled for this repository.`），D19(eb19dc37)/D20(0135b9ec)/
  D21(31c283fe) 均无对应 run，只差 CI 出包。
- 本轮判断：D20 用「排队占比」判断限流值不值得做，但排队占比为 0 有两种互斥
  含义——(a) 并发本就不高（桥非瓶颈）；(b) 并发长期顶在上限、闸门把洪峰削平。
  两者优化方向相反，缺一个区分量。而 D12 的并发采样只在「有请求在飞」时每秒
  +1，busyRatio 恒 100%，回答不了「桥有多忙」。
- 改动（纯派生只读计数，零采样新增、零运行时开销，不碰任何 WebView 挂起 API）：
  - `webview_bridge_probe.dart`：新增活跃期「在飞数 × 时间」积分
    `inFlightIntegralMs` + 活跃采样时长 `activeSampledMs`（采样器运行期间每秒
    累加 `_inFlight*1000`，_stopSampler 按实际毫秒结算尾段），派生
    `averageActiveConcurrency`。
  - `webview_bridge_diagnostics.dart`：新增 `gateSaturationVerdict`
    （平均并发/上限 ≥75% 判饱和 → 限流/分流仍有收益；37.5%~75% 中度占用 →
    优先分流；<37.5% 远未打满 → 桥非主因，转查渲染/解码/DoH）+ 阈值常量
    `gateSaturationRatio=0.75`。
  - `ios14_network_diagnostics_page.dart`：加 D21 展示行 + 探针区「活跃期平均
    并发」行 + 报告 map 三个字段。
  - `ios14-test.yml`：APP_VERSION_SUFFIX 034→035。
- 本地：dart format（CI 同款 3.12.0）3 文件 **0 changed exit 0** ✅；
  dart analyze 因 2 核 OOM 崩溃（历史已知环境问题）。
- commit `31c283fe`；push 成功；dispatch 被 422 拒（Actions 禁用）。
- 下一步：老板恢复 Actions 后重跑 dispatch 出 D21 包（0.2.28.035）；实机刷帖
  前后各看一次诊断页，用 D21 判据决定「下调闸门上限」还是「转查渲染/DoH」。

## 2026-10-15 12:00 CST — D22：限流实验可执行化（运行时并发上限 A/B）+ 阻断未解
- 前置核对：#78 `a4f8ac9c` success（Release ios14-test-78 / 0.2.28.032），
  #77/#76 success，无遗留 failure；**Actions 仍被禁用**（本轮 dispatch 实测再返
  HTTP 422 `Actions has been disabled for this repository.`），
  D19(eb19dc37)/D20(0135b9ec)/D21(31c283fe)/D22(c4b97748) 均无对应 run，只差 CI 出包。
- 本轮判断：D20（排队占比）与 D21（闸门饱和度）各自只回答一半问题，且**单独看会
  互相打架**——排队高说明闸门已在削峰（再降只会更堵）；饱和度低说明并发本就不高
  （限流无收益）；只有「饱和度高 + 排队占比低」才是「上限恰好卡住活跃负载」的特征，
  此时降上限（4→3→2）最有希望。缺一个把两者合成**可执行结论**的判据；且此前每试
  一档上限都要改代码+重出包，而 CI 又被禁，等于实验做不了。
- 改动（纯派生只读计数 + 一个运行时开关，零采样、零新增运行时开销，不碰任何
  WebView 挂起/暂停 API，不阻塞 JS 执行）：
  - `webview_bridge_diagnostics.dart`：新增 `gateTuningVerdict` getter，把 D20 排队
    占比与 D21 饱和度合成四种可执行结论（值得做 / 已过头 / 先查排队来源 / 无收益）；
    加常量 `gateQueueHighRatio`（复用 `gateQueueDominantRatio`=20）。
  - `webview_adapter_settings_service.dart`：新增 `gateMaxConcurrentNotifier`
    （默认 4，与 D13 初值一致）+ `setGateMaxConcurrent()`（下限保护 1，避免 0 让
    所有走桥请求永久排队）；setter 直接写 `WebViewBridgeGate.maxConcurrent`。
  - `ios14_network_diagnostics_page.dart`：诊断页加 D22 建议行 + 运行时上限
    ChoiceChip（2/3/4/6，即切即生效）+ 报告 map 加 `gateTuningVerdict` /
    `gateMaxConcurrent` 两字段 + 监听器注册/注销。
  - `ios14-test.yml`：APP_VERSION_SUFFIX 035→**036**。
- 本地：dart format（CI 同款 3.12.0）3 文件 **0 changed exit 0** ✅
  （首跑 2 changed → 已格式化后复检通过）；dart analyze 因 2 核 OOM 崩溃（已知环境问题）。
- commit `c4b97748`；push 成功；dispatch 被 422 拒（Actions 禁用）。
- 下一步：老板恢复 Actions 后重跑 dispatch 出 D22 包（0.2.28.036）；实机刷帖一轮，
  看 D22 建议行——判「值得做」就在诊断页把上限切到 3 再刷一轮对比发热；
  判「无收益」则转查渲染/图片解码/DoH 出口。

## 2026-10-15 13:00 CST — D24：A/B 开关跨重启持久化（阻断未解，第 5 轮）
- 前置核对：#78 `a4f8ac9c` success（Release ios14-test-78 / 0.2.28.032），
  #77/#76 success，无遗留 failure；**Actions 仍禁用**（本轮 dispatch 实测再返
  HTTP 422；`POST /actions/runs/78/rerun` 返 404，进一步印证账号级禁用）。
  D19–D24 六个 commit 均无对应 run。
- 本轮判断：D19/D22 把「图片分流」「桥并发上限」做成运行时 A/B，但**只存内存**。
  实机对比发热必须重启 App（TrollStore 覆盖装/崩溃/手动杀）时，档位会静默回落到
  默认值，A/B 数据作废——这是当前唯一还能在 CI 被禁期间推进的实机可用性缺口。
- 改动（纯设置持久化，零运行时开销、零采样，不碰 WebView 挂起/暂停 API）：
  - `webview_adapter_settings_service.dart`：新增 `_imageNativeRoutingKey` /
    `_gateMaxConcurrentKey`；两个 setter 改为 `unawaited(_prefs?.setBool/setInt(...))`
    落盘；`initialize()` 恢复两档并同步 `WebViewBridgeGate.instance.maxConcurrent`；
    `resetForTest()` 复位到 true / `defaultMaxConcurrent`；补 `import 'dart:async'`。
  - `ios14-test.yml`：APP_VERSION_SUFFIX 036→**037**。
- 本地：dart format（CI 同款 3.12.0）1 文件 **0 changed exit 0** ✅；
  dart analyze 单文件仍崩（2 核 OOM / analysis server crashed，历史环境问题）。
- commit `81316167`；push 成功（origin 已同步）；dispatch 422。
- 下一步：老板恢复 Actions 后重跑 dispatch 出 D24 包（0.2.28.037）；实机设档→重启
  →确认档位保持→刷帖对比发热。SS 接管内置浏览器方向下轮交替推进。

## 2026-10-15 14:00 CST — D25：跨桥字节搬运税归因（阻断未解，第 6 轮）
- 前置核对：#78 `a4f8ac9c` success（Release ios14-test-78 / 0.2.28.032 已出），
  #77/#76 success，无遗留 failure；**Actions 仍禁用**（本轮 dispatch 实测再返
  HTTP 422）。D19–D25 七个 commit 均无对应 run。
- 本轮判断：D16~D22 的归因全部建立在 `totalRequests` 这个**混合口径**上，但桥上
  有两条成本结构差一个数量级的路径——文本响应（`callHandler` 一次性回传，≈1 次
  跨语言往返）与二进制流（`createWebMessageChannel` 建通道 + `postWebMessage`
  握手 + 每 chunk 一次 `setWebMessageCallback` 回调，≈2+N 次）。若活跃期走桥的
  以流为主，「每请求固定税」的真实大头是**通道建立 + 分块回调**，此时砍脚本体积
  毫无收益，该砍的是走桥的流请求条数（即继续 D2 方向的静态资源分流）。缺一个把
  这个拆出来的判据。
- 改动（纯派生只读计数，零采样、零新增运行时开销，不碰任何 WebView 挂起/暂停 API，
  不阻塞 JS 执行）：
  - `webview_bridge_diagnostics.dart`：新增 `binaryBridgeResponses` /
    `binaryBridgeBytes` / `binaryBridgeChunks` 三个聚合计数；新增
    `bridgeByteTaxVerdict` getter（三种可执行结论：流路径主导 / 文本路径主导 /
    无流走桥）；阈值常量 `bridgeByteTaxStreamDominantRatio`=30；`reset()` 一并复位。
  - `webview_http_adapter.dart`：`bridge.done.whenComplete` 里累加三个计数。
  - `ios14_network_diagnostics_page.dart`：加 D25 结论行 + 流路径固定成本明细行 +
    报告 map 三个字段。
  - `ios14-test.yml`：APP_VERSION_SUFFIX 037→**038**。
- 本地：dart format（CI 同款 3.12.0）3 文件 **0 changed exit 0** ✅。
- commit `ce762103`；push 成功；dispatch 被 422 拒（Actions 禁用）。
- 下一步：老板恢复 Actions 后重跑 dispatch 出 D25 包（0.2.28.038）；实机刷帖一轮
  看 D25 结论行——判「流路径主导」则继续把静态资源分流原生栈；判「文本路径主导」
  则优先减少走桥请求条数。SS 接管内置浏览器方向下轮交替推进。

## 2026-10-15 16:00 CST — D27：图片分流豁免名单（阻断未解，第 7 轮）
- 前置核对：#78 `a4f8ac9c` success（Release ios14-test-78 / 0.2.28.032 已出）；
  #77/#76 success，无遗留 failure；**Actions 仍禁用**（本轮 dispatch 实测再返
  HTTP 422 「Actions has been disabled for this repository」）。D19–D27 共 9 个
  commit 均无对应 run、出不了包。
- 本轮判断：D2 把同源图片**整体**分流原生栈，但回退手段只有「整体开关」
  （`imageNativeRoutingEnabled` 置 false）——一旦某条图片路径实测被 CF 拦/变糊，
  关掉开关就把已省下的全部桥负载吐回去，实验只能二选一。缺「逐条豁免」的粒度。
- 改动（零运行时开销、零采样，不碰任何 WebView 挂起/暂停 API，不阻塞 JS）：
  - `webview_adapter_settings_service.dart`：新增 `_imageSkipPathsKey` 持久化键 +
    `imageSkipPathsNotifier` + `isImageRoutingSkipped(uri)`（path 小写子串匹配）
    + `addImageSkipPath` / `removeImageSkipPath` / `clearImageSkipPaths`（均落盘）；
    `initialize()` 恢复名单；`resetForTest()` 复位为空。
  - `platform_adapter.dart`：图片分流分支加豁免判断——命中名单则**仍走桥**并
    累加 `imageRoutingSkipped`，否则照旧分流并累加 `imageRoutedNative`。
  - `webview_bridge_diagnostics.dart`：新增 `imageRoutingSkipped` 计数并纳入 `reset()`。
  - `ios14_network_diagnostics_page.dart`：报告加 `imageRoutingSkipped` /
    `imageSkipPaths` 两字段；页面加「豁免次数」行 + 名单行 + 「加一条跳过片段」
    弹窗 / 清空 / 逐条删除（InputChip）；监听 `imageSkipPathsNotifier`。
  - `ios14-test.yml`：APP_VERSION_SUFFIX 038→**039**→（本轮最终）**040**。
- 本地：dart format（CI 同款 3.12.0）5 文件 **0 changed exit 0** ✅
  （首轮 3 changed，已用同款 dart format 就地修正后复检 0 changed）。
- commit `a74d4eef`；push 成功（origin 已同步）；dispatch 被 422 拒（Actions 禁用）。
- 下一步：老板恢复 Actions 后重跑 dispatch 出 D27 包（0.2.28.040）；实机刷帖若见
  某路径图片 403/变糊，在诊断页把该路径片段加入豁免名单即时验证，不必整体关分流。
  SS 接管内置浏览器方向下轮交替推进。
