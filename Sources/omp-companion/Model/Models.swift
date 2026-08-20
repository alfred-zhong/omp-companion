import Foundation

// MARK: - Provider

/// 模型服务商或订阅网关。
public enum ProviderID: String, CaseIterable, Sendable {
    case deepseek
    case minimax
    case minimaxCodeCN = "minimax-code-cn"
    case opencodeGo = "opencode-go"
    case unknown

    public init(rawLowercased: String) {
        self = ProviderID(rawValue: rawLowercased) ?? .unknown
    }

    /// 面向用户的展示名（菜单余额行等）。
    public var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .minimax: return "MiniMax"
        case .minimaxCodeCN: return "MiniMax Coding Plan CN"
        case .opencodeGo: return "OpenCode Go"
        case .unknown: return "未知"
        }
    }
}

// MARK: - Balance

/// 余额查询结果。
public struct BalanceResult: Equatable, Sendable {
    public let provider: ProviderID
    public let balance: Double
    public let currency: BalanceCurrency
    public let usedPercent: Double?
    public let resetRemaining: TimeInterval?
    /// 额度窗口：OpenCode Go 三窗口 / MiniMax interval 窗口；其它 provider 为 nil。
    public let quotaWindows: [QuotaWindow]?

    public init(
        provider: ProviderID,
        balance: Double,
        currency: BalanceCurrency,
        usedPercent: Double? = nil,
        resetRemaining: TimeInterval? = nil,
        quotaWindows: [QuotaWindow]? = nil
    ) {
        self.provider = provider
        self.balance = balance
        self.currency = currency
        self.usedPercent = usedPercent
        self.resetRemaining = resetRemaining
        self.quotaWindows = quotaWindows
    }
}

public enum BalanceCurrency: String, Sendable {
    case cny = "CNY"
    case percent = "PERCENT"
}

/// 一次余额数据采集快照。
public struct BalanceSnapshot: Sendable {
    public let result: BalanceResult
    public let capturedAt: Date
    public let isStale: Bool
    /// OpenCode Go 三窗口配额明细（由 result.quotaWindows 透传）；其它 provider 为 nil。
    public let quotaWindows: [QuotaWindow]?

    public init(
        result: BalanceResult,
        capturedAt: Date,
        isStale: Bool = false,
        quotaWindows: [QuotaWindow]? = nil
    ) {
        self.result = result
        self.capturedAt = capturedAt
        self.isStale = isStale
        self.quotaWindows = quotaWindows
    }
}

// MARK: - Quota Window (OpenCode Go)

/// OpenCode Go 额度窗口状态（服务端原样）：`"ok"` 正常，`"rate-limited"` 已限流。
public enum QuotaWindowStatus: String, Equatable, Sendable {
    case ok
    case rateLimited = "rate-limited"
}

/// 一个额度窗口：OpenCode Go 的 5h 滚动 / 7d / 月度（订阅周年重置），
/// 或 MiniMax 的 interval 滚动窗口（时长随套餐变化）。
public struct QuotaWindow: Equatable, Sendable {
    /// 窗口标识：OpenCode Go `"5h"` | `"7d"` | `"monthly"`；MiniMax 为推导标签（如 `"5h"`）。
    public let id: String
    /// 展示名：`"5h"` | `"7d"` | `"月度"`；MiniMax 与 id 同值。
    public let label: String
    /// 已用百分比（0-100，服务端原样，展示层不换算）。
    public let usedPercent: Int
    public let status: QuotaWindowStatus
    /// 服务端下发的重置时刻（ISO）。
    public let resetsAt: Date

    public init(
        id: String,
        label: String,
        usedPercent: Int,
        status: QuotaWindowStatus,
        resetsAt: Date
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.status = status
        self.resetsAt = resetsAt
    }
}

// MARK: - Daily Usage

/// 当日 / 单小时桶的 token 聚合。
public struct TokenStats: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var totalInputTokens: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }

    public var realConsumptionTokens: Int {
        totalInputTokens + outputTokens
    }

    public var cacheHitRate: Double {
        guard totalInputTokens > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(totalInputTokens)
    }

    public static func += (lhs: inout TokenStats, rhs: TokenStats) {
        lhs.inputTokens += rhs.inputTokens
        lhs.outputTokens += rhs.outputTokens
        lhs.cacheCreationTokens += rhs.cacheCreationTokens
        lhs.cacheReadTokens += rhs.cacheReadTokens
    }
}

/// 单小时滑动桶。
public struct HourBucket: Equatable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public var stats: TokenStats

    public init(startMs: Int64, endMs: Int64, stats: TokenStats = TokenStats()) {
        self.startMs = startMs
        self.endMs = endMs
        self.stats = stats
    }
}

 /// 日用量快照。
 public struct DailyUsageSnapshot: Sendable {
    public let today: TokenStats
    public let hourly: [HourBucket]   // 长度 12，index 0 最旧，末位最新
    public let messageCount: Int
    public let capturedAt: Date

    public init(today: TokenStats, hourly: [HourBucket], messageCount: Int, capturedAt: Date) {
        self.today = today
        self.hourly = hourly
        self.messageCount = messageCount
        self.capturedAt = capturedAt
    }

    /// 后 5 个小时桶的并集，等价于 `[now-5h, now]`。
    public var last5h: TokenStats {
        var sum = TokenStats()
        for bucket in hourly.suffix(5) {
            sum += bucket.stats
        }
        return sum
     }
 }

// MARK: - Caffeinate (阻止系统休眠)

/// 阻止系统休眠的预设档位。
public enum CaffeinateBucket: Int, CaseIterable, Sendable {
    case thirtyMinutes  = 30
    case sixtyMinutes   = 60
    case oneTwentyMinutes = 120

    public var minutes: Int { rawValue }
    public var label: String { "\(rawValue) 分钟" }

    public static let `default`: CaffeinateBucket = .sixtyMinutes
}

/// 一次 IOPMAssertion 守护会话。
public struct CaffeinateSession: Equatable, Sendable {
    public let bucket: CaffeinateBucket
    public let startedAt: Date
    public let endAt: Date

    public init(bucket: CaffeinateBucket, startedAt: Date, endAt: Date) {
        self.bucket = bucket
        self.startedAt = startedAt
        self.endAt = endAt
    }

    /// 现在到 endAt 的剩余秒数；负数或 0 表示已到期。
    public func remainingSeconds(now: Date) -> TimeInterval {
        endAt.timeIntervalSince(now)
    }

    public func isActive(now: Date) -> Bool {
        endAt > now
    }
}

// MARK: - RefreshInterval (刷新间隔)

/// 偏好面板的刷新间隔档位：固定三档，默认 60s。
public enum RefreshInterval: Int, CaseIterable, Sendable {
    case seconds30  = 30
    case seconds60  = 60
    case seconds120 = 120

    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public static let `default`: RefreshInterval = .seconds60
}
