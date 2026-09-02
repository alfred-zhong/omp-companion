# 0008 — DeepSeek / MiniMax / OpenCode Go API key 迁移到偏好面板

DeepSeek、MiniMax（Token Plan 与 Coding Plan CN）、OpenCode Go 的 API key 从 `.env` 链读取迁移到偏好面板配置（`SettingsStore` / UserDefaults）。彻底移除 `.env` 链读取与 `CredentialsResolver`。

## Context

原实现沿 `.env` 链（process env → `<cwd>/.env` → `~/.omp/agent/.env` → `~/.omp/.env` → `~/.env`）读取四个鉴权 key。该链依赖进程环境与文件存在性,而 omp-companion 是菜单栏常驻 app,启动语境（cwd、环境、agent 目录）不一定与 omp CLI 一致,导致 `.env` 定位不可靠;且四个 provider 各自硬编码 key 名,分散难管。

用户选择统一到偏好面板：与 ccccapi（ADR-0007）同层,由偏好面板集中管理所有凭据。

## Considered Options

1. **继续 `.env` 链**（现状）——被否:菜单栏 app 与 omp CLI 语境不一致,`.env` 定位不可靠;凭据分散在多个进程态来源。
2. **迁移到偏好面板**（选定）——与 ADR-0007 ccccapi 同构,凭据集中,用户可读可改。
3. **Keychain 存储**——备选:四个 API key 是可直接消费的秘钥,Keychain 更安全。但用户选择 UserDefaults 明文,与 ccccapi 已接受的取舍一致;菜单栏 app 自启场景下 Keychain 解锁时序复杂,收益不匹配当前价值。

## Consequences

- **双份配置（必须挑明）**:omp CLI 上游**仍**读 `.env`。故四个 key 需**两处各配一份**——`.env` 供 omp 用、偏好面板供 omp-companion 用。这不是"迁移",是**新增第二份配置**;已在 CHANGELOG 与本文档明确,不复用 `.env` 作为回退。
- **UserDefaults 明文**:四个 key 经 `SettingsStore` 存 UserDefaults（明文）,与 ccccapiPassword 同层取舍,接受。
- **无 `.env` 回退 / 无自动预填**:彻底不移除 `.env` 读取且不做首次启动预填。已配 `.env` 的用户升级后需在偏好面板手动填写。
- **`CredentialSource` 协议**:`Balance/` 新增 `CredentialSource: Sendable`（`resolve(_ name:) -> String?`）,键名沿用旧 `.env` 变量名作为映射键,使 `MiniMaxRemainsProvider.credentialKey` 等既有抽象不变。`SettingsStore` 实现该协议（同时已实现 `CcccapiCredentialSource`）。
- **`CredentialsResolver` 删除**:只服务 provider key,迁移后无存在必要;`loadEnvFile` / `candidateEnvFiles` / `loadAll` / `mergedEnv` 全删,干净切换。
- **`BalanceProvider` 接口参数换源**:`hasCredential(creds:)` / `fetch(creds:http:)` 参数由 `CredentialsResolver` 换为 `any CredentialSource`;`LiveBalanceSource` 持 `any CredentialSource` 并在 `App.swift` 注入 `settingsStore`。
- **四个字段**:偏好面板「Provider API Keys」节,`SecureField` 分别对应 `DeepSeek API Key` / `MiniMax API Key (Token Plan)` / `MiniMax Coding Plan CN API Key` / `OpenCode Go API Key`;空/全空白视为缺失（`hasCredential` 语义不变）。
- **没有 Keychain / 没有 provider 级"测试连接"按钮**:与现有 ccccapi 测试连接不同,key 校验偏差在应用内不做;错误在状态栏降级为「鉴权失败 (401)」等文案。
