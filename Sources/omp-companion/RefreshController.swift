import Foundation
import Combine

/// 状态机:菜单栏所需的两路快照 + 阻止系统休眠会话。
public final class AppState: ObservableObject, @unchecked Sendable {
    @Published public private(set) var balance: BalanceSnapshot?
    @Published public private(set) var daily: DailyUsageSnapshot?
    @Published public private(set) var lastBalanceError: String?
    @Published public private(set) var lastDailyError: String?
    @Published public private(set) var configMissing: Bool = false
    @Published public private(set) var missingCredential: String?
    /// 当前 config.yml 默认模型名（defaultModel 原始串，如 "deepseek/deepseek-chat"）。
    /// 仅来自 config，不读 runtime 覆盖（ADR-0001）；菜单首行展示，渲染时只取 "/" 之后。
    /// 缺配置时为 nil → 菜单显示 "?"。
    @Published public private(set) var currentModel: String?
    @Published public private(set) var caffeinateSession: CaffeinateSession?
    /// 当前选中的供应商 id（每次 fetch 后由 RefreshController 从 BalanceSnapshot 写入）；
    /// 状态栏用它查 LogoCatalog 渲染 NSStatusItem 的 image。
    @Published public private(set) var currentProvider: ProviderID?
    /// Default Model 中未映射到受支持 Provider 的原始前缀；仅未匹配保底展示时有值。
    @Published public private(set) var unmatchedProvider: String?
    /// 1 秒一次推进的时间戳;UI 订阅它以重绘倒计时。
    @Published public private(set) var countdownTick: Date = .distantPast

    public init() {}

    public func setBalance(_ snap: BalanceSnapshot?) { self.balance = snap }
    public func setDaily(_ snap: DailyUsageSnapshot?) { self.daily = snap }
    public func setBalanceError(_ msg: String?) { self.lastBalanceError = msg }
    public func setDailyError(_ msg: String?) { self.lastDailyError = msg }
    public func setConfigMissing(_ v: Bool) { self.configMissing = v }
    public func setMissingCredential(_ v: String?) { self.missingCredential = v }
    public func setCurrentModel(_ m: String?) { self.currentModel = m }
    public func setCaffeinateSession(_ s: CaffeinateSession?) { self.caffeinateSession = s }
    public func setCurrentProvider(_ p: ProviderID?) { self.currentProvider = p }
    public func setUnmatchedProvider(_ p: String?) { self.unmatchedProvider = p }
    public func advanceCountdownTick() { self.countdownTick = Date() }
}

/// 定时刷新编排:每次 tick 从两个 Source 抓快照,根据 SnapshotError 落 AppState。
/// 抓取细节(config / creds / http / scanner / aggregate)由 Source 实现封进。
public final class RefreshController: @unchecked Sendable {
    public let balanceSource: BalanceSource
    public let dailySource: DailyUsageSource
    public let state: AppState
    public var intervalSeconds: TimeInterval

    public init(
        balanceSource: BalanceSource,
        dailySource: DailyUsageSource,
        state: AppState,
        intervalSeconds: TimeInterval = 60
    ) {
        self.balanceSource = balanceSource
        self.dailySource = dailySource
        self.state = state
        self.intervalSeconds = intervalSeconds
    }

    public func tick() async {
        let bs = await balanceSource.capture(now: Date())
        let ds = await dailySource.capture(now: Date())
        await MainActor.run {
            self.applyBalance(snap: bs.0, err: bs.1, model: bs.2)
            self.applyDaily(snap: ds.0, err: ds.1)
        }
    }

    public func refreshBalance() async {
        let (snap, err, model) = await balanceSource.capture(now: Date())
        await MainActor.run {
            self.applyBalance(snap: snap, err: err, model: model)
        }
    }

    public func refreshDaily() async {
        let (snap, err) = await dailySource.capture(now: Date())
        await MainActor.run {
            self.applyDaily(snap: snap, err: err)
        }
    }

    /// 同步入口:不抓 source,直接用 caller 提供的 (snap, err) 对调 setter。
    /// 给 SelfCheck 用来在不依赖 main runloop / detached task 的情况下验证应用逻辑。
    public func apply(
        balanceSnap: BalanceSnapshot?, balanceErr: SnapshotError?,
        balanceModel: String? = nil,
        dailySnap: DailyUsageSnapshot?, dailyErr: SnapshotError?
    ) {
        self.applyBalance(snap: balanceSnap, err: balanceErr, model: balanceModel)
        self.applyDaily(snap: dailySnap, err: dailyErr)
    }
    private func applyBalance(snap: BalanceSnapshot?, err: SnapshotError?, model: String?) {
        // 模型名来自 config，与 fetch 成败无关：每个 tick 无条件回填（缺配置时为 nil → 菜单 "?"）。
        self.state.setCurrentModel(model)
        switch err {
        case .configMissing:
            self.state.setConfigMissing(true)
            self.state.setMissingCredential(nil)
            self.state.setUnmatchedProvider(nil)
            self.state.setCurrentProvider(nil)
        case .unmatchedProvider(let name):
            self.state.setConfigMissing(false)
            self.state.setMissingCredential(nil)
            self.state.setBalanceError(nil)
            self.state.setUnmatchedProvider(name)
            self.state.setCurrentProvider(.unknown)
        case .missingCredential(let key):
            self.state.setConfigMissing(false)
            self.state.setUnmatchedProvider(nil)
            self.state.setMissingCredential("\(key) 凭据缺失")
            // 即使没拉到余额,凭据缺失这个消息本身也含 provider id —— 把它回填一次,
            // 这样状态栏从 "···" 立刻转到对应 logo + 警示文本,而不是先空白再二次刷新。
            self.state.setCurrentProvider(ProviderID(rawLowercased: key))
        case .fetchError(let reason):
            self.state.setConfigMissing(false)
            self.state.setMissingCredential(nil)
            self.state.setUnmatchedProvider(nil)
            self.state.setBalanceError(reason)
            // 远端错误：保留上一轮 provider,避免界面跳回 '?' 默认图。
        case .scanError, nil:
            self.state.setConfigMissing(false)
            self.state.setMissingCredential(nil)
            self.state.setUnmatchedProvider(nil)
            self.state.setBalanceError(nil)
        }
        self.state.setBalance(snap)
        // 成功 fetch 后从 snapshot 派生 currentProvider。
        if snap != nil { self.state.setCurrentProvider(snap?.result.provider) }
    }

    private func applyDaily(snap: DailyUsageSnapshot?, err: SnapshotError?) {
        self.state.setDaily(snap)
        if case .scanError(let reason) = err {
            self.state.setDailyError(reason)
        } else {
            self.state.setDailyError(nil)
        }
    }
}
