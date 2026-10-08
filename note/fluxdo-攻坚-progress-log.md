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
