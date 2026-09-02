# 0002 — ccccapi 网页会话 Token 刷新机制

研究问题：ccccapi 控制台的 `auth_token` / `token_expires_at` 是否存在刷新机制，以及 omp-companion 是否能在原生 macOS Swift 客户端中复用。

结论基于 ccccapi 当前部署的前端 bundle 与公开的 Sub2API 后端源码；未读取或请求任何真实用户凭据。

---

## 1. TL;DR

| 项目 | 结论 |
| --- | --- |
| 是否支持刷新 | 支持；使用独立的 `refresh_token`，不是仅凭 `auth_token` 刷新 |
| 刷新接口 | `POST https://ccccapi.cc/api/v1/auth/refresh` |
| 请求体 | `{ "refresh_token": "<token>" }`，`Content-Type: application/json` |
| 成功响应 | 标准 envelope：`code: 0`、`data.access_token`、`data.refresh_token`、`data.expires_in`、`data.token_type` |
| 轮转语义 | 每次刷新返回新的 refresh token；旧 refresh token 立即失效 |
| 当前项目现状 | `CCCCAPI_ACCESS_TOKEN` 只有 access token，不能完成自动刷新 |
| 原生 Swift 可否集成 | 可以，但必须额外管理 refresh token、轮转持久化和并发串行化 |

---

## 2. 已确认的前端行为

### 2.1 当前 ccccapi 部署的 bundle

> **事实**：当前站点首页加载的 bundle 是 `/assets/index-mrBG7xPB.js`。在该 bundle 中可以直接定位到以下 key：`auth_token`、`refresh_token`、`token_expires_at`，以及 `/auth/refresh`。
>
> **来源**：<https://ccccapi.cc/>；<https://ccccapi.cc/assets/index-mrBG7xPB.js>
>
> **类型**：primary-source（当前部署的站点资源）

> **事实**：bundle 中的刷新逻辑向 `${getAPIBaseURL()}/auth/refresh` 发起 POST，请求体为 `{ refresh_token: e.refreshToken }`，请求头为 `Content-Type: application/json`，超时时间为 30 秒。
>
> **事实**：刷新成功要求 envelope 满足 `code === 0` 且存在 `data`；返回的 `data` 包含 `access_token`、`refresh_token`、`expires_in` 和 `token_type`。
>
> **来源**：当前 bundle 中的 `refreshAuthTokens` 实现；可读的上游对应源码：<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/frontend/src/api/tokenRefresh.ts>
>
> **类型**：primary-source

### 2.2 过期时间与普通请求

> **事实**：登录或刷新后，前端把 `token_expires_at` 写成 `Date.now() + expires_in * 1000`，因此它是 Unix epoch 毫秒时间戳。
>
> **事实**：普通 API 请求使用 `Authorization: Bearer <auth_token>`。
>
> **事实**：请求收到 401 且存在 `refresh_token` 时，前端刷新 token 后重试原请求一次；刷新失败才清除本地会话并跳转登录页。
>
> **来源**：<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/frontend/src/api/auth.ts>；<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/frontend/src/api/client.ts>；当前部署 bundle 同样包含这些逻辑。
>
> **类型**：primary-source

> **注意**：如果 localStorage 中只有 `auth_token` 和 `token_expires_at`，没有 `refresh_token`，则不能执行无感刷新。常见原因是旧登录响应没有返回 refresh token、refresh token 已被清理，或当前会话是只返回 access token 的兼容路径。

---

## 3. 已确认的后端契约

### 3.1 Endpoint

> **事实**：公开后端 handler 定义：
>
> `POST /api/v1/auth/refresh`
>
> 请求 JSON：
>
> ```json
> { "refresh_token": "rt_..." }
> ```
>
> 成功数据：
>
> ```json
> {
>   "access_token": "...",
>   "refresh_token": "...",
>   "expires_in": 3600,
>   "token_type": "Bearer"
> }
> ```
>
> 外层响应仍是 `{ "code": 0, "message": "...", "data": { ... } }`。
>
> **来源**：<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/backend/internal/handler/auth_handler.go>，`RefreshTokenRequest`、`RefreshTokenResponse` 和 `RefreshToken`。
>
> **类型**：primary-source（公开后端源码）

### 3.2 Refresh token 轮转

