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

### C1（首选）核实 DoH 出站是否跟随系统代理 —— ✅ 已修复（2026-10-09 07:00 CST）

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

**结论（已核实并修复）**：iOS 上 DoH 出站**原本直连**——`_applyProxyState()`
里 `systemProxyUrl` 只在 `Platform.isWindows` 时传入，iOS 恒传 `null`，
于是 `GatewayUpstream.resolve()` 直接走「直连」分支。这就造成：

| 通道 | iOS 14 出站 |
|---|---|
| WKWebView（内部浏览器） | 系统代理（CFNetwork 栈） |
| Rust DoH 网关（Dio/rhttp 出口） | **直连** ← 不一致的根源 |

**已实施修复**（commit 见下）：新增 `_systemProxyUrlForGateway()`，
让 **Windows 与 iOS** 都把 `SystemProxyService.instance.effectiveProxyUrl`
交给网关，使 DoH 出站与 WKWebView 走**同一出口**。

```dart
final upstream = GatewayUpstream.resolve(
  applicationProxy: _proxyService.current,
  systemProxyUrl: _systemProxyUrlForGateway(),
);
```

优先顺序不变：应用内代理 > 系统代理 > 直连。VPN/TUN 模式下系统不写代理，
两者都经 TUN，天然一致（helper 返回 null，与原先等价）。
`test/services/network/gateway_system_proxy_source_test.dart` 锁死该优先级契约。

**待真机验证**：iOS 14.8 实机 HTTP(S) 代理下，DoH 出站与 WebView 出口 IP 应一致。

### C2（备选）iOS 进程内代理写入

iOS 无公开的 per-process 代理写入 API（`CFNetworkCopySystemProxySettings` 是**只读**）。
App 内改全局系统代理只能靠 VPN/`NEPacketTunnelProvider`（需额外 entitlement，
TrollStore 环境下可行性待评估）。**结论：不作为首选**。

### C2 细化（2026-10-09 09:00 CST 调研结论）

| 手段 | 能否让 WebView 走本地 DoH | 证据 / 阻塞点 |
|---|---|---|
| WebView 指向 127.0.0.1 | ❌ | 需 `WKWebsiteDataStore.proxyConfigurations`，iOS 17 API |
| `setProxyOverride` | ❌ | 同上层 API，iOS 14 原生侧未注册 MethodChannel |
| `shouldInterceptRequest` | ❌ | iOS 无实现（@SupportedPlatforms 仅 Android/Win/Linux） |
| `setURLSchemeHandler` | ❌ | 只接管自定义 scheme，拦不到 `https://` |
| `WKContentRuleList` | ❌ | 只能**阻断**匹配 URL，不能改写成经本地代理 |
| App 写全局系统代理 | ❌ | 无公开 API；`CFNetworkCopySystemProxySettings` 只读 |
| `NEPacketTunnelProvider` | ✅ 理论可行 | 见下 |

**`NEPacketTunnelProvider` 在 TrollStore 下的具体阻塞（已核实本仓库）**：

1. **entitlement 缺失**：`ios/Runner/Runner.entitlements` 当前只有
   `com.apple.developer.web-browser`（TrollStore 注入的，用于默认浏览器能力）；
   **没有** `com.apple.developer.networking.networkextension`。
2. **profile 缺失**：TrollStore 是**永久签名注入**，不经过 Apple provisioning；
   `NEProfileIngestionPayload` / `NEPacketTunnelProvider` 需要有效 provisioning
   profile 里带 networkextension entitlement，且由系统看门进程
   `nesessionmanager` 校验签名。TrollStore 签名的 app **不会**被授予该 entitlement
   → `NETunnelProviderManager.loadAllFromPreferences` 报
   `NEVPNErrorConfigurationInvalid` / `permission denied`。
3. **需要额外 target**：`NEPacketTunnelProvider` 必须独立 Extension target +
   `NSExtensionPointIdentifier = com.apple.networkextension.packet-tunnel`，
   当前工程无该 target。
4. **系统级副作用**：一旦成立，TUN 会接管**全机**流量（含其它 App），远超
   「让本 App WebView 走 DoH」的范围，需老板明确授权。

→ **结论：C2/NEPacketTunnel 在 TrollStore 环境下不成立**（entitlement 拿不到）。
**剩余可行方向只有 C1**（DoH 出站跟随系统代理，让两通道出口 IP 一致），
其成立前提由 `SystemProxyProbe.effectiveExitIsSystemProxy` 真机采样判定。

### 若无可用系统代理时的兜底方向（待评估，非本轮实施）

前提：设备**没有**可用系统代理（PAC/直连），此时 C1 无法统一出口。
剩余思路（均需老板决策，因为它们改变产品行为而非纯内部修复）：

- **D1 只提示不接管**：WebView 页面顶栏明确提示「内部浏览器未走 DoH」，
  不假装覆盖（**当前默认行为，已实现**）。
- **D2 WebView 侧降级**：内部浏览器在 iOS <17 自动用 Dart 经 DoH 代理取文档、
  以 `loadData` / 本地服务方式渲染。成本高且会破坏 SPA 行为，**不推荐**。
- **D3 换用可被接管的 WebView 内核**：改用自带代理配置的第三方内核，
  工程量大，超出本轮范围。

## 四、恢复 guard 的边界（写死在代码注释里）

`_requiresUnsupportedProxySkips()`：
- Android → `false`（原生 `WebView.setProxyOverride` 可用）
- iOS / macOS → 视系统版本
- 其余 → `true`

## 五、验收方法

真机看日志：
- 应出现 `[DOH] iOS < 17 无 WKWebsiteDataStore.proxyConfigurations，WebView 无法接管 → 内部浏览器流量裸连（不走本地 DoH 代理）`
- 出现 = 确认裸连（当前状态）；不出现且 WebView 流量走 DoH = 目标达成
