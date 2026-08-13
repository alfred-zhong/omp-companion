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
    @Published public private(set) var caffeinateSession: CaffeinateSession?
    /// 1 秒一次推进的时间戳;UI 订阅它以重绘倒计时。
    @Published public private(set) var countdownTick: Date = .distantPast

    public init() {}

    public func setBalance(_ snap: BalanceSnapshot?) { self.balance = snap }
    public func setDaily(_ snap: DailyUsageSnapshot?) { self.daily = snap }
    public func setBalanceError(_ msg: String?) { self.lastBalanceError = msg }
    public func setDailyError(_ msg: String?) { self.lastDailyError = msg }
    public func setConfigMissing(_ v: Bool) { self.configMissing = v }
    public func setMissingCredential(_ v: String?) { self.missingCredential = v }
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
        let bs = await balanceSource.capture(now: Date())
        let ds = await dailySource.capture(now: Date())
        await MainActor.run {
            self.applyBalance(snap: bs.0, err: bs.1)
            self.applyDaily(snap: ds.0, err: ds.1)
        }
    }

    public func refreshBalance() async {
        let (snap, err) = await balanceSource.capture(now: Date())
        await MainActor.run {
            self.applyBalance(snap: snap, err: err)
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
        dailySnap: DailyUsageSnapshot?, dailyErr: SnapshotError?
    ) {
        self.applyBalance(snap: balanceSnap, err: balanceErr)
        self.applyDaily(snap: dailySnap, err: dailyErr)
    }

    private func applyBalance(snap: BalanceSnapshot?, err: SnapshotError?) {
        switch err {
        case .configMissing:
            self.state.setConfigMissing(true)
        case .missingCredential(let key):
            self.state.setConfigMissing(false)
            self.state.setMissingCredential("\(key) 凭据缺失")
        case .fetchError(let reason):
            self.state.setConfigMissing(false)
            self.state.setMissingCredential(nil)
            self.state.setBalanceError(reason)
        case .scanError, nil:
            self.state.setConfigMissing(false)
            self.state.setMissingCredential(nil)
            self.state.setBalanceError(nil)
        }
        self.state.setBalance(snap)
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
