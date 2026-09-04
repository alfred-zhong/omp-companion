import Foundation

/// 一次 Snapshot 抓取的非致命结果。`nil` 表示成功且有数据;`.some` 表示"明确的状态信号"。
///
/// RefreshController 看到这个枚举后决定写 AppState 的哪个 `@Published` 字段。
public enum SnapshotError: Error, Sendable, Equatable {
    /// 配置文件 / defaultModel 缺失 → AppState.setConfigMissing(true)
    case configMissing
    /// Default Model 格式正确但 Provider 未受支持 → 不查余额，保留 Provider 展示。
    case unmatchedProvider(String)
    /// 鉴权失败 / 缺 API key → AppState.setMissingCredential(key)
    case missingCredential(String)
    /// 远端错误,reason 已是 human-readable 中文 → AppState.setBalanceError(reason)
    case fetchError(String)
    /// 扫 / 聚 / 解析失败 → AppState.setDailyError(reason)
    case scanError(String)
}
/// 一次余额采集事实。BalanceSource 只负责采集，不决定状态迁移。
public struct BalanceCapture: Sendable {
    public let snapshot: BalanceSnapshot?
    public let error: SnapshotError?
    public let model: String?

    public init(snapshot: BalanceSnapshot?, error: SnapshotError?, model: String?) {
        self.snapshot = snapshot
        self.error = error
        self.model = model
    }
}

/// BalanceSource：对 RefreshController 暴露的一次余额采集 seam。
///
/// 把 config 读取 + 凭据解析 + provider 路由 + HTTP + 错误文本化都封在实现里。
public protocol BalanceSource: Sendable {
    func capture(now: Date) async -> BalanceCapture
}

/// 一次余额 Refresh 的完整显示状态，由 RefreshController 计算后提交给 AppState。
public struct BalanceRefreshOutcome: Sendable {
    public let balance: BalanceSnapshot?
    public let balanceUnavailableFor: ProviderID?
    public let lastBalanceError: String?
    public let configMissing: Bool
    public let missingCredential: String?
    public let currentModel: String?
    public let currentProvider: ProviderID?
    public let unmatchedProvider: String?

    public init(
        balance: BalanceSnapshot?,
        balanceUnavailableFor: ProviderID?,
        lastBalanceError: String?,
        configMissing: Bool,
        missingCredential: String?,
        currentModel: String?,
        currentProvider: ProviderID?,
        unmatchedProvider: String?
    ) {
        self.balance = balance
        self.balanceUnavailableFor = balanceUnavailableFor
        self.lastBalanceError = lastBalanceError
        self.configMissing = configMissing
        self.missingCredential = missingCredential
        self.currentModel = currentModel
        self.currentProvider = currentProvider
        self.unmatchedProvider = unmatchedProvider
    }
}

/// DailyUsageSource:对 RefreshController 暴露的"一次日用量聚合"最小 seam。
public protocol DailyUsageSource: Sendable {
    func capture(now: Date) async -> (DailyUsageSnapshot?, SnapshotError?)
}
