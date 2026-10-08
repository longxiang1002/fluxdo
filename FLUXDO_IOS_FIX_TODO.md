# FLUXDO_IOS_FIX — iOS 14.8 DoH 接管内部浏览器（WebView）

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-09 起方向切换**：发热/过盾暂缓，唯一主攻 = **DoH 代理接管内部浏览器流量**。

## 🎯 主攻目标

让 iOS 14.8 的**内部浏览器（WKWebView）**流量与 Dart/rhttp/Dio 通道**走同一 DoH 出口**。

## ✅ 本轮（2026-10-09 07:00 CST）— 路径 C1 实施：iOS DoH 出站跟随系统代理

上轮定论：iOS 14 上 `setProxyOverride` / `shouldInterceptRequest` 双双不可用
（证据见下节）。路径 C 是**唯一可行方向**，本轮把 C1 落地。

### 修复的根因

`network_settings_service.dart` 的 `_applyProxyState()`：

```dart
// 修复前：iOS 恒传 null → DoH 出站直连
systemProxyUrl: Platform.isWindows
    ? SystemProxyService.instance.effectiveProxyUrl
    : null,
```

| 通道 | iOS 14 出站（修复前） |
|---|---|
| WKWebView（内部浏览器） | 系统代理（CFNetwork 栈） |
| Rust DoH 网关（Dio/rhttp 出口） | **直连** ← 出口不一致的根源 |

WKWebView 默认跟随系统代理，而本地 DoH 网关（`127.0.0.1:<port>`）不在系统代理里。
iOS <17 无法用 `WKWebsiteDataStore.proxyConfigurations` 把 WebView 指向本地网关
（那是 iOS 17 API），所以只能反向统一：**让 DoH 出站也走系统代理**。

### 本轮实际改动

- [x] 新增 `_systemProxyUrlForGateway()`：Windows **与 iOS** 都把
      `SystemProxyService.effectiveProxyUrl` 交给 `GatewayUpstream.resolve`，
      使 DoH 出站与 WKWebView 走**同一出口**。优先级不变（应用代理 > 系统代理 > 直连）；
      VPN/TUN 模式下系统不写代理，helper 返回 null，与原行为等价。
- [x] 新增契约测试 `test/services/network/gateway_system_proxy_source_test.dart`
      （应用代理优先 / 系统代理回退 / null 直连 / 畸形值拒绝 / socks5 识别），
      已加入 CI 测试列表。
- [x] 修复 CI 假失败：Release 步骤 403（`Resource not accessible by integration`，
      即使已授予 `contents:write` 仍**间歇性**出现）把构建全绿的 job 拖成 failure
      （run 37841469025 / 37844039536）。改为 `continue-on-error` +
      `RELEASE_TOKEN` 回退脚本 `.github/scripts/publish_release.sh`。
- [x] 本地校验：`dart format --set-exit-if-changed` = 0 changed；
      parse-only `total_errors=0`。
      ⚠️ `flutter test` 本机跑不动（3.7G 内存 + 无 `dart:ui`）→ 交 CI 执行。

### 待办

- [ ] 老板实机验证：iOS 14.8 开 HTTP(S) 系统代理时，DoH 出口与 WebView 出口 IP 一致
- [ ] 若实机仍不一致：检查 `SystemProxyReader.swift` 读到的代理是否包含 socks5 场景

## 📌 上轮（2026-10-09 06:00 CST）— 路径 A/B 根因定论（已核实）


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

- [x] ~~核对 CI run `37838762957`（commit `b1a5e341`）step 9/10~~ → **全绿**：
      格式✅ 兼容✅ **构建未签名 IPA ✅ 上传已检查的测试包 ✅**（2026-10-09 06:00 轮核对）
- [x] **路径 C1：iOS DoH 出站跟随系统代理** ✅ 本轮完成（见上）
- [ ] 老板实机验证：内部浏览器是否走 DoH 出口（诊断日志已加强）
- [ ] 里程碑 tag（Release ios14-test-8 已发布）

## 本轮 CI（2026-10-09 07:00 CST）

- 核对上轮两 run：`37844039536`(`0c7aad6d`) 与 `37841469025`(`58a2411e`)
  → **均为 failure，但构建/格式/测试步全绿（step 7/8/9/10 ✅），
  仅 step 12「发布 GitHub Release」403 失败** → 本轮已修（continue-on-error + 回退）。
- 本轮 commit → 触发新 run（见 progress log）。

## 📌 上轮 CI（已关闭）

- commit `0c7aad6d` → run `37844039536`：构建全绿，Release 步 403（本轮已修）
- commit `58a2411e` → run `37841469025`：同上

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
