# FLUXDO_IOS_FIX — iOS 14.8 DoH 接管内部浏览器（WebView）

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-09 起方向切换**：发热/过盾暂缓，唯一主攻 = **DoH 代理接管内部浏览器流量**。

## 🎯 主攻目标

让 iOS 14.8 的**内部浏览器（WKWebView）**流量与 Dart/rhttp/Dio 通道**走同一 DoH 出口**。

## ✅ 本轮（2026-10-09 06:00 CST）— 路径 A/B 根因定论（已核实）

**结论：iOS 14 上 `setProxyOverride` 与 `shouldInterceptRequest` 双双不可用，
原 version guard 是正确的、不可放宽。**

证据（均为本机 pub-cache 源码逐行核实，非推测）：

| 手段 | 证据文件 | 结论 |
|---|---|---|
| `setProxyOverride` | `flutter_inappwebview_ios-1.2.0-beta.3/ios/.../ProxyManager.swift:9` → `@available(iOS 17.0, *)`；`InAppWebViewFlutterPlugin.swift:64-66` → `if #available(iOS 17.0, *) { proxyManager = ProxyManager(...) }` | iOS 14 上 MethodChannel **从未注册** → `MissingPluginException` 被 Dart catch 吞掉 → 静默失败。原理：底层 `WKWebsiteDataStore.proxyConfigurations` 是 iOS 17 API，**iOS 14 不存在**。 |
| `shouldInterceptRequest` | `flutter_inappwebview_platform_interface/lib/src/in_app_webview/platform_webview.dart:1687+` → `@SupportedPlatforms` 仅列 **Android / Windows / Linux**；`flutter_inappwebview_ios/ios/**/*.swift` 内 `shouldInterceptRequest` 出现次数 = **0** | iOS 明确不支持。 |
| `CustomSchemeHandler` | `InAppWebView.swift:705` → `setURLSchemeHandler(CustomSchemeHandler(), forURLScheme: scheme)` | 仅对**自定义 scheme** 生效，无法接管 `https://`。 |

→ **路径 A（放宽 guard）与路径 B（shouldInterceptRequest）在 iOS 14 上均不可行**，
本轮不做无意义改动，转为把结论固化并**诊断现状**，为路径 C 做准备。

### 本轮实际改动

- [x] 根因核实（上表），确认 guard 正确性
- [x] `_applyWebViewProxy()` 增加 iOS 14 分支的**可诊断日志**：原来静默 `return`，
      现在显式打印「iOS <17 无 WKWebsiteDataStore.proxyConfigurations，WebView 无法接管」
      —— 让真机日志能直接证明「裸连」而非让排查者误以为设置成功
- [x] 新增 `docs/ios14-webview-doh-handoff.md`：iOS 14 WebView 出口接管的
      可行性矩阵 + 路径 C 方案设计

## 📐 路径 C 方案（下一轮实施）

**核心事实**：`SystemProxyReader.swift` 已能读**系统代理**，且 `rhttp` 已跟随它。
问题在于**本地 DoH 代理不在系统代理里** → WebView 走系统出口，Dio 走本地 DoH。

**方案 C1（首选）**：iOS 14 无法把 WebView 指向 127.0.0.1。
剩余可行手段 = **让 DoH 出站本身经由系统代理**，使「Dio→本地DoH→系统代理→出口」
与「WebView→系统代理→出口」**出口 IP 一致**。
→ 检查 `GatewayUpstream.resolve` 在 iOS 是否已把系统代理传给 Rust 网关。

**方案 C2**：若 C1 不成立，改 `SystemProxyService` 在 iOS 上不仅读取、
还尝试用 `CFNetworkCopySystemProxySettings` 的**写侧等价物**（App 进程内无可写 API）
—— 需先证实 iOS 无 per-process proxy 写入能力，再判定是否需要 VPN/NEPacketTunnel。

## 📋 待办

- [ ] **核对 CI run `37838762957`（commit `b1a5e341`）step 9/10**：格式✅ 兼容✅ 已确认，只差 IPA 出包
- [ ] 路径 C1：核实 iOS 上 DoH 出站是否经系统代理（出口一致性）
- [ ] 老板实机验证：内部浏览器是否走 DoH 出口（诊断日志已加强）
- [ ] 里程碑 tag（Release ios14-test-8 已发布）

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
