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
模型服务商或订阅网关（DeepSeek、MiniMax Token Plan、MiniMax Coding Plan、OpenCode Go、ccccapi 等）；每个 Provider 暴露一个查询余额/配额的 REST 端点与一种鉴权凭据。OpenCode Go 是订阅网关：前端多家模型厂商，返回的是额度窗口已用百分比而非货币余额；ccccapi 是账户网关，返回用户账户 USD 余额。
_Avoid_: 服务商、模型提供方、平台

**Account Balance**:
ccccapi 用户账户的 USD 余额；只读取 `data.balance`，不等同于模型 API Key 额度、token 用量或用户身份资料。
_Avoid_: API key 余额、账户资料、额度用量

**Ccccapi Access Token**:
ccccapi 网页会话 access token；从 `.env` 链的 `CCCAPI_ACCESS_TOKEN` 读取，空白值视为缺失，不在本地保存完整响应或打印 token。
_Avoid_: API key、模型密钥

**Quota Window**:
OpenCode Go 订阅的额度窗口：5 小时滚动 / 7 天 / 月度（订阅周年重置）；每窗口由已用百分比（0–100 整数）、状态（正常 / 已限流）、重置时刻组成。状态栏展示 5h 窗口，下拉菜单列出全部窗口。
_Avoid_: 配额、额度段、时段


**Snapshot**:
一次"瞬时"数据采集结果：{ provider, balance, currency?, used?, reset_remaining?, capturedAt }；是状态栏图标文案与弹出菜单的最小可显示单元。
_Avoid_: 取样、点查、读数

**Default Model**:
omp 配置中的 `modelRoles.default`（如 `deepseek/deepseek-v4-flash:high`）；通过合并 `~/.omp/agent/config.yml` 与项目 `<cwd>/.omp/config.yml` 后读取，是 Provider 路由的依据；runtime 覆盖（`--model` / `--smol` / env vars）不可见。
_Avoid_: 当前模型、选中模型、会话模型、运行时模型

**Unmatched Provider**:
去除首尾空白后，首个 `/` 两侧皆非空的 Default Model 中，未映射到受支持 Provider 的原始前缀；其余内容是模型标识。没有可查询的余额 Snapshot。状态栏显示该前缀，下拉菜单首行显示 `Provider (Model)`，随后明确余额查询暂不支持。
_Avoid_: 未知服务商、兜底服务商

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