# FLUXDO_IOS_FIX — iOS 14.8 发烫 + 频繁过盾攻坚

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。

## 已完成（有 CI 出包）

- [x] P1 过盾：iOS UA 对齐真实系统版本（`fa2fa96d`+`df801cb2`+`b3300540`，run 37779567105 / ios14-test-6）
- [x] P3 过盾：retry 403 自动 session WebView fallback（`70bbd5c6`，run 37798457544）
- [x] P2 过盾：iOS 出口一致性（`8fa0082f`+`630be5b6` 格式+`99d0bf59` 编译修复，run 37821106515 / ios14-test-11）
- [x] **修复白屏回归**：iOS 禁用滚动挂起（`446846a9`，run 37830118944 全绿 / ios14-test-8 已发布）
- [x] **P4 文档**：`docs/ios14-network-thermal-milestone.md` + CHANGELOG ios14-fix 段（`2f383617`，2026-10-09 04:00 轮；其 CI run `37835082406` 已于 05:00 轮确认「格式与静态分析」「iOS14 兼容与 CF 回归测试」双绿）
- [ ] **iOS 降发热·销毁式省电**：iOS 常驻 Turnstile WebView 进后台/前台空闲即销毁（`b1a5e341`，CI run `37838762957` **本轮内未出结论**）

## 🚫 硬性禁令（老板实机确认的回归，违反即回滚）

**绝不在 iOS 使用 `InAppWebViewController.pauseTimers`/`resumeTimers`，也绝不把任何
「滚动挂起 / 暂停 WebView」逻辑引入 iOS 路径。**

`pauseTimers()` 在 iOS 上的实现是 `evaluateJavaScript("alert();")`
（`flutter_inappwebview_ios .../InAppWebView.swift:3207-3213`）。未决的 `alert()`
阻塞整个 WebContent 进程 → 同进程内的用户手动验证弹窗一并卡死 → **验证页白屏**
（老板实测复现，test-7 引入 / test-8 修复）。

iOS 若需降发热，**只能**从 Turnstile 实例存活时长 / tick 频率 / 轮询间隔等
**不触碰 WebView JS 执行**的手段入手，且改动说明里必须论证「不会阻塞 JS」。

## 本轮（2026-10-09 04:00 CST）— P4：里程碑文档 + CHANGELOG

**断点核对**：HEAD 原为 `446846a9`（白屏回归修复）；CI run 37830118944 全绿，
Release `ios14-test-8` 已发布。上一轮遗留的 P4（写 CHANGELOG / 里程碑说明）是
TODO 里唯一被勾了但**实际产物不存在**的项——`docs/ios14-network-thermal-milestone.md`
在仓库里查无此文件。本轮补齐。

**改动**（纯文档，无代码/行为变更）：

- 新增 `docs/ios14-network-thermal-milestone.md`：问题与目标 → 根因证据
  （常驻 Turnstile 发热 / Dio-WebView 出口不一致 / UA 指纹不一致 /
  pauseTimers 白屏回归）→ 已交付改动表（含 commit/run/artifact）→
  P2 两个易错点（macOS-only 常量、NSNumber port）→ 交付物 → 验收方法 → 待办边界
- `CHANGELOG.md` 新增 `[ios14-fix]` 段落，覆盖本分支已交付的修复与变更

- [x] 新增 `docs/ios14-network-thermal-milestone.md`
- [x] `CHANGELOG.md` 追加 ios14-fix 段
- [x] commit `2f383617` + push fix/ios14-network-thermal
- [ ] 触发 run 374182066 并轮询 CI（run `37835082406` 已触发，本轮内**未等到完成**——
      「格式与静态分析」步骤单文件 `dart analyze` 约 11 分钟，本轮 25 分钟预算已用尽）

**诚实标注**：本轮 push 成功，但 **CI 结果未确认**（触发时已 03:51，轮内预算不足）。
纯文档改动不参与 `git diff --diff-filter=ACMR -- '*.dart'` 过滤，理论上无格式/分析风险，
但仍须确认。留待下一轮第一件事：核对 run `37835082406` 结论。

## 上一轮核对（2026-10-09 05:00 CST）— 遗留 CI 结论确认

run `37835082406`（commit `2f383617`，纯文档）经 jobs API 核对：
- 「格式与静态分析」✅ success
- 「iOS14 兼容与 CF 回归测试」✅ success
- 「构建未签名 IPA」**仍在 in_progress**（超过 30 分钟，属该 runner 常态慢）

→ 纯文档改动无格式/分析风险，结论与预判一致。**无需重发 Release**（文档不随
artifact 分发）。该项关闭。

## 本轮（2026-10-09 05:00 CST）— P1 发热：iOS 销毁式省电

**约束复盘**：iOS 无可用实例级挂起（`pauseTimers` = `evaluateJavaScript("alert();")`，
未决 alert 阻塞 WebContent → 手动验证页白屏，老板实测已确认）。所以「滚动挂起」
一类手段在 iOS 上永久禁用。可用的替代必须是**只释放/重建实例、不触碰 JS 执行**
的手段 —— 即「缩短 Turnstile 实例存活时长」。

**改动**（`lib/services/cf_clearance_refresh_service.dart`，commit `b1a5e341`）：

