# Repository Guidelines

> 面向 AI 助手的 omp-companion 仓库协作手册。补充人类规范；不重复常识。

## Project Overview

`omp-companion` 是 macOS 菜单栏常驻 app（LSUIElement，无 Dock 图标），聚合展示 **omp 当前所用模型的余额** 与 **当日 / 近 5h token 消耗**。每 20-600s 定时刷新一次，默认 60s。错误降级永不空白：缺配置、缺凭据或网络失败时显示 `⚠︎` / `?omp` 并跳转 README。

- 支持 Provider：`DeepSeek`（CNY）、`MiniMax Token Plan`、`MiniMax Coding Plan (CN)`。
- Provider 路由：直接读合并后的 `~/.omp/agent/config.yml` 与 `<cwd>/.omp/config.yml` 的 `modelRoles.default`；honor `PI_CODING_AGENT_DIR`。
- 凭据：全部 provider 凭据（DeepSeek / MiniMax×2 / OpenCode Go / ccccapi）改由偏好面板配置、经 `SettingsStore` 存 UserDefaults（ADR-0008 / ADR-0007），不经 `.env`；`.env` 链读取已移除（`CredentialsResolver` 删除）。

## Architecture & Data Flow

```
@main OmpCompanion.main
   └─ AppDelegate.applicationDidFinishLaunching          ← DI 装配
       ├─ CredentialSource / SettingsStore               ← provider API key + ccccapi 凭据来源（偏好面板）
       ├─ ConfigSource(homeDir, cwd, env)                ← YAML 合并 (Yams)
       ├─ DailyUsageScanner(sessionsRoot)                ← JSONL 递归扫描
       ├─ SettingsStore()                                ← UserDefaults 镜像
       ├─ RefreshController(creds, config, scanner, …)   ← 每 tick 跑两管线
       ├─ SettingsWindowController(onIntervalChange:)    ← SwiftUI 偏好面板
       └─ StatusBarController(controller, state, …)     ← NSStatusItem + NSMenu
            ├─ Combine 订阅 AppState @Published × 6      ← UI 主线程刷新
            └─ Timer.scheduledTimer(.common)             ← 每 N 秒 fire tick

每个 tick (RefreshController.tick):
  refreshBalance() →  load config → pick provider → hasCredential? → fetch → setBalance(BalanceSnapshot)
  refreshDaily()   →  scanner.scan(now) → aggregator.aggregate → setDaily(DailyUsageSnapshot)
```

**关键决策（必须遵守，不是历史）**

- **无本地缓存层**。每个 tick = 实时查 Provider + 实时扫 omp 会话 JSONL。`~/Library/Caches/<bundle-id>/` 下只剩 URLSession 自管的 `Cache.db`。`BalanceCache` / `DailyUsageCache` / `JSONCache` 已被 ADR-0004 删除，禁止重新引入。
- **runtime 覆盖（`--model` / `--smol` / env vars）不可见**于菜单栏。这是有意取舍（ADR-0001），不要尝试"修复"过期。
- **不 shell-out 上游 CLI**。所有逻辑 Swift 重写，新增 Provider 仅需枚举 case + 实现 `BalanceProvider.fetch`。
- `BalanceSnapshot.isStale` 是持久化的唯一退化路径。

## Key Directories

