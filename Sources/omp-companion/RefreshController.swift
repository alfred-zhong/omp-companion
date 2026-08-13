import Foundation
import Combine

/// 状态机：菜单栏所需的两路快照 + 阻止系统休眠会话。
public final class AppState: ObservableObject, @unchecked Sendable {
    @Published public private(set) var balance: BalanceSnapshot?
    @Published public private(set) var daily: DailyUsageSnapshot?
    @Published public private(set) var lastBalanceError: String?
    @Published public private(set) var lastDailyError: String?
    @Published public private(set) var configMissing: Bool = false
    @Published public private(set) var missingCredential: String?
    @Published public private(set) var caffeinateSession: CaffeinateSession?
    /// 1 秒一次推进的时间戳；UI 订阅它以重绘倒计时。
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

/// 定时刷新：每次 tick 直接执行一次逻辑，无本地缓存。
public final class RefreshController: @unchecked Sendable {
    public let config: ConfigSource
    public let creds: CredentialsResolver
    public let scanner: DailyUsageScanner
    public let aggregator: HourlyAggregator
    public let http: HTTPClient
    public let state: AppState
    public var intervalSeconds: TimeInterval

    public init(
        config: ConfigSource,
        creds: CredentialsResolver,
        scanner: DailyUsageScanner,
        aggregator: HourlyAggregator = HourlyAggregator(),
        http: HTTPClient = URLSessionHTTPClient(),
        state: AppState,
        intervalSeconds: TimeInterval = 60
    ) {
        self.config = config
        self.creds = creds
        self.scanner = scanner
        self.aggregator = aggregator
        self.http = http
        self.state = state
        self.intervalSeconds = intervalSeconds
    }

    public func tick() async {
        await refreshBalance()
        await refreshDaily()
    }

    public func refreshBalance() async {
        let cfg = config.load()
        guard let defaultModel = cfg.defaultModel, !defaultModel.isEmpty else {
            await MainActor.run { state.setConfigMissing(true) }
            return
        }
        await MainActor.run { state.setConfigMissing(false) }
        let pid = BalanceRegistry.providerID(fromDefaultModel: defaultModel)
        guard let provider = BalanceRegistry.provider(for: pid) else {
            await MainActor.run {
                state.setBalanceError("未匹配到服务商（\(defaultModel)）")
                state.setMissingCredential(nil)
            }
            return
        }
        guard provider.hasCredential(creds: creds) else {
            await MainActor.run {
                state.setMissingCredential("\(pid.rawValue) 凭据缺失")
            }
            return
        }
        await MainActor.run { state.setMissingCredential(nil) }

        do {
            let result = try await provider.fetch(creds: creds, http: http)
            let snap = BalanceSnapshot(result: result, capturedAt: Date())
            await MainActor.run {
                state.setBalance(snap)
                state.setBalanceError(nil)
            }
        } catch {
            await MainActor.run {
                state.setBalanceError(humanReadable(error))
            }
        }
    }

    public func refreshDaily() async {
        let now = Date()
        let events = scanner.scan(now: now)
        let todayStartMs = scanner.todayStartMs(now: now)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let snapshot = aggregator.aggregate(events: events, nowMs: nowMs, todayStartMs: todayStartMs)
        await MainActor.run {
            state.setDaily(snapshot)
            state.setDailyError(nil)
        }
    }

    private func humanReadable(_ error: Error) -> String {
        if let http = error as? HTTPError {
            switch http {
            case .timeout: return "请求超时 (10 秒)"
            case .unauthorized: return "鉴权失败 (401)"
            case .rateLimited: return "请求过快 (429)"
            case .server(let s): return "服务异常 (\(s))"
            case .invalidResponse: return "响应解析失败"
            case .missingCredential: return "凭据缺失"
            }
        }
        return error.localizedDescription
    }
}
