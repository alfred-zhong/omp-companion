# 0004 — 无本地缓存：定时刷新直接执行

本地缓存层（余额 TTL 60s、日用量 TTL 30s）整体移除。每次定时刷新都直接调用 Provider API 查询余额、重新扫描 omp 会话转录聚合用量，不读写任何缓存文件。

## Context

app 本身就是常驻进程，以固定 interval（默认 60s，可调 20-600s）主动驱动刷新——刷新的节奏由 app 自己控制，不存在"两个调用方共享同一份数据"的场景。缓存引入的三个问题都不成立：进程间并发写冲突（无第二个写者）、快速冷启动（app 常驻，无需恢复）、API 限流保护（默认 60s 间隔远低于 Provider 限流阈值；日用量侧扫描本地 JSONL 冷启动仅约 20ms）。

保留缓存还带来维护负担：两套 TTL、跨零点失效、原子写、mtime 剪枝，且需要与上游 TTL 保持同步。

## Decision

- 删除 `BalanceCache`、`DailyUsageCache`、`JSONCache` 及其调用点。
- `RefreshController.refreshBalance()` 每次直接 fetch Provider；`refreshDaily()` 每次直接 scan + aggregate。
- 余额查询按 60s 间隔真实请求 Provider API（DeepSeek `/user/balance`、MiniMax `/token_plan/remains` 等，均无严格限流门槛）。
- 系统 `~/Library/Caches/<bundle-id>/` 仅剩 URLSession 自动写入的 `Cache.db`，app 自身不再写缓存文件。

## Consequences

- 上游 omp-model-usage / omp-daily-usage 的缓存 TTL 变更不再影响本 app，逻辑完全自持。
- 余额查询每次都真实发生，网络不可达时菜单栏走"上一份快照 + 错误标记"降级（`isStale` 逻辑保留在 `BalanceSnapshot`）。
- 超短刷新间隔（如 20s）会增加 Provider API 调用量，但仍在合理范围。
