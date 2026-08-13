import Foundation
import AppKit

/// 自检入口:纯函数断言 + 集成断言。`swift run omp-companion --self-check` 调用。
public enum SelfCheck {
    public static func run() -> Int {
        var failures: [String] = []

        func check(_ name: String, _ cond: Bool) {
            if !cond { failures.append(name) }
        }

        // 把 async 操作桥到同步 self-check 的小工具。
        func sync<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
            let sema = DispatchSemaphore(value: 0)
            let box = UncheckedSendableBox<T>(nil)
            Task.detached {
                let v = await op()
                box.set(v)
                sema.signal()
            }
            sema.wait()
            return box.get()!
        }

        // 在 self-check 进程里临时塞一对凭据,绕过 CredentialsResolver 的 env / 文件查找。
        let envBackup = ProcessInfo.processInfo.environment
        func withCreds<T>(_ key: String, _ value: String, _ body: () -> T) -> T {
            setenv(key, value, 1)
            defer { setenv(key, "", 1) }
            return body()
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
            // a=5, b=10, c=100 都在 today(14h ago = 10h,相对 0 仍 ≥ 0)
            // d=-1h 在零点之前,被丢
            check("Agg.todayInput", snap.today.inputTokens == 115)
            check("Agg.msgCount", snap.messageCount == 3)
            // 桶:1h ago → idx = 12-1-1 = 10;6h ago → 12-1-6 = 5;14h ago 不入 12 桶
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
                "\(b.label)\(active?.bucket == b ? " ✓" : "")"
            }
            check("BucketMenu.check", activeLabel(.thirtyMinutes) == "30 分钟 ✓")
            check("BucketMenu.uncheck", activeLabel(.sixtyMinutes) == "60 分钟")
        }

        // StatusBarPresenter.renderTitle (4 priority branches)
        do {
            let snap = BalanceSnapshot(
                result: BalanceResult(provider: .deepseek, balance: 12.5, currency: .cny),
                capturedAt: Date()
            )
            let in1 = StatusBarPresenter.Inputs(
                balance: snap,
                missingCredential: "deepseek 凭据缺失",
                configMissing: true
            )
            check("Title.missingCred", StatusBarPresenter.renderTitle(in1).string == "⚠︎deepse")
            let in2 = StatusBarPresenter.Inputs(
                balance: snap,
                configMissing: true
            )
            check("Title.configMissing", StatusBarPresenter.renderTitle(in2).string == "?omp")
            let sess = CaffeinateSession(
                bucket: .sixtyMinutes,
                startedAt: Date(),
                endAt: Date().addingTimeInterval(3600)
            )
            let in3 = StatusBarPresenter.Inputs(balance: snap, caffeinateSession: sess)
            let active = StatusBarPresenter.renderTitle(in3)
            check("Title.active.starts", active.string.hasPrefix("☕ "))
            check("Title.active.contains", active.string.contains("¥12.50"))
            check("Title.active.padded", active.string.contains(" ¥12.50 "))
            let stale = BalanceSnapshot(
                result: BalanceResult(provider: .deepseek, balance: 12.5, currency: .cny),
                capturedAt: Date(),
                isStale: true
            )
            let in4 = StatusBarPresenter.Inputs(balance: stale)
            check("Title.stale", StatusBarPresenter.renderTitle(in4).string == "¥12.50·off")
            check("Title.empty", StatusBarPresenter.renderTitle(.init()).string == "···")
            let colorAttr = active.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
            check("Title.active.color", colorAttr != nil)
        }

        // StatusBarPresenter.renderChrome
        do {
            check("Chrome.empty", StatusBarPresenter.renderChrome(.init()) == .clear)
            let sess = CaffeinateSession(
                bucket: .thirtyMinutes,
                startedAt: Date(),
                endAt: Date().addingTimeInterval(1800)
            )
            let spec = StatusBarPresenter.renderChrome(.init(caffeinateSession: sess))
            check("Chrome.active.bg", spec.background == StatusBarPresenter.caffeinateColor)
            check("Chrome.active.tint", spec.contentTint == .white)
            check("Chrome.active.radius", spec.cornerRadius > 0)
            check("Chrome.metrics", StatusBarChromeMetrics.cornerRadius(buttonHeight: 18) == 9)
        }

        // StatusBarPresenter.renderMenu (configMissing + missingCredential + normal + countdown header)
        do {
            let cfgItems = StatusBarPresenter.renderMenu(.init(configMissing: true))
            check("Menu.cfgMissing.title", cfgItems.first?.title == "未检测到 omp 配置")
            check("Menu.cfgMissing.lastIsQuit", cfgItems.last?.action == .quit)
            let missItems = StatusBarPresenter.renderMenu(.init(missingCredential: "minimax 凭据缺失"))
            check("Menu.credMissing.title", missItems.first?.title.contains("minimax") == true)
            check("Menu.credMissing.lastIsQuit", missItems.last?.action == .quit)
            let snap = BalanceSnapshot(
                result: BalanceResult(provider: .deepseek, balance: 12.5, currency: .cny),
                capturedAt: Date()
            )
            let sess = CaffeinateSession(
                bucket: .sixtyMinutes,
                startedAt: Date(),
                endAt: Date().addingTimeInterval(3600)
            )
            let daily = DailyUsageSnapshot(
                today: TokenStats(inputTokens: 100, outputTokens: 50, cacheReadTokens: 200),
                hourly: (0..<HOUR_BUCKET_COUNT).map { _ in HourBucket(startMs: 0, endMs: 0) },
                messageCount: 1,
                capturedAt: Date()
            )
            let now = Date()
            let items = StatusBarPresenter.renderMenu(
                .init(balance: snap, caffeinateSession: sess, daily: daily),
                now: now
            )
            check("Menu.normal.hasBalance", items.contains { $0.title.contains("deepseek") && $0.title.contains("¥12.50") })
            check("Menu.normal.hasToday", items.contains { $0.title.hasPrefix("今日") })
            check("Menu.normal.hasLast5h", items.contains { $0.title.hasPrefix("近 5h") })
            check("Menu.normal.hasHeaderTickable", items.contains { $0.tickable })
            check("Menu.normal.hasCaffeinateCancel", items.contains { $0.action == .caffeinateCancel })
            check("Menu.normal.hasSettings", items.contains { $0.action == .showSettings })
            let parentIdx = items.firstIndex { $0.submenu != nil }!
            let sub = items[parentIdx].submenu!
            check("Menu.submenu.count", sub.count == 3)
            check("Menu.submenu.checked", sub.contains { $0.representedBucket == 60 && $0.title.contains("✓") })
            let header = items.first { $0.tickable }!
            check("Menu.header.label", header.title.contains("☕️ 阻止休眠 · 还剩"))
        }

        // RefreshController state application via fake Sources
        do {
            do {
                let state = AppState()
                let rc = RefreshController(
                    balanceSource: FakeBalanceSource(),
                    dailySource: FakeDailyUsageSource(),
                    state: state
                )
                rc.apply(balanceSnap: nil, balanceErr: .configMissing, dailySnap: nil, dailyErr: nil)
                check("Refresh.cfgMissing", state.configMissing == true)
                check("Refresh.cfgMissing.balance", state.balance == nil)
            }
            do {
                let state = AppState()
                let rc = RefreshController(
                    balanceSource: FakeBalanceSource(),
                    dailySource: FakeDailyUsageSource(),
                    state: state
                )
                rc.apply(balanceSnap: nil, balanceErr: .missingCredential("deepseek"), dailySnap: nil, dailyErr: nil)
                check("Refresh.credMissing", state.missingCredential?.contains("deepseek") == true)
                check("Refresh.credMissing.cfgOK", state.configMissing == false)
            }
            do {
                let state = AppState()
                let rc = RefreshController(balanceSource: FakeBalanceSource(), dailySource: FakeDailyUsageSource(), state: state)
                let snap = BalanceSnapshot(
                    result: BalanceResult(provider: .deepseek, balance: 12.5, currency: .cny),
                    capturedAt: Date()
                )
                rc.apply(balanceSnap: snap, balanceErr: nil, dailySnap: nil, dailyErr: nil)
                check("Refresh.success.balance", state.balance?.result.balance == 12.5)
                check("Refresh.success.noError", state.lastBalanceError == nil)
            }
            do {
                let state = AppState()
                let rc = RefreshController(balanceSource: FakeBalanceSource(), dailySource: FakeDailyUsageSource(), state: state)
                let daily = DailyUsageSnapshot(
                    today: TokenStats(inputTokens: 100, outputTokens: 50, cacheReadTokens: 200),
                    hourly: (0..<HOUR_BUCKET_COUNT).map { _ in HourBucket(startMs: 0, endMs: 0) },
                    messageCount: 1,
                    capturedAt: Date()
                )
                rc.apply(balanceSnap: nil, balanceErr: nil, dailySnap: daily, dailyErr: nil)
                check("Refresh.daily.input", state.daily?.today.inputTokens == 100)
            }
            do {
                let state = AppState()
                let rc = RefreshController(
                    balanceSource: FakeBalanceSource(),
                    dailySource: FakeDailyUsageSource(),
                    state: state
                )
                rc.apply(balanceSnap: nil, balanceErr: .fetchError("请求超时 (10 秒)"), dailySnap: nil, dailyErr: nil)
                check("Refresh.fetchError", state.lastBalanceError == "请求超时 (10 秒)")
                check("Refresh.fetchError.noCred", state.missingCredential == nil)
            }
        }

        // SleepGuard via FakeIOPMAssertionAdapter + RecordingTicker (@MainActor)
        MainActor.assumeIsolated {
            do {
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                let ticker = RecordingTicker()
                let guard_ = SleepGuard(state: state, adapter: adapter, ticker: ticker)
                let _ = guard_.start(bucket: .sixtyMinutes)
                check("SleepGuard.start.active", guard_.isActive == true)
                check("SleepGuard.start.stateSession", state.caffeinateSession?.bucket == .sixtyMinutes)
                check("SleepGuard.ticker.started", ticker.startCount == 1)
                check("SleepGuard.adapter.acquired", adapter.acquired.count == 1)
            }
            do {
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                let ticker = RecordingTicker()
                let guard_ = SleepGuard(state: state, adapter: adapter, ticker: ticker)
                let _ = guard_.start(bucket: .thirtyMinutes)
                guard_.cancel()
                check("SleepGuard.cancel.inactive", guard_.isActive == false)
                check("SleepGuard.cancel.stateClear", state.caffeinateSession == nil)
                check("SleepGuard.cancel.tickerStopped", ticker.stopCount == 1)
                check("SleepGuard.cancel.adapterReleased", adapter.released.count == 1)
            }
            do {
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                adapter.failNext = true
                let ticker = RecordingTicker()
                let guard_ = SleepGuard(state: state, adapter: adapter, ticker: ticker)
                let _ = guard_.start(bucket: .sixtyMinutes)
                check("SleepGuard.acquireFail.inactive", guard_.isActive == false)
                check("SleepGuard.acquireFail.stateClear", state.caffeinateSession == nil)
                check("SleepGuard.acquireFail.tickerStopped", ticker.stopCount == 1)
            }
            do {
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                let ticker = RecordingTicker()
                let guard_ = SleepGuard(state: state, adapter: adapter, ticker: ticker)
                let _ = guard_.start(bucket: .thirtyMinutes)
                let firstPair = adapter.acquired.last!
                let _ = guard_.start(bucket: .oneTwentyMinutes)
                check("SleepGuard.restart.released", adapter.released.contains(where: { $0.system == firstPair.system }))
                check("SleepGuard.restart.acquiredTwice", adapter.acquired.count == 2)
                check("SleepGuard.restart.bucket", state.caffeinateSession?.bucket == .oneTwentyMinutes)
            }
        }

        // MiniMaxRemainsProvider 解析(用 inline fake HTTPClient;async 通过 detached Task 桥接)
        do {
            struct FakeHTTP: HTTPClient {
                let body: String
                func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
                    let data = self.body.data(using: .utf8)!
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (data, resp)
                }
            }
            do {
                let p = BalanceRegistry.tokenPlan()
                let body = #"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":42.0,"remains_time":3600000}]}"#
                let result: BalanceResult? = withCreds("MINIMAX_API_KEY", "test") {
                    sync { () -> BalanceResult? in
                        let creds = CredentialsResolver()
                        return try? await p.fetch(creds: creds, http: FakeHTTP(body: body))
                    }
                }
                check("MiniMax.parsed.fetch", result != nil)
                check("MiniMax.parsed.remaining", result?.balance == 42.0)
                check("MiniMax.parsed.used", result?.usedPercent == 58.0)
                check("MiniMax.parsed.reset", abs((result?.resetRemaining ?? 0) - 3600) < 0.001)
                check("MiniMax.parsed.id", result?.provider == .minimax)
            }
            do {
                let p = BalanceRegistry.tokenPlan()
                let body = #"{"model_remains":[{"model_name":"other","current_interval_remaining_percent":99}]}"#
                let result: BalanceResult? = withCreds("MINIMAX_API_KEY", "test") {
                    sync { () -> BalanceResult? in
                        let creds = CredentialsResolver()
                        return try? await p.fetch(creds: creds, http: FakeHTTP(body: body))
                    }
                }
                check("MiniMax.noGeneral.zero", result?.balance == 0)
                check("MiniMax.noGeneral.used", result?.usedPercent == 100)
                check("MiniMax.noGeneral.reset", result?.resetRemaining == 0)
            }
            do {
                let p = BalanceRegistry.codingPlanCN()
                let body = #"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":50.0,"remains_time":0}]}"#
                let result: BalanceResult? = withCreds("MINIMAX_CODE_CN_API_KEY", "test") {
                    sync { () -> BalanceResult? in
                        let creds = CredentialsResolver()
                        return try? await p.fetch(creds: creds, http: FakeHTTP(body: body))
                    }
                }
                check("MiniMax.zeroReset", result?.resetRemaining == 0)
                check("MiniMax.codingCN.id", result?.provider == .minimaxCodeCN)
            }
            check("Registry.allCount", BalanceRegistry.all().count == 3)
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

/// SelfCheck 内 async 桥接用的单槽盒子。
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    private var v: T?
    private let lock = NSLock()
    init(_ initial: T?) { self.v = initial }
    func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return v }
}
