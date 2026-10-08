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