> **事实**：后端要求 refresh token 以 `rt_` 开头，并在服务端缓存中校验其哈希、过期时间、用户状态、token version 和会话绑定条件（若启用）。刷新时先删除旧 refresh token，再生成同一会话 family 的新 token pair。
>
> **事实**：同一个 refresh token 不能安全地被两个并发请求重复使用；先成功的请求会使旧 token 失效。
>
> **来源**：<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/backend/internal/service/auth_service.go>，`GenerateTokenPair`、`generateRefreshToken` 和 `RefreshTokenPair`。
>
> **类型**：primary-source（公开后端源码）

> **未确认事项**：ccccapi 生产实例的具体 access/refresh TTL、是否开启 session binding，以及部署版本是否完全等同于当前公开仓库版本，不能仅凭站点 bundle 确定。

---

## 4. 对 omp-companion 的影响

当前实现只读取 `.env` 中的 `CCCCAPI_ACCESS_TOKEN`，然后调用：

```text
GET https://ccccapi.cc/api/v1/user/profile
Authorization: Bearer <CCCCAPI_ACCESS_TOKEN>
```

来源：`Sources/omp-companion/Balance/Providers.swift` 与 `docs/adr/0006-ccccapi-account-balance.md`。

因此：

1. **仅增加 `token_expires_at` 读取不够**：它只能告诉客户端 token 何时过期，不能生成新 token。
2. **必须拥有 `refresh_token`**：access token 本身不能推导 refresh token。
3. **必须保存轮转结果**：刷新成功后，新的 access token 和新的 refresh token 都要被保存；继续使用旧 refresh token 会失败。
4. **必须串行化刷新**：多个 tick、重试或并发请求不能同时消费同一个 refresh token。
5. **CORS 不是原生 Swift 的主要障碍**：CORS 是浏览器约束；Swift `URLSession` 可以直接发 HTTPS 请求。但 cookie、IP/UA session binding 等服务端策略仍可能影响刷新。

---

## 5. 集成建议

### 推荐方案：Keychain 托管会话

为 `ccccapi` 单独增加 session credential store：

- access token
- refresh token
- expires-at

在 access token 即将过期时提前刷新；遇到 401 时最多刷新并重试一次。将新 token pair 作为一个原子状态更新写回 Keychain，失败则保留旧状态或进入重新登录提示，不能只写入新 access token 而丢失新 refresh token。

该方案需要调整当前项目的既有约束：当前项目明确规定凭据仅从 `.env` 读取、不读 Keychain，且没有本地缓存层。因此应先新增/更新 ADR，再实现，不应悄悄把 refresh token 写入 `.env` 或 `~/Library/Caches/`。

### 不推荐方案：读取 Chrome localStorage

不建议让 macOS app 直接读取 Chrome profile 数据库或依赖 Chrome localStorage：

- 需要依赖特定浏览器 profile 和锁文件格式；
- 多 profile、浏览器升级、用户切换都可能破坏行为；
- localStorage 只暴露当前会话状态，不替代 refresh token 的安全持久化；
- 可能与浏览器自身的 refresh token 轮转发生竞态；
- 会扩大读取其他浏览器站点数据的权限范围。

### 临时方案

在没有实现 session store 前，只能在网页重新登录/刷新后，把新的 access token 手工更新到 `.env`。这不是自动刷新，也不能解决长期无人值守运行。

---

## 6. 安全边界

- `auth_token` 和尤其是 `refresh_token` 都是 bearer credential；不要提交到 Git、日志、诊断输出或聊天内容。
- 不要把 refresh token 写入普通日志或 self-check 输出。
- 不要通过手动重复调用刷新接口做探测；一次刷新可能轮转并立即使旧 refresh token 失效。
- 刷新失败应显示明确的重新登录/重新导入状态，不应伪造余额或无限重试。

---

## 7. 参考来源

- ccccapi 当前站点：<https://ccccapi.cc/>
- ccccapi 当前前端 bundle：<https://ccccapi.cc/assets/index-mrBG7xPB.js>
- 上游前端 refresh 实现：<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/frontend/src/api/tokenRefresh.ts>
- 上游前端认证 API：<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/frontend/src/api/auth.ts>
- 上游前端请求拦截器：<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/frontend/src/api/client.ts>
- 上游后端认证 handler：<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/backend/internal/handler/auth_handler.go>
- 上游后端认证 service：<https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/backend/internal/service/auth_service.go>
