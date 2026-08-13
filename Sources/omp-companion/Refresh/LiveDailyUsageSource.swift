import Foundation

/// 生产 DailyUsageSource:持有 DailyUsageScanner + HourlyAggregator。
public struct LiveDailyUsageSource: DailyUsageSource {
    public let scanner: DailyUsageScanner
    public let aggregator: HourlyAggregator

    public init(scanner: DailyUsageScanner, aggregator: HourlyAggregator = HourlyAggregator()) {
        self.scanner = scanner
        self.aggregator = aggregator
    }

    public func capture(now: Date) async -> (DailyUsageSnapshot?, SnapshotError?) {
        let events = scanner.scan(now: now)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let todayStartMs = scanner.todayStartMs(now: now)
        let snapshot = aggregator.aggregate(events: events, nowMs: nowMs, todayStartMs: todayStartMs)
        return (snapshot, nil)
    }
}