- 新增 `_shouldDisposeOnBackground => io.Platform.isIOS`（唯一 platform 门）
- `pause()`：iOS 分支不再只停计时器保留实例，而是 `_generation++` +
  `_disposeWebView(reason: 'lifecycle_background')` 直接销毁。回前台 `resume()`
  走既有「有期望无实例 → `_startWebView()`」分支重建，无需新分支。
- 新增 `_armIdleDisposeTimer(gen)`：iOS 前台静默超过 `_iosIdleDisposeDelay`（5min）
  且离绝对过期 `>` `_minTtlBeforeIdleDispose`（2min）时销毁
  （`reason: 'ios_idle_dispose'`）。在 `_startTimers` 末尾 / `onTurnstileToken` 回调 /
  cookie 前进（`_syncAndCheckCookies` advanced 分支）三处重置。
- `_cancelRuntimeTimers()` 增加 `_iosIdleDisposeTimer` 清理。

**为什么不会重演白屏**：全程只有 `dispose()` + `HeadlessInAppWebView.run()`，
不调用任何 pause/挂起 API，不向 WebView 注入阻塞脚本；销毁是「释放」而非「冻结」，
被销毁页面的 JS 停止运行是预期结果（页面本身也随实例消失），不存在「同进程其他
WebView 被 alert 卡死」的路径。

**为什么不会增加过盾**：cf_clearance 续期主路径是事件驱动（load_stop / token /
expired / error 即时同步）+ 2min 兜底轮询 + 8min stale 窗口检测；空闲销毁只在
**离过期还有 2min 以上**时发生，且 Turnstile 首次验证期（`_initialTimer` 未清）
一律不销毁。重建成本是一次 `loadData`。

**验证**：
- `dart format --output=none --set-exit-if-changed` → `0 changed` ✅
- analyzer 10.2.0 `parseFile` 语法解析 → `total_errors=0` ✅
  （本机 `dart analyze` 仍 OOM，只能用 parse-only 做本地语法兜底）
- `grep pauseTimers/resumeTimers` → 仅注释，无实际调用 ✅
- commit `b1a5e341` 已 push；CI run `37838762957` 已触发

- [x] 代码改动 + `dart format` 通过
- [x] 本地 parse-only 语法校验 0 error
- [x] commit `b1a5e341` + push
- [x] 触发 run 374182066（run `37838762957`）
- [x] **轮内部分确认**：run `37838762957` step 7「格式与静态分析」✅、
      step 8「iOS14 兼容与 CF 回归测试」✅ —— 改动与本地自检结论一致
- [ ] **step 9「构建未签名 IPA」/ step 10 出包**（本轮内仍在 in_progress，交下一轮）

**诚实标注**：代码已 push，CI 的格式/静态分析/兼容回归三道关**已全绿**，但
**IPA 出包尚未确认**（step 9 常态 30min+）。**不得当作里程碑**，下一轮第一件事：
核对 run `37838762957` 是否产出 artifact。

## 待办

- [ ] **核对 CI run `37838762957`（commit `b1a5e341`）的 step 9/10**：格式✅ 兼容✅
      已确认；只差 IPA 出包。出包绿 → 记为里程碑并考虑发 Release
- [ ] 老板实机验证（test-8 或新包）：发热、CF 弹窗次数、手动验证弹窗是否正常
- [ ] 若实测发热仍高：下一步候选 = 缩短 `_iosIdleDisposeDelay`（5min → 2min），
      或把 `_cookiePollInterval` 在 iOS 上再拉宽（当前 2min，事件驱动为主路径）
- [ ] 里程碑 tag（Release ios14-test-8 已发布，tag 由发布流程创建）

## 环境备忘（本轮新增可用工具链）

服务器原本「无 Flutter/Rust SDK」，本轮已就地搭起**可用的 Dart 校验链**：

- `/tmp/flutter`（Flutter 3.44.0 / Dart 3.12.0，与 CI 完全同版本）
- `/tmp/dartsdk312/dart-sdk/bin/dart`（独立 Dart 3.12.0）
- `core/doh_proxy`、`packages/fluxdo_render` 子模块已 init（`flutter pub get` 需要）

可用：`/tmp/dartsdk312/dart-sdk/bin/dart format --output=none --set-exit-if-changed <file>`
（已验证：对 `lib/services/cf_clearance_refresh_service.dart` 输出 `0 changed`）

不可用：`dart analyze` / `flutter analyze` —— 3.7G 内存机器上 analysis server 会被
OOM kill（exit -9），包括 `chmod +x` 修掉入口权限问题之后仍然崩溃。
**结论：本地只能做 `dart format`，静态分析必须交给 CI（约 11 分钟）。**

**本轮新增可用的本地语法校验**（比 CI 快，补 `dart analyze` 的缺口）：

- `/tmp/parsechk`（analyzer 10.2.0 的 parse-only harness）
- 用法：`/tmp/dartsdk312/dart-sdk/bin/dart run /tmp/parsechk/bin/main.dart <file.dart>`
- 输出 `total_errors=0` = 语法层通过（不含类型检查，类型错误仍需 CI）
- `find /root/.pub-cache -maxdepth 3 -name "analyzer-*"` 可确认版本

**本轮新增：runner 慢已是常态** —— 一次 run 从触发到出结论约 20~40min
（「构建未签名 IPA」单步即可超过 30min）。单轮 25min 预算内基本不可能等到
完成，故每轮应「触发 + 记录 run id + 下一轮核对」，不要在同一轮里空等。
