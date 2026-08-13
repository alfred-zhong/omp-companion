---
status: superseded by ADR-0004
---

# 0002 — 独立缓存路径与上游工具不共享

omp-companion 在自己的缓存路径（macOS standard `~/Library/Caches/<bundle-id>/` 下属子目录）下保存两份缓存：余额缓存（TTL 60s）与日用量缓存（TTL 30s），不读写上游 `~/.cache/omp-model-usage/` 与 `~/.cache/omp-daily-usage/`。

## Context

两个上游项目都把缓存文件写到 `~/.cache/<project>/`。若本应用直接复用同路径，会与手工跑 CLI 时写入的文件互踩——尤其是 CLI 进程与本应用几乎同时调用时，atomic rename 写入可能让另一侧读到陈旧或半写文件。Swift 上层 cache 文件与上游 TS 文件结构也不一致。

## Decision

- 余额缓存路径：`~/Library/Caches/<bundle-id>/balance/<provider>.json`（provider 分桶）。
- 日用量缓存路径：`~/Library/Caches/<bundle-id>/daily-usage/<YYYY-MM-DD>.json`，带本地日期，跨零点失效。
- TTL 与上游保持：余额 60s、日用量 30s。
- 写采用临时文件 + rename 原子替换；写失败静默吞掉。
- 不读上游缓存：若本应用冷启动时上游缓存刚写入、TTL 未过，本应用也至少要等到自己写满一次才走缓存命中——保护首次可观测性。

## Consequences

- 用户如果同时跑上游 CLI 与本应用，两个进程各自维护自己的缓存副本——API 调用量比"共享缓存"略多（每侧独立 TTL 起算）。可接受。
- 缓存路径干净跟随 macOS 惯例；卸载 app 时系统自动清理 `~/Library/Caches/<bundle-id>/`，无残留。
- 上游若调整 TTL，本应用不会自动跟随——需手动同步。