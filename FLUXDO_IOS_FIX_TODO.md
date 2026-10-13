# FluxDO iOS 14 修复 TODO

> 分支 `fix/ios14-network-thermal`。每轮必须动手改代码，写完记 CI 结果。
> **2026-10-13 起主攻**：DoH 模式下 App 仍旧发热。

## 🎯 本轮（2026-10-13 08:00 CST）— 路径 B 落地：上游连接池共享（含子模块无法直推的绕行方案）

### CI 前置核对（强制第 0 步）
- 最近 run：**#37** `c543ea15`(id `38313693826`) = ✅ **success**（2026-10-12 21:56 UTC / 10-13 05:56 CST 触发）。
- #36 `d44e30af` failure、#35 `b66b391f` failure 的根因（format / analyze）**均已修复**，
  #37 即修复后的验证 run，**已通过**。
- GitHub Release tag **`ios14-test-37`** 已生成，含
  `fluxdo-ios14-test-37-c543ea15.ipa` + SHA256SUMS + build-info + validation + inspection。
- → **不存在未修复的 failure，也不需要补建 Release**。本轮可推进新改动。

### 本轮关键发现（阻塞点，先证据）
1. **`core/doh_proxy` 是 git submodule**，指向 `Lingyan000/fluxdo_doh`
   （`.gitmodules:1-3`）。CI 用 `submodules: recursive`（`.github/workflows/ios14-test.yml:24`），
   检出的是**固定 commit** `08d3468f`（`git ls-tree HEAD core/` 印证）。
2. **本 agent 对该子模块仓库没有 push 权限**：
   `GET /repos/Lingyan000/fluxdo_doh` → `permissions.push = false`。
   → 上一轮 06:00 准备的 `note/patches/0001-gateway-share-upstream-h2-pool.patch`
   **无法通过「推子模块」进 CI**，此前只落在本地未生效。
3. 结论：Rust 侧改动只能走**「patch 随主仓库走 + CI 在 checkout 后 `git apply`」**
   的 vendor 方式，才能让 GH Actions 的 macOS runner 真正编译到新代码。

### 本轮改动
- `note/patches/0001-gateway-share-upstream-h2-pool.patch`：正式纳入主仓库（去掉 note/ 的临时性）。
  patch 内容（对比改动前 `src/proxy.rs` 逐条核对无误）：
  - `handle_gateway_connection()`：每连接 `Arc::new(Mutex::new(HashMap::new()))`
    → 进程级 `gateway_shared_pool()`（`OnceLock<GatewayPool>`），跨连接/跨导航复用上游 H2 会话。
  - 客户端侧 `hyper_http1::Builder`（硬编码 HTTP/1.1，单连接单在途请求）
    → `hyper_util::server::conn::auto::Builder`（h1/h2 自适应），共享池才真正可能被二次命中。
  - `DohProxyServer::stop()` 调 `reset_gateway_shared_pool()`，避免跨 start/stop 残留脏 sender。
  - 新增 `gateway_pool_evict()`（`is_ready()` 剔除 + `MAX_POOLED_HOSTS=32` 上限），
    防止共享池变成泄漏源。
  - 移除因改动失效的 `use hyper::server::conn::http1 as hyper_http1`（否则 Rust unused import 报错）。
  - `mitm_serve()` 的单 host 池**保持每连接新建**（作用域本就限定单 host，改全局会串目标）。
- `.github/workflows/ios14-test.yml`：在 checkout 之后新增
  **「应用已 vendor 的 Rust 网关补丁」** 步骤，对 `core/doh_proxy` 逐个 `git apply`
  `note/patches/*.patch`；已应用则跳过（幂等），应用失败则显式报错（不静默继续）。
  位置：紧接 `actions/checkout` 之后、Flutter/Rust toolchain 之前。

### 依赖校验（本地静态核对，无法本地编译 Rust）
- `hyper = { features = ["full"] }`、`hyper-util = { features = ["full"] }`（`core/doh_proxy/Cargo.toml:46-47`）
  → `hyper_util::server::conn::auto::Builder` 可用。
