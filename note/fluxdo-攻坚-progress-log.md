# FluxDO 攻坚 · 进度日志

> 格式：`北京时间 | 本轮改动 | commit | CI 状态 | 下一步`
> 时间一律北京时间（UTC+8）。

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
