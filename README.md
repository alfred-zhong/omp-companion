# omp-companion

Oh My Pi 配套工具：macOS 菜单栏常驻 app，展示 omp 当前默认 Provider 的余额，以及当日 / 近 5h 的 token 消耗。

## 功能

- 菜单栏右上角展示余额（普通 CNY `¥X.XX`、USD `$X.XX` 或 percent `X%: YhYm`；ccccapi 的 USD 余额按 `$10 = ¥1` 显示）
- 弹出菜单展示：
  - 当日：↑输入 · ↓输出 · ⚡缓存读取 · hit%
  - 近 5h：↑输入 · ↓输出 · ⚡缓存读取 · hit%
- 自动定时刷新（默认 60s，可在偏好面板调整为 20-600s），每次刷新直接执行查询 / 扫描，无本地缓存
- 错误降级永不空白：缺配置 / 缺凭据时显示 `⚠︎` 或 `?omp` 并跳转 README；ccccapi 请求失败时显示 `NaN` 与具体错误

## 支持的 Provider

| Provider | 模型示例 | 端点 |
|---|---|---|
| DeepSeek | `deepseek/*` | `api.deepseek.com/user/balance` |
| MiniMax Token Plan | `minimax/*` | `www.minimaxi.com/v1/token_plan/remains` |
| MiniMax Coding Plan (CN) | `minimax-code-cn/*` | `api.minimaxi.com/v1/coding_plan/remains` |
| OpenCode Go | `opencode-go/*` | `opencode.ai/zen/go/v1/usage`（5h / 7d / 月度三窗口已用%） |
| ccccapi | `ccccapi/*` | `ccccapi.cc/api/v1/user/profile`（账户 USD 余额，按 10:1 展示为 CNY） |

## 凭据
镜像 omp 的 `.env` 链：process env → `<cwd>/.env` → agent `.env` → `~/.omp/.env` → `~/.env`；agent 目录默认 `~/.omp/agent`，设置 `PI_CODING_AGENT_DIR` 时跟随该目录。**ccccapi 除外**：凭据改由偏好面板配置（ADR-0007），不读 `.env`。

| Provider | 所需 env |
|---|---|
| DeepSeek | `DEEPSEEK_API_KEY` |
| MiniMax Token Plan | `MINIMAX_API_KEY` |
| MiniMax Coding Plan CN | `MINIMAX_CODE_CN_API_KEY` |
| ccccapi | 偏好面板配置邮箱 + 密码（应用自主登录并按需刷新，见 `docs/adr/0007-ccccapi-login-refresh.md`；不读 `.env`） |
| OpenCode Go | `OPENCODE_API_KEY`（写入 agent `.env`；`omp login opencode-go` 不自动同步，见 `docs/adr/0005-opencode-go-credential-from-dotenv.md`） |

## 编译与运行

```bash
# 编译 + 拼 .app + ad-hoc 签名
./build.sh

# 启动
open build/omp-companion.app

# 或：直接跑可执行文件
./build/omp-companion.app/Contents/MacOS/omp-companion
```

`make build` / `make run` / `make test`（跑自检）也可。

## 自检

```bash
swift run omp-companion --self-check
```

输出 `[self-check] OK (全部通过)` 即表示所有纯函数与集成断言（TokenStats 派生、12 小时桶归属、CompactFormatter、BalanceFormatter、JSONL 解析、复合去重键、Provider 路由、ccccapi 响应解析、10:1 人民币格式化、失败 NaN 状态）通过。

## 架构

参见 `CONTEXT.md` 术语表与 `docs/adr/` 中的决策记录：

- `0001-default-model-from-yml.md` — 为何不 fork `omp config get`
- `0002-independent-cache-paths.md` — 独立缓存路径决策（已被 0004 取代）
- `0003-swift-rewrite-instead-of-cli.md` — 为何完全 Swift 重写而非 shell-out 上游 CLI
- `0004-no-local-cache.md` — 为何去掉本地缓存，定时刷新直接执行
- `0006-ccccapi-account-balance.md` — ccccapi 余额用网页 token 按 10:1 展示（已被 0007 取代）
- `0007-ccccapi-login-refresh.md` — ccccapi 凭据改偏好面板配置，应用独立登录并按需刷新（取代 0006）
 
## ccccapi 安全说明

- 凭据为偏好面板配置的邮箱+密码（存 UserDefaults，明文，ADR-0007）；应用独立登录：邮箱+密码 `POST /auth/login` 换取 access + refresh token，会话（access + refresh + expiresAt）只存内存、不落盘；access token 临近过期时 `POST /auth/refresh` 按需刷新（refresh token 每次轮转，旧 token 立即失效）。
- 查询只读取 `data.balance`；内部保留 USD 来源语义，展示按 `$10 = ¥1` 转为人民币。请求失败、鉴权失败或响应无可信余额时显示 `NaN`，不保留旧余额。
- 不保存或展示用户 ID、API Key、订阅等资料；不在日志或 self-check 输出中打印 token。
- 密码错误显示"账号登录失败: 凭据无效"并对登录做 5 分钟冷却；账户开启 2FA 时显示"暂不支持自动登录"。
- 若曾把 token 暴露给他人，应重新登录/轮换会话。


## 已知限制

- 鉴权凭据一般从 `.env` 链读取，不读 Keychain；ccccapi 例外（ADR-0007）：偏好面板配置，会话 token 仅内存。
- runtime 覆盖（`--model` / `--smol` / env vars）不可见（决策见 ADR-0001）
- 本机 ad-hoc 签名，未做 Developer ID 公证