- `use tracing::{debug, error, info, warn}`（`src/proxy.rs:31`）→ patch 新增的 `debug!` 调用可解析。
- `hyper_http1` 在改动前**仅 2 处**（import + 单次 use），patch 恰好成对删除，无残留引用。

### 硬性禁令遵守
- **不碰 WebView**、不引 `pauseTimers/resumeTimers`、不引任何滚动挂起逻辑。
- 改动全在 Rust 网关连接管理，**不阻塞任何 JS 执行**，与「验证页白屏」路线无关。
- **不改 CONNECT 语义**：CF 验证域名仍强制走隧道（`proxy.rs` 未动该分支）。

### 待验
- [ ] 本地 `dart format` CI 同款预检（本轮无 .dart 改动，仍需确认 workflow 语法）
- [ ] push 主仓库 + 触发 CI run #38
- [ ] 核对 run #38：Rust 编译通过（patch 应用成功）+ 出包 + Release `ios14-test-38`
- [ ] 版本 `APP_VERSION_SUFFIX` → `004`

### 未提交的工作区改动（上一轮 06:00 遗留，本轮不动）
- `lib/services/network/system_proxy_service.dart`：`SystemProxyService` 自适应退避
  （30s 快节拍 → 无变化翻倍 → 封顶 5min；有变化立刻复位）。**本轮不提交**
  （避免一轮改两件事），留作下一轮的独立 Dart 增量。

### 前序里程碑
- run **37**(`c543ea15`) ✅ success，Release `ios14-test-37`：
  IPA `fluxdo-ios14-test-37-c543ea15.ipa`
- run **34**(`66264d5d`) ✅ success，Release `ios14-test-34`（0.2.28.002）

---

## ✅ 已完成（2026-10-13 06:00 CST）— 路径B：网关上游连接复用（DoH 模式发热）

### 证据（先证据后改动）
- `proxy.rs:431`（改前）`handle_gateway_connection()` 里每来一条客户端连接就
  `Arc::new(Mutex::new(HashMap::new()))` → 池生命周期 = 单条客户端 TCP 连接。
- `proxy.rs:456`（改前）客户端侧硬编码 `hyper_http1::Builder`（HTTP/1.1 server），
  **单连接同时只有一个在途请求** → 池里跨 host 的 H2 sender 在单连接内基本不可能被二次命中。
- `proxy.rs:576`（改前）上游协商到 HTTP/1.1 时**完全不入池** → **每请求新建 TLS**。
- 对照：`dns.rs:1250-1255` 的 reqwest DoH 客户端**已正确配置**
  `pool_idle_timeout(90s)` / `pool_max_idle_per_host(8)` / `http2_keep_alive_while_idle(true)`。
- **发热链路**：每次导航/资源请求 → 上游新建 TCP + TLS（含 ECH 与 DoH 解析）+ H2 handshake。
  握手是 ECDHE/RSA 密集运算 + 多次往返，在 iOS 上直接表现为 CPU 峰值与持续耗电。
- ⚠️ 06:00 轮的改动**实际未进入 CI**（子模块无 push 权限），本轮 08:00 用 vendor 方案补上。

---

## ✅ 已完成（2026-10-13 05:30 CST）— 路径 C：干掉常驻悬浮性能面板（每秒重建）

- `lib/widgets/common/perf_overlay.dart`：`showPersistentPill = false`（const）+ `show()` 首行早退。
- `lib/utils/frame_jank_monitor.dart`：`restoreIfEnabled()` 加 `AppLogger.developerMode` 门禁。
- `lib/services/app_logger.dart`：新增 `developerMode` getter。
- 证据：`main.dart:289` release 下 `pref_perf_diagnostics` 为真即 `FrameJankMonitor.start()`
  → `frame_jank_monitor.dart:247` 无条件 `PerfOverlay.restoreIfEnabled()` → 面板插入根 Overlay
  后**永不自行移除**，胶囊态每 1s 重建刷新掉帧率。用户开过一次诊断就永久背着它。
- commit `b66b391f`（随后 `d44e30af` 修 format、`c543ea15` 修 analyze）。

## ✅ 已完成（2026-10-13 05:00 CST）— 路径 A：干掉 SystemProxyService 的僵尸 10s 常驻轮询
见 progress log。
