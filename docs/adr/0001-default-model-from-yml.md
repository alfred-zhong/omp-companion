# 0001 — Default Model 取自合并后的 yml 而非 `omp config get`

Default Model（`modelRoles.default`）通过合并 `~/.omp/agent/config.yml` 与项目 `<cwd>/.omp/config.yml` 后直接读取；不 fork `omp config get modelRoles` 子进程。

## Context

上游 omp-model-usage 选择 fork `omp config get modelRoles` 拿到合并后的 record，原因是 runtime in-memory 覆盖（`--model` / `--smol` / `PI_SMOL_MODEL` 等 env vars）只存在于 omp 进程内、不落盘，无法通过读文件拿到。本项目选择完全不依赖 omp CLI 在场，因此放弃 runtime 覆盖可见性。

## Decision

- 在 Swift 中用 Yams 解析 `~/.omp/agent/config.yml`（fallback `config.yaml`）和 `<cwd>/.omp/config.yml`，按 omp 文档规定的对象 deep merge 规则合并后取 `modelRoles.default`。
- 路径解析遵守 `PI_CODING_AGENT_DIR` 环境变量（重定位整个 omp agent 根目录）。
- Provider id 取 default 字符串中第一个 `/` 前的 lower-case 段，与上游对齐。
- 若 default 缺失或文件不存在，菜单进入"未检测到 omp 配置"分支，跳转 README，不做兜底默认值。

## Consequences

- 不依赖 `omp` CLI 在 `$PATH` 中存在；本机安装即用。
- 用户在 omp 内临时用 `--model foo` 或 `PI_SMOL_MODEL=foo` 启动会话时，菜单栏仍按 yml 中 default 显示对应 Provider 的余额——可能与"此刻实际使用的模型"不一致。这是被接受的权衡。
- YAML 解析依赖 Yams（CocoaPods/SPM 包），后续若 omp 增加新合并层（如全局 overlay 文件）需要同步适配。
- 若用户用 `--config <file>` 启动 omp，本应用看不到该 overlay——但该用法罕见且仅影响多配置调试场景。