# FLUXDO_IOS_FIX — iOS 14.8 发烫 + 频繁过盾攻坚

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。

## 已完成（有 CI 出包）

- [x] P1 发热：iOS 滚动挂起移植（`e4cb9c4b`，run 37789836436 / ios14-test-7）
- [x] P1 过盾：iOS UA 对齐真实系统版本（`fa2fa96d`…，run 37779567105）
- [x] P3 过盾：retry 403 自动 session WebView fallback（`70bbd5c6`，run 37798457544）
- [x] P2 过盾：iOS 出口一致性（`8fa0082f` + 编译修复 `99d0bf59`，run 37821106515 / ios14-test-11）

## 本轮（2026-10-09 03:00 CST）— P1 发热：iOS 滚动挂起的中断路径不恢复

**根因（上游源码实证，非猜测）**

`pauseTimers()` 在 iOS 上的实现是「执行 `alert()` 阻塞 JS 定时器」：

- `flutter_inappwebview_ios .../InAppWebView.swift:3207-3213`
  `pauseTimers()` → `isPausedTimers = true` + `evaluateJavaScript("alert();")`
- `:3215-3225` `resumeTimers()` → 放行 `isPausedTimersCompletionHandler`，复位标志
- `:2382-2385` 只有 `runJavaScriptAlertPanelWithMessage` 会暂存该 handler

**缺陷**：`_updateScrollPause()` 只在 `wantPause == _webViewPausedForScroll` 时跳过、
且 `resumeTimers` 仅在滚动转为不繁忙时调用。一旦挂起期间 WebView 被销毁/重载
（`_disposeWebView`、`_reloadTurnstile`、切前后台），`_webViewPausedForScroll`
在旧实例上为 true 但新实例并未挂起，恢复分支再也进不来；反之若旧实例被销毁时
标志已复位而原生 instance 仍处于 alert 阻塞，CF 续期页的 JS 定时器会永久停摆
→ cf_clearance 不再续期 → 8 分钟 stale 窗口后反复重载 Turnstile → **过盾增多 +
WebView 反复重建加剧发热**。

**改动**：把「进入挂起态」的记账与实例绑定，销毁/重建路径显式复位并兜底 resume；
不改变 Android 行为，不硬关功能。

- [ ] 改 `lib/services/cf_clearance_refresh_service.dart`：挂起态随实例复位 + dispose 前兜底 resume
- [ ] push + 触发 run 374182066，轮询 CI
- [ ] 回填本文件与 progress log 的 commit / run / artifact

## 待办

- [ ] 老板实机验证发热/过盾对照（TrollStore 装 `fluxdo-ios14-test-*`）
- [ ] 里程碑 tag
