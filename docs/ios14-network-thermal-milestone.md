# iOS 14.8 发烫 + 频繁过盾 — 攻坚里程碑（分支 `fix/ios14-network-thermal`）

> 目的：让 FluxDO 在 iOS 14.8 老设备上可正常使用（不烫、少过盾）。
> 构建方式：GitHub Actions macOS runner 出**无签名 IPA** → TrollStore 巨魔安装。
> 工作流：`.github/workflows/ios14-test.yml`（workflow id `374182066`）。

## 一、问题与目标

| 症状 | 目标 |
| --- | --- |
| 手机发烫（iOS 14.8 实机） | 降低常驻 WebView 的 JS 空转与重建频率 |
| 频繁过盾（Cloudflare challenge） | 让 cf_clearance 在 Dio 侧真正生效，打破「验证→仍 403→再验证」循环 |
| 老设备可用 | 不引入 iOS 15+ API；不破坏既有登录/Cookie |

## 二、根因分析（均为源码/实测证据，非猜测）

### 2.1 发热：常驻 Turnstile 续期 WebView 裸跑

- 证据：`lib/services/cf_clearance_refresh_service.dart` 上游注释自述
  「**Turnstile 是活网页，常驻 JS 把平台主线程烧到 60%+ 单核（生产 CPU 采样）**」。
- `start()` 除 Windows 外一律拉起常驻 headless WebView（iOS/Android 都会跑）。
- 触发链：撞盾 → 手动验证 → `Future.delayed(1.5s)` → `CfClearanceRefreshService().start()`，
  即**只要撞过一次盾，常驻 Turnstile 页就一直在后台**。

### 2.2 过盾：Dio 出口与 WebView 出口不一致 → 循环验证

- 证据：`lib/services/network/interceptors/cf_challenge_interceptor.dart` 注释自述
  「验证刚『成功』、cookie 也带上了，重试却仍被 CF 拦——铸出的 clearance 对 Dio 无效。
  这是**确定性环境问题**（典型：系统代理只对 WebView 生效，Dio 直连，两侧出口 IP 不一致）」。
- 结果：每次 IP 不一致的过盾都必然循环「撞盾 → 验证 → 仍撞 → 冷却 → 再撞」，
  而每次验证又拉起新 WebView，**同时加重发热**。

### 2.3 指纹不一致：iOS UA 假报系统版本

- `lib/constants.dart` 的降级/默认 UA 硬编码 `iPhone OS 18_0`，
  而 WKWebView 真实 UA 为 `iPhone OS 14_8` → 同一客户端两套指纹，可被 CF 判定可疑。

### 2.4 ⚠️ 关键回归（已定位并回滚）：iOS 滚动挂起导致**验证页白屏**

`e4cb9c4b` 曾把 Android 的「滚动时挂起 Turnstile」扩展到 iOS，用的是
`InAppWebViewController.pauseTimers()`。本地插件源码 `flutter_inappwebview_ios`
的 `InAppWebView.swift:3207-3213` 证实其实现为：

```swift
public func pauseTimers() {
    isPausedTimers = true
    self.evaluateJavaScript("alert();", completionHandler: nil)   // ← 阻塞 JS 的实现方式
}
```

未决的 `alert()` 会**阻塞整个 WKWebView（WebContent 进程）**，而同进程内的
用户手动验证弹窗会被一并冻结 → **验证页白屏**。该交互危害远大于省电收益。

**因此本项目有一条硬性禁令：**

> 🚫 绝不在 iOS 使用 `pauseTimers`/`resumeTimers`，
> 也绝不把任何「滚动挂起 / 暂停 WebView」逻辑引入 iOS 路径。

iOS 的滚动挂起已永久禁用（仅 Android 保留 `pause()`/`resume()`）。
iOS 若需降发热，只能从 **Turnstile 实例存活时长 / tick 频率 / 轮询间隔** 等
**不触碰 WebView JS 执行**的手段入手，且改动说明里必须论证「不会阻塞 JS」。

## 三、已交付改动