| 路径 | 用途 |
|---|---|
| `Sources/omp-companion/` | 唯一可执行 target（`executableTarget`） |
| ↳ `App.swift` | `@main` 入口 + DI + `--self-check` 分派 |
| ↳ `RefreshController.swift` | tick 编排 + `AppState` (`ObservableObject`) |
| ↳ `SelfCheck.swift` | 进程级断言入口（`static run() -> Int`） |
| ↳ `Model/Models.swift` | 共享值类型：`ProviderID` / `BalanceResult` / `BalanceSnapshot` / `TokenStats` / `HourBucket` / `DailyUsageSnapshot` / `OmpConfig` |
| ↳ `Balance/` | `HTTPClient` 协议 + `URLSessionHTTPClient` 实现 + `HTTPError` 枚举；`Providers.swift` 三 Provider + `BalanceRegistry`；`CredentialSource.swift` provider key 来源协议；`BalanceFormatter` 状态栏文案；`CcccapiSessionManager.swift` ccccapi 登录/刷新会话状态机 |
| ↳ `Config/ConfigSource.swift` | `ConfigSource.load() -> OmpConfig`；模块级 `deepMerge` |
| ↳ `DailyUsage/Formatting.swift` | `CompactFormatter.format(Int)` K/M/B + 滚动边界 `999_500 → "1.0M"` |
| ↳ `DailyUsage/JSONLLineParser.swift` | 单行 JSONL → `ParsedEvent`，复合去重键 `"\(relPath):\(eventId)"` |
| ↳ `DailyUsage/DailyUsageScanner.swift` | 递归扫描 + mtime 剪枝 + dedup |
| ↳ `DailyUsage/HourlyAggregator.swift` | 12 滑动小时桶（`HOUR_BUCKET_COUNT = 12`, `HOUR_MS = 3_600_000`，左开右闭） |
| ↳ `UI/StatusBarController.swift` | `NSStatusItem` + `NSMenu` + `Timer` + Combine sink |
| ↳ `UI/SettingsWindow.swift` | `SettingsStore` (`@Published` × 镜像 UserDefaults) + `NSHostingController<SettingsView>` |
| `Resources/Info.plist` | bundle 元数据，**`LSUIElement=true`**、`CFBundleIdentifier=com.alfred-zhong.omp-companion`、`LSMinimumSystemVersion=13.0` |
| `docs/adr/0001-default-model-from-yml.md` | 当前：yml 解析而非 `omp config get` |
| `docs/adr/0002-independent-cache-paths.md` | **已被 0004 取代**，勿参考为现行策略 |
| `docs/adr/0003-swift-rewrite-instead-of-cli.md` | 当前：完全 Swift 重写，不 shell-out |
| `docs/adr/0004-no-local-cache.md` | 当前（取代 0002）：无本地缓存 |
| `docs/adr/0006-ccccapi-account-balance.md` | 已被 0007 取代，勿参考为现行策略 |
| `docs/adr/0007-ccccapi-login-refresh.md` | 当前（取代 0006）：ccccapi 偏好面板凭据 + 仅内存会话 + 按需刷新 |
| `docs/adr/0008-provider-keys-in-preferences.md` | 当前：DeepSeek / MiniMax×2 / OpenCode Go API key 偏好面板配置（取代 `.env` 链；删除 `CredentialsResolver`） |

## Development Commands

```bash
make build              # swift build -c release + 拼 .app + ad-hoc 签名（= ./build.sh）
make run                # build 后 open build/omp-companion.app
make test               # swift run omp-companion --self-check（必跑）
make clean              # rm -rf build .build
```

`-c` 由 `CONFIG?=release` 控制；需要 debug 编译可 `CONFIG=debug make build`。

`build.sh` 等价步骤：

```bash
swift build -c release
swift build -c release --show-bin-path        # 取 .build/release/omp-companion
mkdir -p build/omp-companion.app/Contents/{MacOS,Resources}
cp .build/release/omp-companion build/omp-companion.app/Contents/MacOS/
cp Resources/Info.plist   build/omp-companion.app/Contents/Info.plist
codesign --force --deep --sign - build/omp-companion.app   # ad-hoc
```

启动：`open build/omp-companion.app`，或直接跑二进制 `build/omp-companion.app/Contents/MacOS/omp-companion`。

## Code Conventions & Common Patterns

### 异步

- **不引入 `DispatchQueue` / `actor`**。fetch 路径用 `async/await`，UI 跳主线程 `await MainActor.run { … }`，Combine 桥接 `MainActor.assumeIsolated { updateTitle() }`。
- tick 在 `Timer.scheduledTimer(withTimeInterval:repeats:)` 上调度（`RunLoop.main` + `.common`），每次 fire 包装在 `Task { @MainActor in await self.controller.tick() }`。
- `init` 里会立刻 fire 一次首次 tick **加上** timer 首次 tick：不主动去重。
- 例：

```swift
// RefreshController.refreshBalance
do {
    let snap = try await provider.fetch(creds: creds, http: http)
    await MainActor.run { state.setBalance(snap) }
} catch {
    await MainActor.run { state.setBalanceError(Self.humanReadable(error)) }
}
```

### 错误处理

