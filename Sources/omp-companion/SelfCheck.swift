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
        check("Balance.menuBarTextCNY", BalanceFormatter.menuBarText(cny) == "¥12.50")
        let pct1 = BalanceResult(provider: .minimaxCodeCN, balance: 92, currency: .percent, usedPercent: 8, resetRemaining: 4 * 3600 + 30 * 60)
        let pct2 = BalanceResult(provider: .minimaxCodeCN, balance: 92, currency: .percent, usedPercent: 8, resetRemaining: nil)
        check("Balance.menuBarTextPercentWithReset", BalanceFormatter.menuBarText(pct1) == "8%")
        check("Balance.menuBarTextNoReset", BalanceFormatter.menuBarText(pct2) == "8%")
        check("Balance.statusBarTextStripsReset", BalanceFormatter.statusBarText(pct1) == "8%")
        check("Balance.hms0", BalanceFormatter.formatHMS(0) == "0h0m")
        check("Balance.hms125", BalanceFormatter.formatHMS(125) == "0h2m")
        check("Balance.hms3661", BalanceFormatter.formatHMS(3661) == "1h1m")
        check("Duration.hms", BalanceFormatter.formatDuration(3 * 3600 + 15 * 60) == "3h15m")
        check("Duration.23h59m", BalanceFormatter.formatDuration(86399) == "23h59m")
        check("Duration.1d", BalanceFormatter.formatDuration(86400) == "1d")
        check("Duration.5d3h", BalanceFormatter.formatDuration(5 * 86400 + 3 * 3600) == "5d3h")

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
        check("Provider.opencodeGo", BalanceRegistry.providerID(fromDefaultModel: "opencode-go/deepseek-v4-flash:high") == .opencodeGo)
        check("Provider.ccccapi", BalanceRegistry.providerID(fromDefaultModel: "ccccapi/claude-sonnet") == .ccccapi)
        check("Provider.opencodeZenUnknown", BalanceRegistry.providerID(fromDefaultModel: "opencode-zen/foo") == .unknown)
        check("Provider.unknown", BalanceRegistry.providerID(fromDefaultModel: "zenmux/foo") == .unknown)
        let relocatedCreds = CredentialsResolver(
            homeDir: "/tmp/omp-home",
            cwd: "/tmp/omp-cwd",
            environment: ["PI_CODING_AGENT_DIR": "/tmp/omp-relocated-agent"]
        )
        check("Credentials.agentDirOverride", relocatedCreds.candidateEnvFiles()[1] == "/tmp/omp-relocated-agent/.env")

        // LiveBalanceSource 未匹配 Provider 保底：不查询余额，也不触发 HTTP。
        do {
            final class RecordingHTTP: HTTPClient, @unchecked Sendable {
                var callCount = 0

                func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
                    self.callCount += 1
                    throw HTTPError.invalidResponse
                }
            }

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("omp-companion-self-check-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let agentDir = root.appendingPathComponent(".omp/agent", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
                try "modelRoles:\n  default: OpenCode-Zen/foo:high\n".write(
                    to: agentDir.appendingPathComponent("config.yml"),
                    atomically: true,
                    encoding: .utf8
                )
                let http = RecordingHTTP()
                let source = LiveBalanceSource(
                    config: ConfigSource(homeDir: root.path, cwd: root.path, env: [:]),
                    creds: CredentialsResolver(),
                    http: http
                )
                let capture = sync { await source.capture(now: Date()) }
                check("Source.unmatched.noSnapshot", capture.0 == nil)
                check("Source.unmatched.signal", capture.1 == .unmatchedProvider("OpenCode-Zen"))
                check("Source.unmatched.modelNormalized", capture.model == "OpenCode-Zen/foo:high")
                check("Source.unmatched.noHTTP", http.callCount == 0)

                try "modelRoles:\n  default: OpenCode-Zen/\n".write(
                    to: agentDir.appendingPathComponent("config.yml"),
                    atomically: true,
                    encoding: .utf8
                )
                let invalidCapture = sync { await source.capture(now: Date()) }
                if case .fetchError = invalidCapture.1 {
                    check("Source.invalidModel.error", true)
                } else {
                    check("Source.invalidModel.error", false)
                }
                check("Source.invalidModel.noHTTP", http.callCount == 0)
            } catch {
                check("Source.unmatched.setup", false)
            }
        }
        // CaffeinateBucket
        check("Bucket.count", CaffeinateBucket.allCases.count == 3)
        check("Bucket.thirty", CaffeinateBucket.thirtyMinutes.minutes == 30)
        check("Bucket.sixty", CaffeinateBucket.sixtyMinutes.minutes == 60)
        check("Bucket.120", CaffeinateBucket.oneTwentyMinutes.minutes == 120)
        check("Bucket.default", CaffeinateBucket.default == .sixtyMinutes)
        check("Bucket.raw30", CaffeinateBucket(rawValue: 30) == .thirtyMinutes)
        check("Bucket.invalid5", CaffeinateBucket(rawValue: 5) == nil)

        // RefreshInterval
        check("Interval.count", RefreshInterval.allCases.count == 3)
        check("Interval.seconds30", RefreshInterval.seconds30.seconds == 30)
        check("Interval.seconds60", RefreshInterval.seconds60.seconds == 60)
        check("Interval.seconds120", RefreshInterval.seconds120.seconds == 120)
        check("Interval.default", RefreshInterval.default == .seconds60)
        check("Interval.raw30", RefreshInterval(rawValue: 30) == .seconds30)
        check("Interval.invalid999", RefreshInterval(rawValue: 999) == nil)

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
            check("Title.missingCred", StatusBarPresenter.renderTitle(in1).string == "\u{2009}\u{2009}⚠︎deepse")
            let in2 = StatusBarPresenter.Inputs(
                balance: snap,
                configMissing: true
            )
            check("Title.configMissing", StatusBarPresenter.renderTitle(in2).string == "\u{2009}\u{2009}?omp")
            let sess = CaffeinateSession(
                bucket: .sixtyMinutes,
                startedAt: Date(),
                endAt: Date().addingTimeInterval(3600)
            )
            let in3 = StatusBarPresenter.Inputs(balance: snap, caffeinateSession: sess)
            let active = StatusBarPresenter.renderTitle(in3)
            check("Title.active.gapPrefix", active.string.hasPrefix("\u{2009}\u{2009}"))
            check("Title.active.balanceBeforeCoffee", active.string.hasPrefix("\u{2009}\u{2009} ¥12.50 "))
            check("Title.active.contains", active.string.contains("¥12.50"))
            check("Title.active.padded", active.string.contains(" ¥12.50 "))
            check("Title.active.coffeeAtEnd", active.string.hasSuffix(" \u{2615}"))
            let coffeeIdx = active.string.range(of: "\u{2615}")!.lowerBound
            let colorAttr = active.attributes(at: active.string.distance(from: active.string.startIndex, to: coffeeIdx),
                                              effectiveRange: nil)[.foregroundColor] as? NSColor
            check("Title.active.color", colorAttr != nil)
            let stale = BalanceSnapshot(
                result: BalanceResult(provider: .deepseek, balance: 12.5, currency: .cny),
                capturedAt: Date(),
                isStale: true
            )
            let in4 = StatusBarPresenter.Inputs(balance: stale)
            check("Title.stale", StatusBarPresenter.renderTitle(in4).string == "\u{2009}\u{2009}¥12.50·off")
            let staleCcccapi = BalanceSnapshot(
                result: BalanceResult(provider: .ccccapi, balance: 12.5, currency: .usd),
                capturedAt: Date(),
                isStale: true
            )
            let ccccapiTitle = StatusBarPresenter.renderTitle(.init(balance: staleCcccapi)).string
            check("Title.ccccapiStaleWithoutOff", ccccapiTitle == "\u{2009}\u{2009}$12.50")
            check("Title.empty", StatusBarPresenter.renderTitle(.init()).string == "\u{2009}\u{2009}···")
            let unmatched = StatusBarPresenter.Inputs(unmatchedProvider: "OpenCode-Zen")
            check("Title.unmatched", StatusBarPresenter.renderTitle(unmatched).string == "\u{2009}\u{2009}OpenCode-Zen")
            let unmatchedActive = StatusBarPresenter.renderTitle(.init(caffeinateSession: sess, unmatchedProvider: "OpenCode-Zen"))
            check("Title.unmatched.coffeeAtEnd", unmatchedActive.string == "\u{2009}\u{2009}OpenCode-Zen \u{2615}")
            if let unmatchedCoffeeIdx = unmatchedActive.string.range(of: "\u{2615}")?.lowerBound {
                let unmatchedColor = unmatchedActive.attributes(
                    at: unmatchedActive.string.distance(from: unmatchedActive.string.startIndex, to: unmatchedCoffeeIdx),
                    effectiveRange: nil
                )[.foregroundColor] as? NSColor
                check("Title.unmatched.coffeeColor", unmatchedColor == StatusBarPresenter.caffeinateColor)
            } else {
                check("Title.unmatched.coffeeColor", false)
            }
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
            check("Menu.normal.hasBalance", items.contains { $0.title == "DeepSeek" } && items.contains { $0.title == "余额 ¥12.50" })
            let pctSnap = BalanceSnapshot(
                result: BalanceResult(provider: .minimaxCodeCN, balance: 92, currency: .percent, usedPercent: 8, resetRemaining: 4 * 3600 + 30 * 60),
                capturedAt: Date(),
                quotaWindows: [QuotaWindow(id: "5h", label: "5h", usedPercent: 8, status: .ok, resetsAt: now.addingTimeInterval(4 * 3600 + 30 * 60))]
            )
            let pctItems = StatusBarPresenter.renderMenu(
                .init(balance: pctSnap, daily: daily),
                now: now
            )
            let pctBar = pctItems.first { $0.usageBar != nil }?.usageBar
            check("Menu.normal.percentRow.balance", pctItems.first?.title == "MiniMax Coding Plan CN")
            check("Menu.normal.percentBar", pctBar?.leftText == "5h" && pctBar?.percentText == "8%" && pctBar?.resetText == "4h30m 后重置" && abs((pctBar?.value ?? -1) - 8) < 0.001)
            check("Menu.normal.percentRow.noGenericReset", !pctItems.contains { $0.title.hasPrefix("重置剩余时间") })
            // 无窗口降级（响应缺 start/end）：bar 行无左标签
            let noWindowSnap = BalanceSnapshot(
                result: BalanceResult(provider: .minimaxCodeCN, balance: 92, currency: .percent, usedPercent: 8, resetRemaining: 4 * 3600 + 30 * 60),
                capturedAt: Date()
            )
            let noWindowItems = StatusBarPresenter.renderMenu(.init(balance: noWindowSnap, daily: daily), now: now)
            check("Menu.normal.percentBarNoWindow", noWindowItems.first { $0.usageBar != nil }?.usageBar?.leftText == nil)
            // OpenCode Go：行 1 用 displayName（无尾百分比），三窗口各一条进度条行
            let qs: [QuotaWindow] = [
                QuotaWindow(id: "5h", label: "5h", usedPercent: 67, status: .ok, resetsAt: now.addingTimeInterval(3 * 3600 + 15 * 60)),
                QuotaWindow(id: "7d", label: "7d", usedPercent: 12, status: .ok, resetsAt: now.addingTimeInterval(5 * 86400 + 3 * 3600)),
                QuotaWindow(id: "monthly", label: "月度", usedPercent: 3, status: .rateLimited, resetsAt: now.addingTimeInterval(86400)),
            ]
            let ocSnap = BalanceSnapshot(
                result: BalanceResult(provider: .opencodeGo, balance: 67, currency: .percent, usedPercent: 67),
                capturedAt: Date(),
                quotaWindows: qs
            )
            let ocItems = StatusBarPresenter.renderMenu(.init(balance: ocSnap, daily: daily), now: now)
            let ocBars = ocItems.compactMap { $0.usageBar }
            check("Menu.opencode.balanceRow", ocItems.contains { $0.title == "OpenCode Go" })
            check("Menu.opencode.barCount", ocBars.count == 3)
            check("Menu.opencode.rollingBar", ocBars.contains { $0.leftText == "5h" && $0.percentText == "67%" && $0.resetText == "3h15m 后重置" && abs($0.value - 67) < 0.001 })
            check("Menu.opencode.weeklyBar", ocBars.contains { $0.leftText == "7d" && $0.percentText == "12%" && $0.resetText == "5d3h 后重置" && abs($0.value - 12) < 0.001 })
            check("Menu.opencode.monthlyBar", ocBars.contains { $0.leftText == "月度" && $0.percentText == "3%" && $0.resetText == "1d 后重置" && abs($0.value - 3) < 0.001 })
            check("Menu.opencode.noGenericReset", !ocItems.contains { $0.title.hasPrefix("重置剩余时间") })
            // 进度条最短长度：视图按 minimumWidth 加宽后，两种左标签形态的条长都 ≥ minBarWidth
            let barMinLabeled = UsageBarMenuItemView.barWidth(totalWidth: UsageBarMenuItemView.minimumWidth(hasLeftLabel: true), hasLeftLabel: true)
            let barMinUnlabeled = UsageBarMenuItemView.barWidth(totalWidth: UsageBarMenuItemView.minimumWidth(hasLeftLabel: false), hasLeftLabel: false)
            check("Menu.bar.minLength.labeled", barMinLabeled >= UsageBarMenuItemView.minBarWidth)
            check("Menu.bar.minLength.unlabeled", barMinUnlabeled >= UsageBarMenuItemView.minBarWidth)
            // stale：进度条行回退纯文本
            let staleSnap = BalanceSnapshot(
                result: BalanceResult(provider: .opencodeGo, balance: 67, currency: .percent, usedPercent: 67),
                capturedAt: Date(),
                isStale: true,
                quotaWindows: qs
            )
            let staleItems = StatusBarPresenter.renderMenu(.init(balance: staleSnap, daily: daily), now: now)
            check("Menu.stale.opencode", staleItems.contains { $0.title == "5h · 已用 67% · 3h15m 后重置" } && !staleItems.contains { $0.usageBar != nil })
            let stalePctSnap = BalanceSnapshot(
                result: BalanceResult(provider: .minimaxCodeCN, balance: 92, currency: .percent, usedPercent: 8, resetRemaining: 4 * 3600 + 30 * 60),
                capturedAt: Date(),
                isStale: true,
                quotaWindows: [QuotaWindow(id: "5h", label: "5h", usedPercent: 8, status: .ok, resetsAt: now.addingTimeInterval(4 * 3600 + 30 * 60))]
            )
            let stalePctItems = StatusBarPresenter.renderMenu(.init(balance: stalePctSnap, daily: daily), now: now)
            check("Menu.stale.percent", stalePctItems.contains { $0.title == "5h · 已用 8% · 4h30m 后重置" } && !stalePctItems.contains { $0.usageBar != nil })
            check("Menu.normal.hasLast5h", items.contains { $0.title.hasPrefix("近 5h") })
            check("Menu.normal.hasHeaderTickable", items.contains { $0.tickable })
            check("Menu.normal.hasCaffeinateCancel", items.contains { $0.action == .caffeinateCancel })
            check("Menu.normal.hasSettings", items.contains { $0.action == .showSettings })
            let parentIdx = items.firstIndex { $0.submenu != nil }!
            let sub = items[parentIdx].submenu!
            check("Menu.submenu.count", sub.count == 3)
            check("Menu.submenu.checked", sub.contains { $0.representedBucket == 60 && $0.title.contains("✓") })
            let header = items.first { $0.tickable }!
            // 模型名内联到余额行（provider: usage 之后，用 · 连接）
            let modelItems = StatusBarPresenter.renderMenu(
                .init(balance: snap, currentModel: "deepseek/deepseek-chat"),
                now: now
            )
            check("Menu.model.inline", modelItems.contains { $0.title == "DeepSeek (deepseek-chat)" } && modelItems.contains { $0.title == "余额 ¥12.50" })
            let thinkItems = StatusBarPresenter.renderMenu(
                .init(balance: ocSnap, currentModel: "hy3:high"),
                now: now
            )
            check("Menu.model.stripThinkLevel", thinkItems.contains { $0.title == "OpenCode Go (hy3)" })
            let unmatchedItems = StatusBarPresenter.renderMenu(
                .init(
                    daily: daily,
                    currentModel: "OpenCode-Zen/foo:high",
                    unmatchedProvider: "OpenCode-Zen"
                ),
                now: now
            )
            check("Menu.unmatched.header", unmatchedItems.first?.title == "OpenCode-Zen (foo)")
            check("Menu.unmatched.notice", unmatchedItems.contains { $0.title == "OpenCode-Zen 暂不支持余额查询" })
            check("Menu.unmatched.normalActions", unmatchedItems.contains { $0.action == .showSettings } && unmatchedItems.contains { $0.action == .quit })
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
                rc.apply(balanceSnap: snap, balanceErr: nil, balanceModel: "deepseek/deepseek-chat", dailySnap: nil, dailyErr: nil)
                check("Refresh.success.balance", state.balance?.result.balance == 12.5)
                check("Refresh.success.noError", state.lastBalanceError == nil)
                check("Refresh.success.model", state.currentModel == "deepseek/deepseek-chat")
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
                check("Refresh.fetchError.noOldBalance", state.balance == nil)
            }
            do {
            do {
                let state = AppState()
                let rc = RefreshController(balanceSource: FakeBalanceSource(), dailySource: FakeDailyUsageSource(), state: state)
                let old = BalanceSnapshot(
                    result: BalanceResult(provider: .ccccapi, balance: 12.34, currency: .usd),
                    capturedAt: Date()
                )
                rc.apply(balanceSnap: old, balanceErr: nil, balanceModel: "ccccapi/model", dailySnap: nil, dailyErr: nil)
                rc.apply(balanceSnap: nil, balanceErr: .fetchError("响应解析失败"), balanceModel: "ccccapi/model", dailySnap: nil, dailyErr: nil)
                check("Refresh.fetchError.stale", state.balance?.isStale == true)
                check("Refresh.fetchError.staleValue", state.balance?.result.balance == 12.34)
            }
                let state = AppState()
                let rc = RefreshController(balanceSource: FakeBalanceSource(), dailySource: FakeDailyUsageSource(), state: state)
                let old = BalanceSnapshot(
                    result: BalanceResult(provider: .deepseek, balance: 12.5, currency: .cny),
                    capturedAt: Date()
                )
                rc.apply(balanceSnap: old, balanceErr: nil, balanceModel: "deepseek/deepseek-chat", dailySnap: nil, dailyErr: nil)
                rc.apply(
                    balanceSnap: nil,
                    balanceErr: .unmatchedProvider("OpenCode-Zen"),
                    balanceModel: "OpenCode-Zen/foo:high",
                    dailySnap: nil,
                    dailyErr: nil
                )
                check("Refresh.unmatched.noBalance", state.balance == nil)
                check("Refresh.unmatched.provider", state.unmatchedProvider == "OpenCode-Zen")
                check("Refresh.unmatched.logo", state.currentProvider == .unknown)
                check("Refresh.unmatched.noError", state.lastBalanceError == nil && state.missingCredential == nil)
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
                let body = #"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":42.0,"remains_time":3600000,"start_time":1787209200000,"end_time":1787227200000,"current_interval_status":1}]}"#
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
                check("MiniMax.parsed.window.count", result?.quotaWindows?.count == 1)
                check("MiniMax.parsed.window.label", result?.quotaWindows?.first?.label == "5h")
                check("MiniMax.parsed.window.used", result?.quotaWindows?.first?.usedPercent == 58)
                check("MiniMax.parsed.window.resetsAt", result?.quotaWindows?.first?.resetsAt.timeIntervalSince1970 == 1787227200)
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
        // OpenCode Go 解码：三窗口全量 + used 语义 + all-or-nothing
        do {
            let p = BalanceRegistry.opencodeGo()
            let body = #"{"usage":{"rolling":{"percent":67,"status":"ok","resetsAt":"2027-08-19T12:00:00Z"},"weekly":{"percent":12,"status":"ok","resetsAt":"2026-08-25T12:00:00Z"},"monthly":{"percent":3,"status":"rate-limited","resetsAt":"2026-09-03T12:00:00Z"}}}"#
            let result: BalanceResult? = withCreds("OPENCODE_API_KEY", "test") {
                sync { () -> BalanceResult? in
                    let creds = CredentialsResolver()
                    return try? await p.fetch(creds: creds, http: FakeHTTP(body: body))
                }
            }
            let expRolling = ISO8601DateFormatter().date(from: "2027-08-19T12:00:00Z")!
            check("OpenCode.id", result?.provider == .opencodeGo)
            check("OpenCode.rolling.balance", result?.balance == 67)
            check("OpenCode.rolling.used", result?.usedPercent == 67)
            check("OpenCode.windows.count", result?.quotaWindows?.count == 3)
            check("OpenCode.windows.order", result?.quotaWindows?.map(\.id) == ["5h", "7d", "monthly"])
            check("OpenCode.windows.rolling.resetsAt", result?.quotaWindows?[0].resetsAt == expRolling)
            check("OpenCode.windows.rolling.used", result?.quotaWindows?[0].usedPercent == 67)
            check("OpenCode.windows.weekly.used", result?.quotaWindows?[1].usedPercent == 12)
            check("OpenCode.windows.monthly.used", result?.quotaWindows?[2].usedPercent == 3)
            check("OpenCode.windows.monthly.limited", result?.quotaWindows?[2].status == .rateLimited)
            check("OpenCode.resetRemaining", abs((result?.resetRemaining ?? -999) - expRolling.timeIntervalSince(Date())) < 5)
        }
        do {
            // live 响应形状：resetsAt 带小数秒（ISO8601DateFormatter 默认格式解析不了，走 fallback）
            let p = BalanceRegistry.opencodeGo()
            let body = #"{"usage":{"rolling":{"percent":28,"status":"ok","resetsAt":"2026-08-19T13:02:42.270Z"},"weekly":{"percent":11,"status":"ok","resetsAt":"2026-08-24T00:00:00.270Z"},"monthly":{"percent":5,"status":"ok","resetsAt":"2026-09-19T07:59:11.270Z"}}}"#
            let result: BalanceResult? = withCreds("OPENCODE_API_KEY", "test") {
                sync { () -> BalanceResult? in
                    let creds = CredentialsResolver()
                    return try? await p.fetch(creds: creds, http: FakeHTTP(body: body))
                }
            }
            check("OpenCode.liveShape.count", result?.quotaWindows?.count == 3)
            check("OpenCode.liveShape.rolling", result?.quotaWindows?[0].usedPercent == 28)
            check("OpenCode.liveShape.weekly", result?.quotaWindows?[1].usedPercent == 11)
            check("OpenCode.liveShape.monthly", result?.quotaWindows?[2].usedPercent == 5)
        }
        do {
            // 缺 monthly 窗口 → all-or-nothing → invalidResponse
            let p = BalanceRegistry.opencodeGo()
            let body = #"{"usage":{"rolling":{"percent":10,"status":"ok","resetsAt":"2026-08-19T12:00:00Z"},"weekly":{"percent":10,"status":"ok","resetsAt":"2026-08-25T12:00:00Z"}}}"#
            let thrown = withCreds("OPENCODE_API_KEY", "test") {
                sync {
                    let creds = CredentialsResolver()
                    do {
                        _ = try await p.fetch(creds: creds, http: FakeHTTP(body: body))
                        return nil as HTTPError?
                    } catch let e as HTTPError {
                        return e
                    } catch {
                        return nil as HTTPError?
                    }
                }
            }
            check("OpenCode.missingWindow.throws", thrown == .invalidResponse)
        }
        do {
            // percent 越界 → malformed → invalidResponse
            let p = BalanceRegistry.opencodeGo()
            let body = #"{"usage":{"rolling":{"percent":150,"status":"ok","resetsAt":"2026-08-19T12:00:00Z"},"weekly":{"percent":10,"status":"ok","resetsAt":"2026-08-25T12:00:00Z"},"monthly":{"percent":3,"status":"ok","resetsAt":"2026-09-03T12:00:00Z"}}}"#
            let thrown = withCreds("OPENCODE_API_KEY", "test") {
                sync {
                    let creds = CredentialsResolver()
                    do {
                        _ = try await p.fetch(creds: creds, http: FakeHTTP(body: body))
                        return nil as HTTPError?
                    } catch let e as HTTPError {
                        return e
                    } catch {
                        return nil as HTTPError?
                    }
                }
            }
            check("OpenCode.badPercent.throws", thrown == .invalidResponse)
        }
        do {
            final class RecordingHTTP: HTTPClient, @unchecked Sendable {
                let body: String
                var calls = 0
                var requestedURL: URL?
                var requestedHeaders: [String: String] = [:]

                init(body: String) { self.body = body }

                func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
                    calls += 1
                    requestedURL = url
                    requestedHeaders = headers
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (body.data(using: .utf8)!, response)
                }
            }

            let p = BalanceRegistry.ccccapi()
            let http = RecordingHTTP(body: #"{"code":0,"message":"success","data":{"balance":12.34,"email":"redacted"}}"#)
            let result: BalanceResult? = withCreds("CCCAPI_ACCESS_TOKEN", "test-token") {
                sync {
                    let creds = CredentialsResolver()
                    return try? await p.fetch(creds: creds, http: http)
                }
            }
            check("Ccccapi.parsed", result?.provider == .ccccapi && result?.balance == 12.34 && result?.currency == .usd)
            check("Ccccapi.request.url", http.requestedURL?.absoluteString == "https://ccccapi.cc/api/v1/user/profile")
            check("Ccccapi.request.auth", http.requestedHeaders["Authorization"] == "Bearer test-token")

            let malformedHTTP = RecordingHTTP(body: #"{"code":0,"message":"success","data":{}}"#)
            let malformed: HTTPError? = withCreds("CCCAPI_ACCESS_TOKEN", "test-token") {
                sync {
                    let creds = CredentialsResolver()
                    do {
                        _ = try await p.fetch(creds: creds, http: malformedHTTP)
                        return nil
                    } catch let error as HTTPError {
                        return error
                    } catch {
                        return nil
                    }
                }
            }
            check("Ccccapi.strict", malformed == .invalidResponse)

            let blankHTTP = RecordingHTTP(body: #"{"code":0,"message":"success","data":{"balance":1}}"#)
            let blankCreds = CredentialsResolver(environment: ["CCCAPI_ACCESS_TOKEN": "   "])
            let blank: HTTPError? = sync {
                do {
                    _ = try await p.fetch(creds: blankCreds, http: blankHTTP)
                    return nil
                } catch let error as HTTPError {
                    return error
                } catch {
                    return nil
                }
            }
            check("Ccccapi.blankCredential", blank == .missingCredential && blankHTTP.calls == 0)
        }
        check("Balance.usd.status", BalanceFormatter.statusBarText(BalanceResult(provider: .ccccapi, balance: 12.3, currency: .usd)) == "$12.30")
        check("Balance.usd.menu", BalanceFormatter.menuBarText(BalanceResult(provider: .ccccapi, balance: 12.3, currency: .usd)) == "$12.30")
            check("Registry.allCount", BalanceRegistry.all().count == 5)
        }
        check("Logo.unknown.asset", LogoCatalog.assetBaseName(for: .unknown) == "logo_omp")
        check("Logo.ccccapi.asset", LogoCatalog.assetBaseName(for: .ccccapi) == "provider_ccccapi")

        // LogoCatalog：每个 ProviderID 的图标资源都得真实落盘到仓库 Resources/ 下。
        // SelfCheck 跑在 `swift run --self-check` 下,Bundle.main 不携带 Resources,
        // 所以直接探源文件路径 + 实际加载 NSImage。任何文件被误删/格式坏掉 → 立刻暴露。
        do {
            let repoRoot = "/Users/alfred/Workspace/github.com/alfred-zhong/omp-companion/Resources"
            let fm = FileManager.default
            let needed: [(ProviderID, String)] = [
                (.deepseek, "provider_deepseek@2x.png"),
                (.deepseek, "provider_deepseek@3x.png"),
                (.minimax, "provider_minimax@2x.png"),
                (.minimax, "provider_minimax@3x.png"),
                (.opencodeGo, "provider_opencode_go@2x.png"),
                (.opencodeGo, "provider_opencode_go@3x.png"),
                (.ccccapi, "provider_ccccapi.svg"),
                (.unknown, "logo_omp.svg"),
            ]
            for (pid, name) in needed {
                let path = "\(repoRoot)/\(name)"
                check("Logo.asset.\(pid.rawValue).\(name)", fm.fileExists(atPath: path))
            }
            // PNG signature + 每个资源均可被 NSImage 加载,在 swift run 进程里即可完成。
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            for name in ["provider_deepseek@3x.png", "provider_minimax@3x.png", "provider_opencode_go@3x.png"] {
                let url = URL(fileURLWithPath: "\(repoRoot)/\(name)")
                guard let data = try? Data(contentsOf: url) else {
                    check("Logo.read.\(name)", false); continue
                }
                check("Logo.signature.\(name)", data.count >= 8 && data.subdata(in: 0..<8) == png)
                let img = NSImage(contentsOf: url)
                check("Logo.nsimage.\(name)", img != nil)
            }
            // 每张落地资源均标记为 template,确认 AppKit 能消费。
            // 注意:NSImage 的 KVC key 是 'template' 而不是 'isTemplate'(ObjC property 名)。
            for (pid, name) in needed {
                let url = URL(fileURLWithPath: "\(repoRoot)/\(name)")
                if let img = NSImage(contentsOf: url) {
                    img.setValue(true, forKey: "template")
                    check("Logo.template.\(pid.rawValue).\(name)", img.isTemplate)
                }
            }
            let ompURL = URL(fileURLWithPath: "\(repoRoot)/logo_omp.svg")
            check("Logo.omp.canvas", NSImage(contentsOf: ompURL)?.size == NSSize(width: 16, height: 16))
            if Bundle.main.bundleURL.pathExtension == "app" {
                check("Logo.bundle.unknown", LogoCatalog.image(for: .unknown)?.isTemplate == true)
            }
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
