# Changelog

## Unreleased

### 变更

- DeepSeek / MiniMax（Token Plan 与 Coding Plan CN） / OpenCode Go 的 API key 由 `.env` 链迁移到偏好面板：偏好面板新增「Provider API Keys」节（4 个 `SecureField`），值经 `SettingsStore` 存 UserDefaults（明文）；新增 `CredentialSource` 协议（`Balance/`），`SettingsStore` 实现，`BalanceProvider` 的 `hasCredential` / `fetch` 参数由 `CredentialsResolver` 换为 `any CredentialSource`；彻底移除 `.env` 链读取并删除 `CredentialsResolver.swift`（旧 key 不再自动读取，需在偏好面板手动填写；决策见 `docs/adr/0008-provider-keys-in-preferences.md`）。
- ccccapi 鉴权改由偏好面板配置：新增邮箱 + 密码输入与「测试连接」；应用独立登录（`POST /auth/login`）换取 access + refresh token，会话仅内存、不落盘；access token 临近过期自动刷新（`POST /auth/refresh`，refresh token 每次轮转），刷新被拒后用密码兜底重登；移除 `.env` 的 `CCCCAPI_ACCESS_TOKEN` 静态 token 路径（决策见 `docs/adr/0007-ccccapi-login-refresh.md`，取代 `docs/adr/0006-ccccapi-account-balance.md`）。

### Bug 修复

- 偏好面板的邮箱/密码文本域无法粘贴：菜单栏 accessory 应用未装主菜单，缺少 Edit 菜单导致 Cmd+V 的 `paste:` 键等价无法路由。已装入最小主菜单（含编辑菜单），设置窗口文本域恢复粘贴/复制/剪切/全选。

### 新增特性

- 新增 ccccapi Provider：`ccccapi/*` 使用 `.env` 中的 `CCCCAPI_ACCESS_TOKEN` 查询账户 USD 余额；只解析标准用户资料响应的 `data.balance`，内部保留 USD，展示按 `$10 = ¥1` 转为人民币，不读取或展示身份、API Key、订阅等字段（决策见 `docs/adr/0006-ccccapi-account-balance.md`）。
- 菜单栏新增构建时本地打包的 ccccapi Sub2API SVG logo（`provider_ccccapi.svg`）。

### 变更

- 凭据解析的 agent `.env` 跟随 `PI_CODING_AGENT_DIR`；空白凭据统一视为缺失，不发送空 Bearer token。
- Provider 远端请求失败时不再保留上一份余额快照：状态栏与菜单对所有 provider 统一显示 `NaN` 并保留具体错误（与 ccccapi 行为一致）；缺配置、未匹配 Provider、凭据缺失仍清空余额。
- 移除菜单栏余额旁 stale 的 `·off` 后缀：余额不可用时状态栏直接显示 `NaN`，不再回退到旧快照。

### Bug 修复
- 未匹配但格式正确的 Provider 不再触发余额请求；状态栏与菜单保留 Provider / Model 展示，并使用 omp 官网图标作为默认图标。
- 未匹配 Provider 启用「阻止系统休眠」时，状态栏与其他 Provider 一致追加咖啡杯标记。
- 统一 omp 默认图标的菜单栏逻辑尺寸，避免显示大于其他 Provider 图标。

### 新增特性


