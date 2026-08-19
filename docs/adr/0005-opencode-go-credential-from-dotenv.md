# 0005 — OpenCode Go 凭据走 .env 链，不读 omp 的凭据存储

OpenCode Go（opencode.ai 订阅网关）的 `OPENCODE_API_KEY` 从 `.env` 链解析（与 DeepSeek / MiniMax 一致），不读取 omp 自身 `agent.db` 的 `auth_credentials` 表。

## Context

omp 用 `omp login opencode-go` 把 API key 写入自己的 sqlite 凭据库（`~/.omp/agent/agent.db` 的 `auth_credentials` 表，WAL 模式）。omp-companion 需要一个凭据源来调用 `GET https://opencode.ai/zen/go/v1/usage`。

两条候选路径：

1. 扩展 `CredentialsResolver` 直读 omp 的 `auth_credentials` 表——用户零维护，`omp login` 后立即生效。
2. 沿用现有 `.env` 链（`process env → <cwd>/.env → ~/.omp/agent/.env → ~/.omp/.env → ~/.env`）解析 `OPENCODE_API_KEY`。

路径 1 的风险：`auth_credentials` 是 omp 私有 schema（带 `auth_schema_version`、WAL、潜在的 multi-key 池与 ranking 策略），上游任何迁移都会静默破坏余额读取；且 app 需要处理 sqlite 并发读与密钥多行选择，复杂度不成比例。路径 2 与既有三 Provider 完全同构，且 omp 本身也读 `.env` 文件解析 provider env var——两边共享同一数据源，不引入第二事实源。

## Decision

- `OPENCODE_API_KEY` 从 `.env` 链解析（`CredentialsResolver` 零改动）。
- 不新增任何对 `agent.db` / omp 凭据存储的读取。
- 换 key 时两处维护（`omp login opencode-go` + `.env`），在 README 与 missing-credential 文案中说明。

## Consequences

- omp 升级迁移 `auth_credentials` schema 不影响本 app。
- 用户首次配置需手动把 key 放入 `.env`；`omp login` 不再自动同步到本 app。
- 保持 ADR-0001 / ADR-0003 的「不依赖 omp 内部实现」路线。
