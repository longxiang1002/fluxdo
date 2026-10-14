# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-13 起主攻**：DoH 模式下 App 仍旧发热（症状=**活跃刷帖时**发热，非空闲）。


## 🎯 本轮（2026-10-15 04:00 CST）— D19：同源图片分流做成诊断页运行时 A/B 开关

### CI 前置核对（强制第 0 步）
- **#78** `a4f8ac9c`（D18 走桥脚本瘦身）= ✅ success，Release **`ios14-test-78`** 已出
  （版本 0.2.28.032）。
- **#77** `affbc514`（D17）= ✅ success；**#75/76** 均已处理。
- 结论：无未修复 failure，Release/IPA 齐全，可推进新工作。

### 1) 本轮判断（为什么做 D19）
- 上轮已把 D2「同源图片分流到原生 Dio」的静态开关 `imageNativeRoutingEnabled`
  提升为 `WebViewAdapterSettingsService` 里的运行时 `ValueNotifier`，并已接线
  `platform_adapter.dart` 走桥判据（`requestCanUseWebViewAdapter` 见
  `imageRoutedNative++` 分流），但**诊断页只有监听、没有 A/B 切换入口**（半成品）。
- 图片是活跃刷帖时**体量最大的走桥负载**（JS fetch + 分块 base64 跨桥回传），
  分流到原生 Dio 是降发热主攻方向的直接命中点之一。
- 本轮补齐诊断页 `SwitchListTile`，让老板在实机上**即切即开/关**做 A/B：
  - 开 = 同源图片走原生直连（省桥负载）；
  - 若刷帖出现图片变糊 / CF 403，一键关掉即回走桥旧行为（遵守 D3 回退铁律，不硬推）。

### 2) 改动（小而稳，零行为变化基线，不碰任何 WebView 挂起 API）
- `webview_adapter_settings_service.dart`：新增 `imageNativeRoutingNotifier`
  （默认 true）、`imageNativeRoutingEnabled` getter、`setImageNativeRouting()`。
- `platform_adapter.dart`：`requestCanUseWebViewAdapter` 走桥判据改用
  service 动态开关替换原静态 bool（删掉旧的顶层 `bool imageNativeRoutingEnabled`）。
- `ios14_network_diagnostics_page.dart`：在「同源图片已分流原生直连」下方加
  `SwitchListTile`，绑定该 notifier，initState/dispose 里监听切换驱动刷新。
- `.github/workflows/ios14-test.yml`：`APP_VERSION_SUFFIX` 032 → **033**。
- 未触碰任何 pauseTimers / resumeTimers / 滚动挂起逻辑；默认行为与旧版一致
  （true=分流开启），仅新增运行时开关入口。

### 3) 本地验证（CI 同款 Dart 3.12.0）
- `dart format --set-exit-if-changed`：3 个改动 dart 文件 **0 changed，exit 0** ✅
- `dart analyze` 因 2 核 OOM 崩溃（历史已知环境问题，非代码问题）。
- 引用一致性：`imageNativeRoutingEnabled` / `setImageNativeRouting` /
  `imageNativeRoutingNotifier` 三处（page UI + page 监听 + platform_adapter）
  与 service 定义全部匹配，import 齐全。

### 4) 提交与 CI
- commit（见 progress-log），push 后触发 workflow。
- `APP_VERSION_SUFFIX` 032 → **033**。

### 下一步
1. 核对本轮 run → 确认 Release + IPA 直链。
2. 实机刷帖做 D2 A/B：先关分流（走桥）→ 刷帖发热；再开分流（原生）→ 对比发热
   与图片是否正常加载、有无 CF 403/变糊。预期开分流时桥负载显著下降。
3. 若 A/B 证实图片分流省热且不过盾 → 固化该路径为默认策略；若 403 → 回退并在
   日志写明数据（D3 铁律）。
4. SS 接管内置浏览器方向与主线轮次交替。
