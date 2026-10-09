# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-09 起方向切换**：发热/过盾暂缓，唯一主攻 = **DoH 代理接管内部浏览器流量**。

## 🎯 本轮（2026-10-09 14:00 CST）— 路径 A 结案：guard 是**对的**，真根因 = iOS<17 无法在系统设置里注入 per-app 代理

### 本轮结论（源码级确证，三个独立证据）

**`_requiresUnsupportedProxySkips()` 里那条 iOS<17 guard 必须保留，放宽即
`MissingPluginException` + iOS14 兼容性崩。** 证据：

1. **插件原生侧根本不存在 iOS<17 的实现**
   `flutter_inappwebview_ios-1.2.0-beta.3/ios/.../InAppWebViewFlutterPlugin.swift:64`
   ```swift
   if #available(iOS 17.0, *) { proxyManager = ProxyManager(plugin: self) }
   ```
   `ProxyManager.swift:10` 整个类就是 `@available(iOS 17.0, *)`，
   `setProxyOverride` 唯一实现是 `WKWebsiteDataStore.default().proxyConfigurations`
   （ProxyManager.swift:45-49，Apple 该 API 就是 iOS 17 起）。
   → iOS 14 上 MethodChannel `com.pichillilorenzo/flutter_inappwebview_proxycontroller`
   **从未注册**，Dart 侧调用必抛 `MissingPluginException`（issue #2265 同款）。

2. **即使放宽 guard，iOS14 也无法用「系统代理」替代**
   本仓库 `ios/Runner/SystemProxyReader.swift` 读的是
   `CFNetworkCopySystemProxySettings()` / `CFNetworkCopyProxiesForURL()`。
   这两者读的是**系统全局代理设置**；iOS 上第三方 App **无权**写它
   （只有 MDM/描述文件或 App 内有设置界面的 VPN App 能改）。
   → 想让 WKWebView 走 `127.0.0.1:<port>` 本地 DoH 网关，在 iOS 14 上
   **没有任何进程内可用的 API**。

3. **插件也没有 iOS 侧的 `shouldInterceptRequest`**（路径 B 在 iOS 上不可行）
   `flutter_inappwebview_platform_interface-1.4.0-beta.3/lib/src/in_app_webview/platform_webview.dart:1687-1707`
   的 `@SupportedPlatforms` 只列 Android / Windows / Linux；
   `grep -rn "shouldInterceptRequest" flutter_inappwebview_ios-1.2.0-beta.3/ios/`
   **0 处命中**（Dart 侧有事件分发代码，原生侧无实现）。
   `decidePolicyFor navigationAction` 只提供 allow/cancel，**不改请求**（InAppWebView.swift:1917+）。

### 本轮改动（1 commit）
- [x] `lib/pages/webview_page.dart`：把「同一个出口 IP」这个前提从**只 iOS**
      放宽为 iOS/macOS **共用**采样（`_logWebViewExitConsistency` 的
      `Platform.isIOS` 早退 → `!isIOS && !isMacOS`），与
      `_systemProxyUrlForGateway()` 的两平台出口一致性语义对齐；
      **不改变 iOS 行为，只多一条 macOS 日志**。
- [x] `lib/services/network/system_proxy_service.dart`：修正 `probeEffectiveProxy()`
      doc 里「非 iOS 返回 null」的错误措辞（原生实现本就是 iOS+macOS 都有），
      并说明该探针是「内部浏览器出口是否跟随系统代理」的**唯一直接证据**，
      与 `_resolveEgressVerified` 的 iOS 判定分工。
- [x] **明确不做的**：不放宽版本 guard、不引 `pauseTimers/resumeTimers`（硬禁令）、
      不在 iOS 侧伪造 `shouldInterceptRequest`。

