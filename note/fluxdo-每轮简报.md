【FluxDO 攻坚·16:00 轮简报】

结论：本轮推进 D27——给「同源图片分流」补上**逐条豁免**能力。此前 D2 把同源图片整体分流到原生栈，回退手段只有整体开关：一旦某条图片路径实测被 CF 拦/变糊，关掉开关就把已省下的桥负载全吐回去，实验只能二选一。现在可在诊断页把该路径片段加入豁免名单，只让这一条回退走桥，其余照旧分流，名单落盘、跨重启保持。代码已 push（commit a74d4eef）。

证据：
- 前置核对：#78 a4f8ac9c success，Release ios14-test-78（0.2.28.032）已出；#77/#76 均 success，无遗留 failure。
- 改动：settings 服务加名单 notifier/isImageRoutingSkipped/增删清+落盘；platform_adapter 分流分支加豁免判断与 imageRoutingSkipped 计数；诊断页加名单 UI（加/删/清空）与报告字段；版本后缀 038→040。
- 本地 dart format（CI 同款 3.12.0）5 文件 0 changed exit 0 ✅。纯判断+整数计数，零采样，无 pauseTimers/滚动挂起。

⚠️ 阻断（连续第 7 轮）：GitHub Actions 仍被禁用——本轮 dispatch 实测再返 HTTP 422「Actions has been disabled for this repository」。D19–D27 共 9 个 commit 均无对应 run、出不了包，需老板在 GitHub 网页端恢复（Settings→Actions 或 Billing 申诉），我无法用 PAT 自行恢复。

下一步：老板恢复 Actions 后重跑 dispatch 即出 0.2.28.040 包；实机刷帖若见某路径图片 403/变糊，用豁免名单即时验证。SS 接管内置浏览器方向下轮交替推进。

（北京时间 2026-10-15 16:00）
