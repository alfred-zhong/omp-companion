import Foundation

// MARK: - Provider

/// 模型服务商。
public enum ProviderID: String, CaseIterable, Sendable {
    case deepseek
    case minimax
    case minimaxCodeCN = "minimax-code-cn"
    case unknown

    public init(rawLowercased: String) {
        self = ProviderID(rawValue: rawLowercased) ?? .unknown
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

    public init(
        provider: ProviderID,
        balance: Double,
        currency: BalanceCurrency,
        usedPercent: Double? = nil,
        resetRemaining: TimeInterval? = nil
    ) {
        self.provider = provider
        self.balance = balance
        self.currency = currency
        self.usedPercent = usedPercent
        self.resetRemaining = resetRemaining
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

    public init(result: BalanceResult, capturedAt: Date, isStale: Bool = false) {
        self.result = result
        self.capturedAt = capturedAt
        self.isStale = isStale
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