### 为什么这轮算「实质推进」而不是文档轮
前几轮一直在「补诊断 + 猜 guard 来源」；本轮用**三份上游源码 + Apple API 语义**
把路径 A / B / C 全部判死（或标注前提未验证），把剩余可行空间收敛到
**唯一一条**：iOS<17 的出口一致性只能靠「外部系统代理/VPN（如 Clash 系统代理
或 TUN）」这种**进程外**手段，即
`docs(结论): WebView DoH 接管在 iOS<17 无进程内解`。这让下一轮不再重复走死路。

### 下一轮（若老板不否决该结论）
- [ ] 把结论固化进 `lib/services/network/doh/network_settings_service.dart` 的
      `_requiresUnsupportedProxySkips()` doc（把「本函数没法解决」升级为
      「全平台层面无解 + 替代路径清单」）。
- [ ] 在 `ios14_diagnostics_page.dart` 增加一行文案：iOS<17 用户需把
      Clash/规则代理设为**系统代理**（而非仅 TUN 之外的模式）才能让内部浏览器
      与 rhttp/Dio 同出口；否则只能 TUN 全域接管。
- [ ] （需老板拍板）若要「进程内接管」，唯一路线是自写
      `WKURLSchemeHandler`/`WKContentRuleList` 或换用支持 iOS14 的 fork，
      成本高、且对 `https://` 主站导航要整页代发，风险大 → 建议先不做。

---

## 🎯 上轮（2026-10-09 13:00 CST）— step9 Swift 编译阻塞**已破冰，CI 出包成功**

**关键里程碑**：commit `64ddaaa0` → run **`37886570564`** → **success**（13:01 CST 触发），
已生成无签名 IPA（Release `ios14-test-*`）。step9 的 CF 类型问题彻底解决：
`CFNetworkCopyProxiesForURL` 第二参数用显式 `CFDictionary?`，不再猜 allocator。

**本条修正 12:00 轮的过度悲观**：当时判断「首次走到构建 IPA 才暴露问题」，
实际是 CF 函数签名一路猜错；修对后一次通过。

---

## 🎯 上上轮（2026-10-09 12:00 CST）— step9 Swift 编译阻塞**第二轮**：`kCFAllocatorDefault` 用错类型

### 事实修正：11:00 轮的修法是**错的**
11:00 轮把 `nil` 换成 `kCFAllocatorDefault`，以为「CFNetwork 自行取系统级设置」。
run `37877390735`(`b3b2029a`) 最终 **failure@step 9**，日志原文
（`actions/jobs/113649001266/logs` 第 1685 行）：

```
Swift Compiler Error (Xcode): Cannot convert value of type 'CFAllocator' to expected argument type 'CFDictionary'
  /Users/runner/work/fluxdo/fluxdo/ios/Runner/SystemProxyReader.swift:67:64
```

**真根因**：`CFNetworkCopyProxiesForURL(_:proxySettings:)` 第二个参数要的是
**`CFDictionary`（代理设置字典）**，而 `kCFAllocatorDefault` 是 **`CFAllocator`**
——名字像、类型完全无关。11:00 轮的「语义等价」判断是错的：那是 allocator 不是设置。
（11:00 轮另一个错也被本条覆盖：报错只有 **1 个**，此前记「两个错」是把 09:00 轮
`nil` 桥接失效引发的**连带**推断错误当成独立缺陷。）

**教训**：CF 函数带 `Copy`/第二个参数往往是**设置对象**，`kCFAllocatorDefault` 只用于
`CFXxxCreate(allocator,...)` 这类显式带 allocator 形参的构造器。不确认签名就别猜。

### 改动（1 commit，已 push）
- [x] `ff87b235` `fix(ios14): pass nil as CFDictionary? to CFNetworkCopyProxiesForURL (step9)`

```swift
// 第二个参数是 `CFDictionary?` 的 proxySettings（可空）。
let proxySettings: CFDictionary? = nil
let entries = CFNetworkCopyProxiesForURL(probeURL as CFURL, proxySettings)
  .takeRetainedValue() as? [[String: Any]]
```