| 优先级 | 改动 | Commit | CI run | 产物 |
| --- | --- | --- | --- | --- |
| P1 过盾 | iOS UA 对齐真实系统版本（14.8），Dio UA 与 WKWebView 指纹一致 | `fa2fa96d` + `df801cb2` + `b3300540` | 37779567105 ✅ | ios14-test-6 |
| P1 发热（**已回滚**） | iOS 滚动挂起移植 `pauseTimers()` | `e4cb9c4b` | 37789836436 ✅ | ios14-test-7（**白屏回归**） |
| P3 过盾 | retry 仍 403/429 时，数据请求自动走 session WebView fallback | `70bbd5c6` | 37798457544 ✅ | ios14-test-9 |
| P2 过盾 | iOS 出口一致性：`CFNetworkCopySystemProxySettings` 读系统代理 → rhttp 同出口 | `8fa0082f` + `630be5b6`（格式）+ `99d0bf59`（编译修复） | 37821106515 ✅ | ios14-test-11 |
| **修复回归** | iOS 禁用滚动挂起 + iOS 代理读取加固 + Dart 侧代理 URL 校验 | `446846a9` | 37830118944 ✅ | **ios14-test-8** |

### 3.1 P2 实施细节（iOS 出口一致性）

- 新增 `ios/Runner/SystemProxyReader.swift`：`CFNetworkCopySystemProxySettings()` 读取
  固定 HTTP/HTTPS 代理；优先 HTTPS，未启用 / 仅 PAC 时返回 `nil` → 直连
  （与 Windows 注册表读取同策略，PAC 不在 Dart/native 侧求值）。
- `AppDelegate.swift` 注册 `com.fluxdo/system_proxy` MethodChannel。
- `SystemProxyService` 在 iOS 上纳入 10s 刷新；`rhttp_adapter` 未显式配置上游时跟随系统代理。
- 两个易错点（已修）：
  1. `kCFNetworkProxiesHTTPSEnable/HTTPSProxy/HTTPSPort` 是 **macOS-only 常量**，
     iOS 引用会编译报 `unavailable` → 改用等值字符串字面量 `"HTTPSEnable"` 等。
  2. port 用 `as? Int` 解析会失败（CFNetwork 返回 `NSNumber`）→ 改 `NSNumber.intValue`
     并校验 `0 < port <= 65535`、拒绝 `0.0.0.0`。
- Dart 侧 `sanitizeProxyUrl` 在 `effectiveProxyUrl` 返回前校验格式，
  避免一个坏代理把全站请求拖垮。

### 3.2 白屏回归的修复

1. `cf_clearance_refresh_service.dart`：`_scrollPauseTicker` **仅 Android** 启动；
   `_updateScrollPause()` / `_releaseScrollPauseIfNeeded()` 在 iOS 直接 no-op。
2. `SystemProxyReader.swift`：port 用 `NSNumber` 解析 + host/port 合法性校验。
3. `system_proxy_service.dart`：新增 `sanitizeProxyUrl` 兜底。

## 四、交付物（GitHub Releases）

- **最新：`ios14-test-8`** — commit `446846a9`，CI run `37830118944` 全绿
  - IPA 54,848,995 bytes
  - SHA256 `8836af6a4ecbf9a7501644287b59ecb7e620588699bc7feece8aaae634e78ba8`
  - https://github.com/longxiang1002/fluxdo/releases/tag/ios14-test-8
- 历史：`ios14-test-3`（首轮）/ `ios14-test-6`（UA 对齐）/ `ios14-test-7`（**含白屏回归，勿用**）

## 五、验收方法

见 `docs/ios14-validation.md`（随 artifact 一起分发）。要点：

- 安装：TrollStore 直接覆盖安装，**不先卸载**；先备份重要草稿。
- 发热对照：不充电、固定亮度/网络/内容/时长；开「网络设置 → 调试 → 刷帖负载诊断」，
  分组测纯文本 / 连续未读楼层 / 多视频帖（先不播放），每组 5–10 分钟，记电量与 CF 弹出次数。
- DoH 验收：加 `https://linuxdo.ddd.oaifree.com/query-dns` → 开 DoH →
  「测试当前 DoH」→ 开「采集实际请求路由」→ 刷帖后看
  `gateway + io-ios14 + gatewayResolverMatched=true`。
- ⚠️ `direct-or-rhttp` ≠ 已证明走 DoH；`webview` ≠ 走应用 DoH。
  iOS 17 以下现有接口无法把 WebView 接入应用代理，故登录/过盾可能走系统网络。

## 六、待办与边界

- [ ] 老板实机验证 `ios14-test-8`：手动验证弹窗是否正常、发热、CF 弹窗次数
- [ ] iOS 侧降发热（仅限不动 WebView JS 执行的手段）尚未动工
- [ ] 不改账户数据结构 / Bundle ID / 最低系统目标；不清 Cookie；不强推 `main`
- [ ] 自动化与静态检查只能证明对应代码与声明；真机安装、登录、CPU/热状态、
      DoH 实际采用情况与 CF 频率**必须由用户在设备上验证**