- 新增 Provider：OpenCode Go（`opencode-go/*`，opencode.ai 订阅网关）——状态栏展示 5h 滚动窗口已用百分比，下拉菜单平铺 5h / 7d / 月度三窗口明细（各自重置倒计时，≥24h 用 `XdYh`；`rate-limited` 窗口标「已限流」）；凭据走 `.env` 链 `OPENCODE_API_KEY`（决策见 `docs/adr/0005-opencode-go-credential-from-dotenv.md`）
- 菜单栏新增 OpenCode Go 官方品牌 logo（opencode.ai favicon 终端窗框字形蒙版，`provider_opencode_go@2x/3x.png`）
- 菜单栏在余额 / 用量文字左侧渲染供应商 logo:DeepSeek / MiniMax / Coding Plan (CN) 走各自动蒙版（黑透 PNG），`.unknown` 路由下落回默认问号图
- 菜单栏加入「阻止系统休眠」（Caffeinate）守护:基于 `IOPMAssertion`,同时阻止系统与显示器空闲睡眠;提供 30 / 60 / 120 分钟三档可重复启动,到期或取消自动释放;进程退出静默释放
- 状态栏标题在 caffeinate 激活时把咖啡杯标记从 logo 与文字之间移到余额右侧,减少视觉抢戏
- 下拉菜单余额行（`provider: usage`）的 provider 后跟括号标注当前模型名：取自 config.yml 的 `modelRoles.default`，取最后一个 `/` 之后的模型段并剥掉末尾 think level（如 `hy3:high` → `OpenCode Go (hy3): 67%`、`deepseek/deepseek-chat` → `DeepSeek (deepseek-chat): ¥12.50`）。仅展示 config 默认模型，不读 runtime 覆盖（ADR-0001）
- 用量进度条：percent 类型 provider 在首行下方新增自绘进度条行（圆角轨道 + 段色填充），格式 `5h [条] 8% 4h17m 后重置`——窗口标签 + 紧贴条尾的百分比 + 右侧左对齐的重置倒计时，无 `·` 分隔；三段色 <70 绿 / 70–90 黄 / >90 红；OpenCode Go 三窗口各一行、MiniMax interval 窗口一行、stale 时回退纯文本行
- MiniMax 读取 interval 窗口起止（`start_time` / `end_time`）：窗口大小由时长推导（整小时 `5h`、非整小时 `240m`，随套餐可变），进度条行显示窗口标签；`current_interval_status == 2`（耗尽）映射 `rate-limited` 语义

### 变更

- 下拉菜单余额行 provider 前缀改用展示名（`DeepSeek` / `MiniMax Coding Plan CN` / `OpenCode Go`），不再输出原始 provider id
- 偏好面板刷新间隔由滑块（20-600s）改为三档分段选择：30s / 60s / 120s，默认 60s；存量非法值自动回退默认并写回自愈
- 移除偏好面板中「开机自启」占位开关（该功能未启用）
- 菜单栏标题对所有 percent 类型 provider 仅展示「使用额度」（如 `12%`），不再附带过期时间
- 下拉菜单余额行统一为 `provider: 余额` 格式:percent 类型如 `minimax-code-cn: 8%`,有 reset 时 reset 单独起一行 `重置剩余时间: 4h30m`(无 reset 时只有一行);cny 类型如 `deepseek: ¥12.50`
- `BalanceFormatter.menuBarText` 收紧为纯余额段(percent 只返回 `"8%"`,reset 文案改由 `StatusBarPresenter.normalMenu` 拼装第二行)
- 下拉菜单模型名改为内联到余额行（`StatusBarPresenter.normalMenu` 余额行 provider 后括号拼接 `(<model>)`），不再单独成行；`SelfCheck` 改为断言余额行内联（`Menu.model.inline` / `Menu.model.stripThinkLevel`）与 `Refresh.success.model` 通路
- `SelfCheck` 新增 5 条断言锁定上述行为（`Balance.menuBarTextCNY` / `Menu.normal.percentRow` 等），全部通过
- `SelfCheck` 增加 Caffeinate / CountdownFormatter / StatusBarTitleComposer 共 14 条断言，全部通过
- 下拉菜单余额行结构统一为「首行 `provider (model)` + 数值第二行」：percent 类型第二行为进度条行（含重置倒计时），DeepSeek CNY 第二行为 `余额 ¥X.XX`；首行不再显示余额/百分比
- 进度条行布局修订：右文本由「定宽右对齐」改为「百分比紧贴条尾（百分比区定宽 40pt 保证多行条等长）+ 重置倒计时右区左对齐」
- 移除进度条行的 `已限流` 后缀（限流状态不再在菜单展示）

