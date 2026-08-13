# 0003 — 完全 Swift 重写两份逻辑，不 shell-out 上游 CLI

omp-companion 把"余额查询"和"日用量聚合"在 Swift 中各重写一份；不调 `omp-model-usage` / `omp-daily-usage` 的 CLI 子进程。

## Context

上游两个项目都是 CLI（短命进程，每次外部刷新调用一次）。把它们当黑盒用 fork 调，逻辑零维护，但要承担：双 bun 运行时依赖、启动延迟、参数协议与上游强耦合、跨进程 stdout 解析与 ANSI 处理。

## Decision

- 余额侧：实现 Swift `BalanceProvider` 协议 + Provider 注册表（deepseek、minimax token plan、minimax coding plan 中国版），各自实现 `func fetch() async throws -> BalanceResult`。
- 日用量侧：实现 Swift `DailyUsageScanner`，递归扫 `~/.omp/agent/sessions/`，按上游既定的 JSONL 行 schema 解析 → 12 滑动小时桶聚合 → 12 根 8 级柱图字符渲染。
- 缓存策略、原子写、TTL、跨零点失效、JSONL 行预过滤、复合去重键（`relPath:eventId`）等实现细节与上游 1:1 对齐——目的是让"上游修复 bug，本应用同步修"成为可机械化的事。
- 测试：XCTest 覆盖纯函数（小时桶、归属、金额格式化、柱图映射），用 JSONL fixture 注入扫描器；Provider HTTP 路径不在测试中触网。

## Consequences

- 上游两项目的变更（聚合口径、缓存 TTL、新增 Provider）需要在本应用镜像实现一份——多一处维护点。
- macOS 应用可观测性更好（崩溃、断点、性能 profiler 直接覆盖到逻辑层），而子进程路线只能看到 stdout / stderr。
- 启动延迟与内存占用都优于 fork CLI：纯 Swift in-process，零外部进程。
- 后续新增 Provider 需在本应用内新增枚举 case + fetch 实现；不再依赖 TS 注册表。