import Foundation
import Combine

/// 状态机:菜单栏所需的两路快照 + 阻止系统休眠会话。
public final class AppState: ObservableObject, @unchecked Sendable {
    @Published public private(set) var balance: BalanceSnapshot?
    /// 已执行余额请求但未取得可信余额时（任何 provider）的显式失败状态。
    @Published public private(set) var balanceUnavailableFor: ProviderID?
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

    /// 一次写入完整 Balance Refresh Outcome；余额字段的同步细节不泄漏给 RefreshController。
    public func applyBalance(_ outcome: BalanceRefreshOutcome) {
        self.balance = outcome.balance
        self.balanceUnavailableFor = outcome.balanceUnavailableFor
        self.lastBalanceError = outcome.lastBalanceError
        self.configMissing = outcome.configMissing
        self.missingCredential = outcome.missingCredential
        self.currentModel = outcome.currentModel
        self.currentProvider = outcome.currentProvider
        self.unmatchedProvider = outcome.unmatchedProvider
    }

    public func setDaily(_ snap: DailyUsageSnapshot?) { self.daily = snap }
    public func setDailyError(_ msg: String?) { self.lastDailyError = msg }
    public func setCaffeinateSession(_ s: CaffeinateSession?) { self.caffeinateSession = s }
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
        let balanceCapture = await balanceSource.capture(now: Date())
        let dailyCapture = await dailySource.capture(now: Date())
        await MainActor.run {
            self.state.applyBalance(self.balanceOutcome(for: balanceCapture))
            self.applyDaily(snap: dailyCapture.0, err: dailyCapture.1)
        }
    }

    public func refreshBalance() async {
        let capture = await balanceSource.capture(now: Date())
        await MainActor.run {
            self.state.applyBalance(self.balanceOutcome(for: capture))
        }
    }

    public func refreshDaily() async {
        let (snap, err) = await dailySource.capture(now: Date())
        await MainActor.run {
            self.applyDaily(snap: snap, err: err)
        }
    }


    private func balanceOutcome(for capture: BalanceCapture) -> BalanceRefreshOutcome {
        var configMissing = false
        var missingCredential: String?
        var unmatchedProvider = state.unmatchedProvider
        var lastBalanceError: String?
        var balanceUnavailableFor: ProviderID?
        var currentProvider = state.currentProvider

        switch capture.error {
        case .configMissing:
            configMissing = true
            unmatchedProvider = nil
            currentProvider = nil
        case .unmatchedProvider(let name):
            unmatchedProvider = name
            currentProvider = .unknown
        case .missingCredential(let key):
            missingCredential = "\(key) 凭据缺失"
            unmatchedProvider = nil
            currentProvider = ProviderID(rawLowercased: key)
        case .fetchError(let reason):
            lastBalanceError = reason
            let failedProvider = capture.model.map { BalanceRegistry.providerID(fromDefaultModel: $0) }
            unmatchedProvider = nil
            if let failedProvider, failedProvider != .unknown {
                balanceUnavailableFor = failedProvider
                currentProvider = failedProvider
            }
        case .scanError, nil:
            break
        }

        let balance: BalanceSnapshot?
        if case .fetchError = capture.error, capture.snapshot == nil {
            if balanceUnavailableFor != nil {
                balance = nil
            } else if let old = state.balance {
                balance = BalanceSnapshot(
                    result: old.result,
                    capturedAt: old.capturedAt,
                    isStale: true,
                    quotaWindows: old.quotaWindows
                )
            } else {
                balance = nil
            }
        } else {
            balance = capture.snapshot
        }
        if let balance, !balance.isStale {
            currentProvider = balance.result.provider
        }

        return BalanceRefreshOutcome(
            balance: balance,
            balanceUnavailableFor: balanceUnavailableFor,
            lastBalanceError: lastBalanceError,
            configMissing: configMissing,
            missingCredential: missingCredential,
            currentModel: capture.model,
            currentProvider: currentProvider,
            unmatchedProvider: unmatchedProvider
        )
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