### Bug 修复
- MiniMax logo 换源:弃用 lobe-icons 变体（线条过细，32/48px 蒙版下碎成点阵），改用官网导航栏官方红色 "M" 字形（`filecdn.minimax.chat` 裁剪图形区），重新生成 `provider_minimax@2x/3x.png` 蒙版并保留 `provider_minimax.color.png` 原图
- OpenCode Go 下拉菜单三窗口重置倒计时格式不统一：5h 窗口为紧凑无空格 `4h59m`，而 7d / 月度窗口为 `3d 14h` / `29d 22h`（中间带空格）。已统一 `BalanceFormatter.formatDuration` 为全程无空格风格 `XdYh`（与 `formatHMS` / 状态栏 `YhYm` 一致）
- 窄菜单中的用量进度条可能缩成过短：进度条行现按固定布局宽度自动加宽，保证有左标签和无左标签时轨道均至少 60pt；`SelfCheck` 新增两条最小长度断言


### 变更
- 移除本地缓存：定时刷新每次直接查询 Provider / 扫描 omp 会话转录，不再读写 `~/Library/Caches/` 下缓存文件（决策见 `docs/adr/0004-no-local-cache.md`，取代 0002）

### Bug 修复
- 下拉菜单中"偏好… / 立即刷新 / 退出"置灰不可点：菜单项未设置 target，menu 自动禁用。已为所有 action 菜单项显式设置 target
- 移除下拉中"peak …柱图"行（不再展示柱图）

### Bug 修复
- DeepSeek 余额恒为 0：响应字段是 `total_balance`（字符串），此前误解析为 `balance`，导致取值为 nil → 0。已按上游 omp-model-usage 对齐，取 `balance_infos[0].total_balance`。

## 0.1.0 (2026-08-13)

### 新增特性
- macOS 菜单栏常驻 app，LSUIElement，无 Dock 图标
- 菜单栏展示 omp 当前默认 Provider 的余额（CNY `¥X.XX` 或 percent `X%: YhYm`）
- 弹出菜单：今日 token 消耗（↑输入 / ↓输出 / ⚡缓存读取 / hit%）
- 弹出菜单：近 5h token 消耗（后 5 个滑动小时桶并集）+ 5 根柱图 + peak
- Provider 路由：直接读 `~/.omp/agent/config.yml` 与项目 `<cwd>/.omp/config.yml` 合并后的 `modelRoles.default`，支持 `PI_CODING_AGENT_DIR` 重定位
- 支持 Provider：DeepSeek（CNY 余额）、MiniMax Token Plan（percent + 重置倒计时）、MiniMax Coding Plan 中国版
- 凭据解析：镜像 omp .env 链（process env → `<cwd>/.env` → `~/.omp/agent/.env` → `~/.omp/.env` → `~/.env`）
- 12 滑动小时桶 + mtime 剪枝 + (relPath, eventId) 复合去重键，递归扫描 omp 会话转录（含子代理）
- 独立缓存路径：余额 TTL 60s、日用量 TTL 30s（带本地日期，跨零点失效），原子写
- 错误降级：永不空白——缺凭据 / 缺配置 / 网络失败时菜单栏显示 `⚠︎` 或 `?omp` + 跳转 README
- SwiftUI 偏好面板：刷新间隔 20-600s
- 一键构建：`./build.sh`（编译 + ad-hoc 签名 + 拼 `.app` bundle）
- 自检入口：`swift run omp-companion --self-check`，覆盖 TokenStats / CompactFormatter / BalanceFormatter / HourlyBars / HourlyAggregator / JSONLParser / ProviderID

### 已知限制
- 鉴权 token 走 .env 链（与上游 omp-model-usage 一致），不读 Keychain
- runtime 覆盖（`--model` / `--smol` / env vars）不可见（决策记录在 `docs/adr/0001-default-model-from-yml.md`）
- 开机自启暂未启用，偏好面板中开关 disabled
- 本机 ad-hoc 签名，未做 Developer ID / 公证
- 单元测试采用 main target 内的 `SelfCheck` 断言（CommandLineTools 环境无 XCTest / Testing 模块；生产环境可迁回 XCTest）
