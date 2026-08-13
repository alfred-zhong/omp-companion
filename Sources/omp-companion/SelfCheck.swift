import Foundation
import AppKit

/// 自检入口：纯函数断言。`swift run omp-companion --self-check` 调用。
public enum SelfCheck {
    public static func run() -> Int {
        var failures: [String] = []

        func check(_ name: String, _ cond: Bool) {
            if !cond { failures.append(name) }
        }

        // TokenStats
        do {
            let s = TokenStats(inputTokens: 100, outputTokens: 50, cacheCreationTokens: 20, cacheReadTokens: 30)
            check("TokenStats.totalInput", s.totalInputTokens == 150)
            check("TokenStats.realConsumption", s.realConsumptionTokens == 200)
            let s2 = TokenStats(inputTokens: 100, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 400)
            check("TokenStats.cacheHitRate", abs(s2.cacheHitRate - 0.8) < 1e-9)
            check("TokenStats.zeroHit", TokenStats().cacheHitRate == 0)
        }

        // CompactFormatter
        check("Compact.0", CompactFormatter.format(0) == "0")
        check("Compact.999", CompactFormatter.format(999) == "999")
        check("Compact.1K", CompactFormatter.format(1_000) == "1.0K")
        check("Compact.1.5K", CompactFormatter.format(1_500) == "1.5K")
        check("Compact.1M", CompactFormatter.format(1_000_000) == "1.0M")
        check("Compact.2.5M", CompactFormatter.format(2_500_000) == "2.5M")
        check("Compact.1B", CompactFormatter.format(1_000_000_000) == "1.0B")
        check("Compact.rollover", CompactFormatter.format(999_950) == "1.0M")

        // BalanceFormatter
        let cny = BalanceResult(provider: .deepseek, balance: 12.5, currency: .cny)
        check("Balance.CNY", BalanceFormatter.statusBarText(cny) == "¥12.50")
        let pct1 = BalanceResult(provider: .minimaxCodeCN, balance: 92, currency: .percent, usedPercent: 8, resetRemaining: 4 * 3600 + 30 * 60)
        check("Balance.pctWithReset", BalanceFormatter.statusBarText(pct1) == "8%: 4h30m")
        let pct2 = BalanceResult(provider: .minimaxCodeCN, balance: 92, currency: .percent, usedPercent: 8, resetRemaining: nil)
        check("Balance.pctNoReset", BalanceFormatter.statusBarText(pct2) == "8%")
        check("Balance.hms0", BalanceFormatter.formatHMS(0) == "0h0m")
        check("Balance.hms125", BalanceFormatter.formatHMS(125) == "0h2m")
        check("Balance.hms3661", BalanceFormatter.formatHMS(3661) == "1h1m")

        // HourlyAggregator
        do {
            let nowMs: Int64 = 24 * HOUR_MS
            let todayStartMs: Int64 = 0
            let ev1 = ParsedEvent(tsMs: nowMs - HOUR_MS, input: 5, output: 0, cacheRead: 0, cacheWrite: 0, dedupeKey: "a")
            let ev2 = ParsedEvent(tsMs: nowMs - 6 * HOUR_MS, input: 10, output: 0, cacheRead: 0, cacheWrite: 0, dedupeKey: "b")
            let ev3 = ParsedEvent(tsMs: nowMs - 14 * HOUR_MS, input: 100, output: 0, cacheRead: 0, cacheWrite: 0, dedupeKey: "c")
            let ev4 = ParsedEvent(tsMs: -HOUR_MS, input: 999, output: 0, cacheRead: 0, cacheWrite: 0, dedupeKey: "d")
            let events: [ParsedEvent] = [ev1, ev2, ev3, ev4]
            let snap = HourlyAggregator().aggregate(events: events, nowMs: nowMs, todayStartMs: todayStartMs)
            // a=5, b=10, c=100 都在 today（14h ago = 10h，相对 0 仍 ≥ 0）
            // d=-1h 在零点之前，被丢
            check("Agg.todayInput", snap.today.inputTokens == 115)
            check("Agg.msgCount", snap.messageCount == 3)
            // 桶：1h ago → idx = 12-1-1 = 10；6h ago → 12-1-6 = 5；14h ago 不入 12 桶
            check("Agg.bucket10", snap.hourly[10].stats.inputTokens == 5)
            check("Agg.bucket5", snap.hourly[5].stats.inputTokens == 10)
        }

        // JSONLParser
        do {
            let p = JSONLLineParser()
            let line = #"{"type":"message","id":"e1","message":{"role":"assistant","timestamp":1234567890000,"usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":1}}}"#
            let ev = p.parse(line: line, relPath: "p/sess.jsonl")
            check("JSONL.parsed", ev != nil)
            check("JSONL.ts", ev?.tsMs == 1234567890000)
            check("JSONL.dedupe", ev?.dedupeKey == "p/sess.jsonl:e1")
            let user = #"{"type":"message","message":{"role":"user","timestamp":1,"usage":{"input":1}}}"#
            check("JSONL.userSkipped", p.parse(line: user, relPath: "p") == nil)
        }

        // ProviderID
        check("Provider.deepseek", BalanceRegistry.providerID(fromDefaultModel: "deepseek/foo:high") == .deepseek)
        check("Provider.minimax", BalanceRegistry.providerID(fromDefaultModel: "minimax/foo") == .minimax)
        check("Provider.minimaxCodeCN", BalanceRegistry.providerID(fromDefaultModel: "minimax-code-cn/MiniMax-M3:high") == .minimaxCodeCN)
        check("Provider.unknown", BalanceRegistry.providerID(fromDefaultModel: "zenmux/foo") == .unknown)

        // CaffeinateBucket
        check("Bucket.count", CaffeinateBucket.allCases.count == 3)
        check("Bucket.thirty", CaffeinateBucket.thirtyMinutes.minutes == 30)
        check("Bucket.sixty", CaffeinateBucket.sixtyMinutes.minutes == 60)
        check("Bucket.120", CaffeinateBucket.oneTwentyMinutes.minutes == 120)
        check("Bucket.default", CaffeinateBucket.default == .sixtyMinutes)
        check("Bucket.raw30", CaffeinateBucket(rawValue: 30) == .thirtyMinutes)
        check("Bucket.invalid5", CaffeinateBucket(rawValue: 5) == nil)

        // CaffeinateSession
        do {
            let now = Date()
            let s = CaffeinateSession(bucket: .sixtyMinutes, startedAt: now, endAt: now.addingTimeInterval(60))
            check("Session.active", s.isActive(now: now))
            check("Session.remaining", abs(s.remainingSeconds(now: now) - 60) < 1e-6)
            let expired = CaffeinateSession(bucket: .thirtyMinutes, startedAt: now.addingTimeInterval(-120), endAt: now.addingTimeInterval(-60))
            check("Session.expired", !expired.isActive(now: now))
        }

        // CountdownFormatter
        check("Countdown.0", CountdownFormatter.format(remaining: 0) == "0s")
        check("Countdown.0.5", CountdownFormatter.format(remaining: 0.5) == "1s")
        check("Countdown.59", CountdownFormatter.format(remaining: 59) == "59s")
        check("Countdown.60", CountdownFormatter.format(remaining: 60) == "1m")
        check("Countdown.3540", CountdownFormatter.format(remaining: 3540) == "59m")
        check("Countdown.3600", CountdownFormatter.format(remaining: 3600) == "60m")
        check("Countdown.7200", CountdownFormatter.format(remaining: 7200) == "120m")

        // Caffeinate menu semantics
        do {
            let active: CaffeinateSession? = CaffeinateSession(
                bucket: .thirtyMinutes,
                startedAt: Date(),
                endAt: Date().addingTimeInterval(1800)
            )
            let activeLabel: (CaffeinateBucket) -> String = { b in
                "\(b.label)\(active?.bucket == b ? " \u{2713}" : "")"
            }
            check("BucketMenu.check", activeLabel(.thirtyMinutes) == "30 分钟 \u{2713}")
            check("BucketMenu.uncheck", activeLabel(.sixtyMinutes) == "60 分钟")
        }

        // StatusBarTitleComposer
        do {
            let plain = StatusBarTitleComposer.compose(balanceText: "¥12.50", isStale: false, caffeinateActive: false)
            check("Composer.plain", plain.string == "¥12.50")
            let stale = StatusBarTitleComposer.compose(balanceText: "¥12.50", isStale: true, caffeinateActive: false)
            check("Composer.stale", stale.string == "¥12.50·off")
            let active = StatusBarTitleComposer.compose(balanceText: "¥12.50", isStale: false, caffeinateActive: true)
            check("Composer.active.starts", active.string.hasPrefix("☕ "))
            check("Composer.active.ends", active.string.hasSuffix("¥12.50"))
            check("Composer.active.length", active.length == ("☕ ¥12.50" as NSString).length)
            // prefix 部分应有 foregroundColor 属性。
            let colorAttr = active.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
            check("Composer.active.color", colorAttr != nil)
        }

        if failures.isEmpty {
            print("[self-check] OK (全部通过)")
            return 0
        } else {
            print("[self-check] FAIL (\(failures.count)):")
            for f in failures { print("  - \(f)") }
            return 1
        }
    }
}
