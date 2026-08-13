# omp-companion

macOS 菜单栏常驻 app，聚合展示 omp 当前所用模型的余额与当日 / 近 5h token 消耗。

## Language

**Menu Bar App**:
常驻 macOS 右上角菜单栏的轻量 GUI 程序；用户与界面只通过顶部状态栏图标和弹出菜单交互，无 Dock 图标、无主窗口。
_Avoid_: 状态栏 app、状态栏小工具、系统托盘 app

**Status Item**:
NSStatusItem 在系统菜单栏中占据的一个槽位及其图标；omp-companion 只占用一个槽位。
_Avoid_: 状态栏图标、状态栏 entry

**Provider**:
模型服务商（DeepSeek、MiniMax Token Plan、MiniMax Coding Plan 等）；每个 Provider 暴露一个查询余额的 REST 端点与一种鉴权凭据。
_Avoid_: 服务商、模型提供方、平台


**Snapshot**:
一次"瞬时"数据采集结果：{ provider, balance, currency?, used?, reset_remaining?, capturedAt }；是状态栏图标文案与弹出菜单的最小可显示单元。
_Avoid_: 取样、点查、读数

**Default Model**:
omp 配置中的 `modelRoles.default`（如 `deepseek/deepseek-v4-flash:high`）；通过合并 `~/.omp/agent/config.yml` 与项目 `<cwd>/.omp/config.yml` 后读取，是 Provider 路由的依据；runtime 覆盖（`--model` / `--smol` / env vars）不可见。
_Avoid_: 当前模型、选中模型、会话模型、运行时模型

**Daily Usage**:
当日（本地零点至此刻）omp 全部会话的 token 聚合：{ input, output, cacheCreation, cacheRead, totalInput, realConsumption, messageCount, cacheHitRate }；以单条助手消息的 timestamp 归属，不按会话归属。
_Avoid_: 今天用量、今日统计

**Hourly Bucket**:
以当前时刻为右端、向前 1h 为步长切出的滑动区间，索引 0 最旧、末位最新；共 12 桶；区间左开右闭 `(startMs, endMs]`；不对齐钟点；末桶永远是完整一小时。
_Avoid_: 小时柱、时段桶

**Real Consumption**:
真实消耗 token 数 = 总输入 + 输出 = input + output + cacheCreation + cacheRead；柱图按它归一化。
_Avoid_: 合计、总 token、总消耗

 **Refresh**:
 按固定 interval（默认 60s）重新调用两个数据源并刷新 UI 的周期操作；每次刷新都直接执行查询 / 扫描逻辑，无本地缓存。
 _Avoid_: 轮询、拉取

**Sleep Guard**:
基于 IOPMAssertion 的「阻止系统睡眠」守护模块；同一时刻只维护一个 Caffeinate Session，到期或 cancel() 即释放。不持久化；进程退出静默释放。
_Avoid_: 防休眠、Keep Awake

**Caffeinate Session**:
一次 IOPMAssertion 守护实例：{ bucket, startedAt, endAt }；被 AppState.caffeinateSession 暴露；UI 据此在弹出菜单顶部显示「还剩 Xm/Xs」倒计时。
_Avoid_: 守护任务、唤醒锁

**Caffeinate Bucket**:
阻止休眠的预设档位集合：`{30, 60, 120}` 分钟；菜单子菜单列出全部档位，当前生效档位标 ✓。区别于 Daily Usage 里的 Hourly Bucket。
_Avoid_: 时长档