- 显式声明 `CFDictionary?` 再传 `nil` → 类型合法，且让 CFNetwork 取**当前进程生效**的
  系统代理设置（这正是本探针的语义目标）
- **JSON 输出字段全部不变**（`count`/`systemProxyUrl`/`entries`/`type`/`probeHost`/
  `host`/`port`/`hasPacScript`/`consistentWithSystem`），Dart 侧 `SystemProxyProbe` 无需改动
- 引入 `CFAllocator` 到 `SystemProxyReader.swift` 的**只有注释**，调用处已无该常量

### 12:00 轮 CI
- commit `ff87b235` → run **`37882148105`**（12:04 CST 触发，最终 failure@step9）
- 关键观察点仍是 **step 9**

---

## 🎯 更早（2026-10-09 11:00 CST）— 修 step9 Swift 编译阻塞（首次走到「构建 IPA」才暴露）

### 关键事实修正（09:00 轮日志的乐观结论有误）
09:00 轮记「step7 破冰，step 8 已 in_progress，等出包」——**too early**。
run `37873771518`(`6819d488`) 最终 **failure@step 9（构建未签名 IPA）**：
自建 Swift 文件 `ios/Runner/SystemProxyReader.swift` 编译不过。

### 本轮改动
- [x] `b3b2029a` `fix(ios14): make SystemProxyReader compile on iOS 14 (build step9 blocker)`

---（更早轮次见 `note/fluxdo-攻坚-progress-log.md`）

## 📌 最近 CI 一览

| run id | commit | 北京时间 | 结果 |
|---|---|---|---|
| `37887902403` | `64ddaaa0` | 10-09 13:17 | in_progress（本轮触发时仍未完） |
| `37886570564` | `64ddaaa0` | 10-09 13:01 | ✅ **success（出包）** |
| `37882148105` | `ff87b235` | 10-09 12:04 | ❌ failure@step 9 |
| `37877390735` | `b3b2029a` | 10-09 11:02 | ❌ failure@step 9 |
| `37873771518` | `6819d488` | 10-09 10:16 | ❌ failure@step 9 |

## 🚫 硬性禁令（老板实机确认的回归，违反即回滚）

**绝不在 iOS 使用 `InAppWebViewController.pauseTimers`/`resumeTimers`，也绝不把任何
「滚动挂起 / 暂停 WebView」逻辑引入 iOS 路径。**

`pauseTimers()` 在 iOS 上的实现是 `evaluateJavaScript("alert();")`。未决的 `alert()`
阻塞整个 WebContent 进程 → 同进程内的用户手动验证弹窗一并卡死 → **验证页白屏**
（老板实测复现，test-7 引入 / test-8 修复）。

## 已完成（有 CI 出包）

- [x] P1 过盾：iOS UA 对齐真实系统版本（`fa2fa96d`+`df801cb2`+`b3300540`，run 37779567105 / ios14-test-6）
- [x] P3 过盾：retry 403 自动 session WebView fallback（`70bbd5c6`，run 37798457544）
- [x] P2 过盾：iOS 出口一致性（`8fa0082f`+`630be5b6`+`99d0bf59`，run 37821106515 / ios14-test-11）
- [x] 修复白屏回归：iOS 禁用滚动挂起（`446846a9`，run 37830118944 / ios14-test-8）

## 环境备忘

- `/tmp/flutter`（Flutter 3.44.0 / Dart 3.12.0）、`/tmp/dartsdk312/dart-sdk/bin/dart`
- 可用：`dart format --output=none --set-exit-if-changed <file>`
- 可用：`/tmp/parsechk/bin/main.dart <file.dart>` → `total_errors=0` 语法层兜底
- **不可用**：`dart analyze`（3.7G 内存 OOM kill）→ 静态分析交给 CI（约 11min）
- runner 慢是常态：一次 run 20~40min，单轮 25min 内基本等不到完成 → 触发+记 run id+下轮核对
