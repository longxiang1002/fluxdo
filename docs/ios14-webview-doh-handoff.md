# iOS 14 内部浏览器 DoH 出口接管 — 可行性矩阵与方案

> 2026-10-09 06:00 CST · 分支 `fix/ios14-network-thermal`
> 目标：让 iOS 14.8 的**内部浏览器（WKWebView）**流量与 Dart/rhttp/Dio 走**同一 DoH 出口**。

## 一、问题陈述

`lib/services/network/doh/network_settings_service.dart` 的 `_applyWebViewProxy()`
在 iOS < 17 上**直接 return** → `ProxyController.setProxyOverride(...)` 从未被调用
→ 内部浏览器（`lib/pages/my_browser_page.dart` / `webview_page.dart`）**裸连**，
不走本地 DoH 代理；而 Dart/rhttp/Dio 通道走 `127.0.0.1:<port>`。**两个出口不一致**。

## 二、三条候选路径的结论（源码级核实，非推测）

| 路径 | 手段 | 核实证据 | 结论 |
|---|---|---|---|
| A | 放宽 `setProxyOverride` 的 version guard | `flutter_inappwebview_ios-1.2.0-beta.3/ios/.../ProxyManager.swift:9` → `@available(iOS 17.0, *)`<br>`.../InAppWebViewFlutterPlugin.swift:64-66` → `if #available(iOS 17.0, *) { proxyManager = ProxyManager(plugin: self) }` | ❌ **不可行**。iOS 14 上 `com.pichillilorenzo/flutter_inappwebview_proxycontroller` MethodChannel **从未注册**，`invokeMethod` 抛 `MissingPluginException`（被 `catch` 吞掉 → 静默失败）。底层 `WKWebsiteDataStore.proxyConfigurations` 本身是 **iOS 17 新 API**，iOS 14 无此符号。guard 是**正确**的。 |
| B | `useShouldInterceptRequest` 拦截 WebView 全部请求 | `flutter_inappwebview_platform_interface-*/lib/src/in_app_webview/platform_webview.dart:1687+` → `@SupportedPlatforms(platforms: [AndroidPlatform, WindowsPlatform, LinuxPlatform, ...])`<br>`flutter_inappwebview_ios/ios/**/*.swift` 中 `shouldInterceptRequest` 出现 **0 次** | ❌ **不可行**。iOS 明确不在支持列表，原生侧无实现。 |
| B' | `CustomSchemeHandler` 接管 | `.../InAppWebView/InAppWebView.swift:705` → `configuration.setURLSchemeHandler(CustomSchemeHandler(), forURLScheme: scheme)` | ❌ 仅对**自定义 scheme** 生效，无法接管 `https://`。 |
| C | 统一出口：让 WebView 与 Dart 走同一出站 | `ios/Runner/SystemProxyReader.swift`（读系统代理，CFNetwork 栈）＋ `lib/services/network/system_proxy_service.dart` | ⚠️ **唯一可行方向**，见下。 |

**副产品结论**：原 version guard **不应放宽**——放开了也只是让日志变成
`MissingPluginException`，反而掩盖问题。本轮把它从「静默 return」改为
**显式诊断日志**，让真机日志能直接证明「iOS 14 内部浏览器裸连」。

## 三、路径 C：统一出口

关键事实：**WKWebView 默认跟随系统代理（CFNetwork 栈）**，而本地 DoH 代理
（`127.0.0.1:<port>`）**不在系统代理里**。所以：

- **iOS 17+**：`WKWebsiteDataStore.proxyConfigurations` 把 WebView 直接指向
  `127.0.0.1:<port>` → 两个通道都走本地 DoH ✅
- **iOS 14**：无此 API → 只能让**两个通道经由同一上游**达到出口 IP 一致。

### C1（首选）核实 DoH 出站是否跟随系统代理

`GatewayUpstream.resolve()` 的优先级为「应用内代理 > 系统代理 > 直连」，
且 `_applyProxyState()` 里 **只在 `Platform.isWindows` 时**把
`SystemProxyService.instance.effectiveProxyUrl` 传进去：

```dart
final upstream = GatewayUpstream.resolve(
  applicationProxy: _proxyService.current,
  systemProxyUrl: Platform.isWindows
      ? SystemProxyService.instance.effectiveProxyUrl
      : null,          // ← iOS 传 null
);
```

→ **iOS 上系统代理没有传给 Rust 网关**。虽然 `SystemProxyReader` 已能读，
虽然 `rhttp` 已跟随系统代理，但**本地 DoH 代理的出站**未必跟随。

**下一轮动作**：确认 iOS 上 DoH 出站的真实路径。
- 若 DoH 出站为直连 → WebView 经系统代理、Dio 经 DoH 直连，**出口仍不一致**
  → 需要把 `effectiveProxyUrl` 在 iOS 也传给 `GatewayUpstream.resolve`
  （使 DoH 出站也经系统代理），从而两个通道出口一致。
- 注意：此处改动会影响 iOS 的**全部** DoH 流量，属行为变更，需要真机验证。

### C2（备选）iOS 进程内代理写入

iOS 无公开的 per-process 代理写入 API（`CFNetworkCopySystemProxySettings` 是**只读**）。
App 内改全局系统代理只能靠 VPN/`NEPacketTunnelProvider`（需额外 entitlement，
TrollStore 环境下可行性待评估）。**结论：不作为首选**。

## 四、恢复 guard 的边界（写死在代码注释里）

`_requiresUnsupportedProxySkips()`：
- Android → `false`（原生 `WebView.setProxyOverride` 可用）
- iOS / macOS → 视系统版本
- 其余 → `true`

## 五、验收方法

真机看日志：
- 应出现 `[DOH] iOS < 17 无 WKWebsiteDataStore.proxyConfigurations，WebView 无法接管 → 内部浏览器流量裸连（不走本地 DoH 代理）`
- 出现 = 确认裸连（当前状态）；不出现且 WebView 流量走 DoH = 目标达成
