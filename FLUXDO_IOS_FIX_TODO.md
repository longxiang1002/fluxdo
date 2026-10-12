# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-13 起主攻**：DoH 模式下 App 仍旧发热。

## 🎯 本轮（2026-10-13 05:00 CST）— 路径 A：干掉 SystemProxyService 的僵尸 10s 常驻轮询

### 证据（先证据后改动）

`lib/services/network/system_proxy_service.dart:238`：
```dart
static const _refreshInterval = Duration(seconds: 10);
_refreshTimer = Timer.periodic(_refreshInterval, (_) => refresh());
```
- `main.dart:392`：iOS/Windows **无条件** `SystemProxyService.instance.start()`。
- 每次 tick → `refresh()` → iOS 走 `_refreshIos()` →
  `_iosChannel.invokeMethod('effectiveProxyUrl')`（第 257-263 行）→ 原生
  `AppDelegate.swift:39` → `SystemProxyReader.effectiveProxyUrl`
  → **`CFNetworkCopySystemProxySettings()`（阻塞式 CFNetwork 系统调用）**，
  每 10 秒一次，**永久**，且在平台通道（主线程）上。
- 该节拍**没有任何**前台/后台门禁、也没有「值没变就不必再读」的退避：
  就算系统代理设置一整小时没动，仍照读不误 → 纯粹的常驻唤醒（0.1Hz IPC +
  CFNetwork 系统调用），是 DoH 模式下后台/前台都持续的发热/耗电源之一。

补充：`_updateEffective()` 已经做了「值未变则 early-return」，所以**变化检测本身
是廉价的**；真正贵的是那次 CFNetwork 系统调用 + 跨通道 IPC。

### 本轮改动（1 commit）

- `lib/services/network/system_proxy_service.dart`：
  新增**前台门禁 + 懒刷新**：
  - 新增 `pause()` / `resume()`：后台时取消周期定时器，前台恢复时**先立即刷新一次**
    再重挂定时器 → 后台零唤醒；恢复瞬间立即补齐状态，不牺牲正确性。
  - `start()` 保持不变（首次仍会与其它服务并行初始化时读一次真实值）。
  - 轮询周期从 10s 放宽（见改动常量）：iOS 系统代理变化本就有
    `cf_challenge_interceptor` 的显式 `refresh()` 兜底 + 后台/前台风控。
- `lib/main.dart`：在 `didChangeAppLifecycleState` 里接上
  `SystemProxyService.instance.pause()/resume()`（仅 iOS/Windows）。

### 硬性禁令遵守
- **不碰 WebView**：本改动只动系统代理读取节拍，与 WebView JS 执行无关，
  不引 `pauseTimers/resumeTimers`，不引任何滚动挂起逻辑 → 不会重演白屏回归。

### 待验
- [ ] 本地 `dart format` + `dart analyze`
- [ ] push + 触发 CI run（ios14-test.yml）
- [ ] 记录 CI 结果与 Next

---

## 📌 历史里程碑（滚动保留，详见 note/fluxdo-攻坚-progress-log.md）
- `3194ad67` → run 33 ✅ success（app 版本 0.2.28.001，出包链路已通）
- `14022f07` 本地 Rust 网关代理 Shadowsocks（path 前置）
- `d8cd0517` iOS<17 guard 结案：无进程内解
