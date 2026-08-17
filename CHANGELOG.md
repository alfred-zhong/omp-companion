# Changelog

## Unreleased


### 新增特性


- 菜单栏加入「阻止系统休眠」（Caffeinate）守护：基于 `IOPMAssertion`，同时阻止系统与显示器空闲睡眠；提供 30 / 60 / 120 分钟三档可重复启动，到期或取消自动释放；进程退出静默释放
- 守护激活时，状态栏标题前出现咖啡色 `☕️ ` 前缀 + 胶囊背景；下拉菜单顶部显示「☕️ 阻止休眠 · 还剩 Xm/Xs」实时倒计时（每秒推进）

### 变更

- 菜单栏标题对所有 percent 类型 provider 仅展示「使用额度」（如 `12%`），不再附带过期时间
- 下拉菜单余额行统一为 `provider: 余额` 格式:percent 类型如 `minimax-code-cn: 8%`,有 reset 时 reset 单独起一行 `重置剩余时间: 4h30m`(无 reset 时只有一行);cny 类型如 `deepseek: ¥12.50`
- `BalanceFormatter.menuBarText` 收紧为纯余额段(percent 只返回 `"8%"`,reset 文案改由 `StatusBarPresenter.normalMenu` 拼装第二行)
- `SelfCheck` 新增 5 条断言锁定上述行为（`Balance.menuBarTextCNY` / `Menu.normal.percentRow` 等），全部通过
- 状态栏 `NSButton.title` 改为 `attributedTitle`，文本由纯字符串升级为 `NSAttributedString` 以承载彩色前缀
- `SelfCheck` 增加 Caffeinate / CountdownFormatter / StatusBarTitleComposer 共 14 条断言，全部通过
- **架构重构（深度化）**：
  - 状态栏展示层拆出 `StatusBarPresenter`（`renderTitle` / `renderChrome` / `renderMenu` 三个纯函数），`StatusBarController` 缩为 Timer + Combine + 转发；删除 `StatusBarTitleComposer`（已并入 Presenter 内部 helper）
  - Refresh pipeline 引入 `BalanceSource` / `DailyUsageSource` 协议 + `LiveBalanceSource` / `LiveDailyUsageSource` / `FakeBalanceSource` / `FakeDailyUsageSource`；`RefreshController` 简化为「两个 source + apply」组合，`SnapshotError` 枚举封装 configMissing / missingCredential / fetchError / scanError
  - SleepGuard 拆出 `IOPMAssertionAdapter` + `CountdownTicker` 协议，整类 `@MainActor` 化，删除 `NSLock` 与 `DispatchQueue.main.async`
  - 两个 MiniMax provider 合并为 `MiniMaxRemainsProvider(endpoint:credentialKey:providerID:)`，`BalanceRegistry` 注册两次；`MiniMaxTokenPlanProvider` / `MiniMaxCodingPlanCNProvider` 已删除
- `SelfCheck` 新增 53 条断言（Presener 22 + Refresh 9 + SleepGuard 13 + MiniMax 9），全部通过

## 0.1.2 (2026-08-13)

### 变更
- 移除本地缓存：定时刷新每次直接查询 Provider / 扫描 omp 会话转录，不再读写 `~/Library/Caches/` 下缓存文件（决策见 `docs/adr/0004-no-local-cache.md`，取代 0002）

### Bug 修复
- 下拉菜单中"偏好… / 立即刷新 / 退出"置灰不可点：菜单项未设置 target，menu 自动禁用。已为所有 action 菜单项显式设置 target
- 移除下拉中"peak …柱图"行（不再展示柱图）

## 0.1.1 (2026-08-13)

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