- HTTP 层 `throws`，具体见 `enum HTTPError`：`timeout | unauthorized | rateLimited | server(Int) | invalidResponse | missingCredential`。
- 配置 / 凭据加载用 `Optional`，消费方 `guard let` 降级；不用 `Result`。
- `RefreshController.refreshDaily()` 不 `throws`：扫描/聚合异常最终落到 `state.lastDailyError`，但当前主链不主动写该字段（已知差异点）。
- `SelfCheck.run()` 返回 `Int`（0=全部通过，1=有失败）；新加断言用一个闭包 `check(name, cond)`。
- `RefreshController.humanReadable(_:)` 把 `HTTPError` case 映射到中文状态文案，缺省回退 `error.localizedDescription`。

### 状态管理与 DI

- `AppState`（`final class : ObservableObject, @unchecked Sendable`）持有六个 `@Published`：`balance`, `daily`, `lastBalanceError`, `lastDailyError`, `configMissing`, `missingCredential`。**所有修改必须经过 setter**，Setter 都在主线程被调用。
- `RefreshController` 是 `final class, @unchecked Sendable`；`let` 协作对象 + `var intervalSeconds`（由 SwiftUI picker 闭包写回）。
- `StatusBarController` 用 `Set<AnyCancellable>` 收 `@Published`；`Timer` 在 `deinit` 与 `restartTimer()` 中 `invalidate()`。
- DI 通过构造器注入（`CredentialSource`（由 `SettingsStore` 实现）/ `ConfigSource` / `DailyUsageScanner` / `SettingsStore`）。不要引入 Service Locator 或全局单例。

### 命名 / 模板

- 类型命名沿用值类型优先（`struct BalanceResult` / `TokenStats` / `HourBucket` / `DailyUsageSnapshot`），行为/纯函数走 `enum SomeName` 单例（如 `BalanceRegistry` / `SelfCheck` / `CompactFormatter` / `BalanceFormatter` / `HourlyAggregator`）。
- 所有跨任务类型 `Sendable`；跨线程持有者用 `@unchecked Sendable` + 命名 setter。
- Provider id 派生：`BalanceRegistry.providerID(fromDefaultModel:)` 取第一段 `/` 之前小写 → `.deepseek | .minimax | .minimaxCodeCN | .unknown`。

### 日志 / 文案 / 状态栏标题

- 错误降级文案集中在 `BalanceFormatter.statusBarText` + `RefreshController.humanReadable(_:)`；新增错误显示分支请优先复用这两条路径。
- 状态栏标题优先级（`StatusBarController.updateTitle`）：`missingCredential > configMissing > balance > "···"`。
- 时间格式 `BalanceFormatter.formatHMS(_:)`：0 / `MM:SS` / `H:MM:SS`，状态栏倒计时专用。

### 添加 Provider / Provider 字段

1. 在 `ProviderID` 加 `case`（`CaseIterable, Sendable`）。
2. `Balance/Providers.swift` 加新 `struct XxxProvider: BalanceProvider`；实现 `hasCredential(creds: any CredentialSource) -> Bool` + `fetch(creds: any CredentialSource, http:) async throws -> BalanceResult`。凭据来源经由 `CredentialSource`（由 `SettingsStore` 实现，偏好面板），不再读 `.env`。
3. 在 `BalanceRegistry.all()` 注册；在 `providerID(fromDefaultModel:)` 补路由分支。
4. `SelfCheck` 里加 provider 路由断言（按已有 `.unknown` 分支模式）。

### 进度条 / 时段桶不变量

- 12 个 `HourBucket`，索引 0 最旧、末位最新，区间左开右闭 `(startMs, endMs]`。
- 末桶完整 1 小时；事件 `tsMs < todayStartMs` 直接丢（不算"今日"，不进时段桶）。
- dedupe key 形如 `"\(relPath):\(eventId)"`，**不要** 改成其它样式，否则会和去重语义冲突。

## Important Files

| 文件 | 角色 |
|---|---|
| `Package.swift` | SwiftPM 入口；Swift 5.9；macOS `.v13`；唯一外部依赖 `Yams 5.1+`（实际 5.4.0）；`executableTarget` 路径 `Sources/omp-companion` |
| `Package.resolved` | 锁定 Yams 5.4.0；commit 时不要忽略（被 `.gitignore` 列入，可能要回顾） |
| `Makefile` | `build` / `run` / `test` / `clean`，全部 `.PHONY` |
| `build.sh` | 构建 + 拼 `.app` + ad-hoc `codesign --force --deep --sign -` |
| `Resources/Info.plist` | bundle id、版本、`LSUIElement=true` |
| `Sources/omp-companion/App.swift` | 进程入口，DI 在此装配 |
| `Sources/omp-companion/RefreshController.swift` | tick 编排 + `AppState` |
| `Sources/omp-companion/UI/StatusBarController.swift` | 菜单栏 + Timer + Combine |
| `docs/adr/0001` & `docs/adr/0003` & `docs/adr/0004` & `docs/adr/0007` & `docs/adr/0008` | 当前决策（按 README 引用；0002 已弃；0006 被 0007 取代） |

