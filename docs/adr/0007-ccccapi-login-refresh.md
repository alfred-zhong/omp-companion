# 0007 — ccccapi 凭据改为偏好面板配置，应用独立登录并按需刷新

ccccapi 账户鉴权从 `.env` 里的静态 `CCCCAPI_ACCESS_TOKEN` 迁移为在偏好面板配置邮箱+密码：应用启动后独立 `POST /auth/login` 取 access token，进程内按需刷新，从而持续查询余额。会话（access + refresh token）只存内存、不落盘；凭据本身（邮箱/密码）经 `SettingsStore` 存 UserDefaults。

## Context

原实现只读 `CCCCAPI_ACCESS_TOKEN`（ADR-0006）。该 token 是无刷新能力的网页会话凭据，过期后只能手工重新粘贴，无法无人值守长期运行。经源码与线上探测确认：登录为 `email + password`；线上该账号无验证码、无 TOTP 2FA（`requires_2fa` 为 false）；登录/刷新均返回 `expires_in`（实测 86400s）；刷新走 `POST /auth/refresh` 且**轮转**（旧 refresh token 立即失效）；日志/密钥不得回显。

## Considered Options

1. **继续静态 `.env` token**（现状）——被否：无刷新，无法长期运行。
2. **读取 Chrome localStorage**——被否：依赖浏览器 profile、与浏览器自身轮转竞态、扩大读取范围。
3. **Keychain 持久化会话**——备选：会话 token 更安全，但用户选择凭据存 UserDefaults；且会话本身仅内存、不落盘，无需 Keychain。
4. **仅内存会话 + 启动时用偏好密码登录**（选定）——菜单栏进程启动一次常驻，登录一次 POST 可忽略；避免持久化轮转密钥，保持 ADR-0004 "无本地缓存" 约束。

## Consequences

- `CCCCAPI_ACCESS_TOKEN` 环境变量**移除**（只替换）；ccccapi 必须配置邮箱+密码。
- 邮箱/密码经 `SettingsStore` 存 UserDefaults（**明文**，用户已知的取舍）；会话 token 仅内存。
- 新增 `CcccapiSessionManager`：单飞登录/刷新，`validAccessToken()` 提前刷新（`expires_in` 内距过期 <5h）+ 401 被动 `reauthorize()` 重试一次；刷新链失败用密码兜底重登；凭据无效失败进入 5 分钟冷却。
- `HTTPClient` 协议新增 `post`（auth 端点需要读 401 的 `reason`，故非 2xx 原样返回）。
- 余额仍读 `GET /user/profile` 的 `data.balance`（USD，10:1 转 CNY）；失败降级 `NaN` + 具体原因。
- 该账号无 2FA；若未来账号开启，登录返回 `requires_2fa` 时显示"暂不支持自动登录"降级，不做交互式 2FA。

本 ADR 取代 ADR-0006。
