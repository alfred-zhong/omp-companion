import Foundation

/// 一次 Snapshot 抓取的非致命结果。`nil` 表示成功且有数据;`.some` 表示"明确的状态信号"。
///
/// RefreshController 看到这个枚举后决定写 AppState 的哪个 `@Published` 字段。
public enum SnapshotError: Error, Sendable, Equatable {
    /// 配置文件 / defaultModel 缺失 → AppState.setConfigMissing(true)
    case configMissing
    /// 鉴权失败 / 缺 API key → AppState.setMissingCredential(key)
    case missingCredential(String)
    /// 远端错误,reason 已是 human-readable 中文 → AppState.setBalanceError(reason)
    case fetchError(String)
    /// 扫 / 聚 / 解析失败 → AppState.setDailyError(reason)
    case scanError(String)
}

/// BalanceSource:对 RefreshController 暴露的"一次余额抓取"最小 seam。
///
/// 把 config 读取 + 凭据解析 + provider 路由 + HTTP + 错误文本化都封在实现里。
/// RefreshController 只看到 `(BalanceSnapshot?, SnapshotError?)`。
public protocol BalanceSource: Sendable {
    func capture(now: Date) async -> (BalanceSnapshot?, SnapshotError?)
}

/// DailyUsageSource:对 RefreshController 暴露的"一次日用量聚合"最小 seam。
public protocol DailyUsageSource: Sendable {
    func capture(now: Date) async -> (DailyUsageSnapshot?, SnapshotError?)
}