## Runtime / Tooling Preferences

- **运行时**：macOS 13.0+；Apple Silicon / Intel 均可。系统无 Bun / Node 依赖。
- **构建工具**：SwiftPM 5.9（`swift build`）+ bash。`xcodebuild` 不需要。
- **包管理器**：SwiftPM（`Package.swift`）；不要新增 Conan / CocoaPods / Carthage。
- **签发**：仅本机 ad-hoc（`codesign --force --deep --sign -`），**不做 Developer ID 公证**，不在 release 流程加。
- **代码签名约束**：不要新增 `LaunchAgent plist`、不要在仓库里写 `~/Library/LaunchAgents/*.plist`。
- **凭据**：provider API key（DeepSeek / MiniMax×2 / OpenCode Go）与 ccccapi（邮箱/密码）均经 `SettingsStore` 偏好面板配置、存 UserDefaults 明文；**不读 `.env`、不读 Keychain**（ADR-0008 / ADR-0007）。
- **安全**：provider 请求走 `URLSession.shared`，未配 `NSAppTransportSecurity` 例外；新增端点必须 HTTPS。

## Testing & QA

- **测试方式**：SwiftPM 当前 `executableTarget` 缺 XCTest / Swift Testing 模块，测试以 **`SelfCheck` 进程级断言**形式存在，由 `--self-check` 调用（`swift run omp-companion --self-check`）。`make test` 等价同命令。
- **新增断言**：在 `SelfCheck.run()` 内追加 `do { check("...", cond) }` 块，纯函数 + `Bool` 条件；不要引入 XCTest。生产环境迁移 XCTest 时再移除 `SelfCheck`。
- **覆盖范围**（自检保证）：`TokenStats` 派生（含 cache-hit 0 除法）、`CompactFormatter`（K/M/B + `999_500 → 1.0M`）、`BalanceFormatter`（CNY `¥12.50` / percent 含与不含 `resetRemaining` / `formatHMS` 边界）、`HourlyAggregator`（今日聚合、桶归属、`todayStartMs` 之前事件丢弃）、`JSONLLineParser`（assistant → 带 `dedupeKey`，user → `nil`）、`BalanceRegistry.providerID(...)` 路由。
- **退出码**：0 = 全部通过，输出 `[self-check] OK (全部通过)`；1 = 任意失败，输出 `[self-check] FAIL (N):` + 每条失败 label。
- **发布前必跑**：

```bash
swift build -c release && \
swift run omp-companion --self-check   # 期望 [self-check] OK (全部通过)
./build.sh                              # 出 build/omp-companion.app
```

- **手动烟测**：`open build/omp-companion.app` 后看菜单栏标题是否渲染为余额 / `¥X.XX` / `X%: YhYm`；触发"立即刷新"是否即时重抓；偏好面板切换刷新档位是否在 ~1 个 tick 内生效。
- **不要**靠 unit test 覆盖率衡量进度；PR 当前靠 `SelfCheck` + 人工菜单栏检查。

## 与上游决策保持一致（提交前对照）

1. 没有新增任何对 `~/Library/Caches/<bundle-id>/` 下的写盘逻辑（ADR-0004）。
2. 没有引入 `XDG_CACHE_HOME` / `ProcessInfo.processInfo.environment["XDG_*"]` 类代理路径。
3. 没有 fork 上游 omp CLI；新端点必须以 Swift `BalanceProvider` 协议实现。
4. 没有为了"实时性"读取 runtime env override（ADR-0001）。
5. `SelfCheck.run()` 通过、`build.sh` 成功、`build/omp-companion.app` ad-hoc 签名通过 `codesign -dv` 校验。
6. 没有从 `.env` 读取 provider 凭据（ADR-0008）；凭据一律经 `SettingsStore` 偏好面板。
