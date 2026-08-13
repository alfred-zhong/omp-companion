import Foundation

public let HOUR_BUCKET_COUNT = 12
public let HOUR_MS: Int64 = 3600 * 1000

/// 把事件流按当日归属 + 12 滑动小时桶聚合。
public struct HourlyAggregator: Sendable {
    public init() {}

    public func aggregate(events: [ParsedEvent], nowMs: Int64, todayStartMs: Int64) -> DailyUsageSnapshot {
        var hourly: [HourBucket] = (0..<HOUR_BUCKET_COUNT).map { i in
            let endMs = nowMs - Int64(i) * HOUR_MS
            return HourBucket(startMs: endMs - HOUR_MS, endMs: endMs)
        }

        var today = TokenStats()
        var messageCount = 0

        for ev in events {
            // 当日归属：事件 timestamp ≥ 本地零点
            guard ev.tsMs >= todayStartMs else { continue }
            today += TokenStats(
                inputTokens: ev.input,
                outputTokens: ev.output,
                cacheCreationTokens: ev.cacheWrite,
                cacheReadTokens: ev.cacheRead
            )
            messageCount += 1

            // 小时桶归属：hoursAgo ∈ [0, 12)
            let hoursAgo = Double(nowMs - ev.tsMs) / Double(HOUR_MS)
            guard hoursAgo >= 0, hoursAgo < Double(HOUR_BUCKET_COUNT) else { continue }
            let idx = HOUR_BUCKET_COUNT - 1 - Int(floor(hoursAgo))
            guard idx >= 0, idx < hourly.count else { continue }
            hourly[idx].stats += TokenStats(
                inputTokens: ev.input,
                outputTokens: ev.output,
                cacheCreationTokens: ev.cacheWrite,
                cacheReadTokens: ev.cacheRead
            )
        }

        return DailyUsageSnapshot(
            today: today,
            hourly: hourly,
            messageCount: messageCount,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)
        )
    }
}
