import AppKit
import QuartzCore
import Combine
import SwiftUI

public final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: RefreshController
    private let state: AppState
    private let sleepGuard: SleepGuard
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var onShowSettings: () -> Void
    private var caffeinateHeaderItem: NSMenuItem?

    public init(
        controller: RefreshController,
        state: AppState,
        sleepGuard: SleepGuard,
        onShowSettings: @escaping () -> Void
    ) {
        self.controller = controller
        self.state = state
        self.sleepGuard = sleepGuard
        self.onShowSettings = onShowSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.title = "···"
        let m = NSMenu()
        self.statusItem.menu = m
        super.init()
        m.delegate = self
        wireState()
        Task { @MainActor in
            await self.controller.tick()
        }
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    public func restartTimer() { startTimer() }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: controller.intervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.controller.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func wireState() {
        let bridge: (Any) -> Void = { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.updateTitle() }
        }
        state.$balance.receive(on: RunLoop.main).sink { bridge($0) }.store(in: &cancellables)
        state.$daily.receive(on: RunLoop.main).sink { bridge($0) }.store(in: &cancellables)
        state.$lastBalanceError.receive(on: RunLoop.main).sink { bridge($0) }.store(in: &cancellables)
        state.$lastDailyError.receive(on: RunLoop.main).sink { bridge($0) }.store(in: &cancellables)
        state.$configMissing.receive(on: RunLoop.main).sink { bridge($0) }.store(in: &cancellables)
        state.$missingCredential.receive(on: RunLoop.main).sink { bridge($0) }.store(in: &cancellables)
        state.$caffeinateSession.receive(on: RunLoop.main).sink { bridge($0) }.store(in: &cancellables)
        state.$countdownTick.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshCaffeinateHeaderInPlace() }
        }.store(in: &cancellables)
    }

    @MainActor
    private func updateTitle() {
        if let missing = state.missingCredential {
            statusItem.button?.attributedTitle = NSAttributedString(string: "⚠︎\(missing.prefix(6))")
            applyCaffeinateChrome(active: false)
        } else if state.configMissing {
            statusItem.button?.attributedTitle = NSAttributedString(string: "?omp")
            applyCaffeinateChrome(active: false)
        } else if let balance = state.balance {
            let text = BalanceFormatter.statusBarText(balance.result)
            let active = state.caffeinateSession != nil
            let padded = active ? " \(text) " : text
            statusItem.button?.attributedTitle = StatusBarTitleComposer.compose(
                balanceText: padded,
                isStale: balance.isStale,
                caffeinateActive: active
            )
            applyCaffeinateChrome(active: active)
        } else {
            statusItem.button?.attributedTitle = NSAttributedString(string: "···")
            applyCaffeinateChrome(active: false)
        }
    }

    @MainActor
    private func applyCaffeinateChrome(active: Bool) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layoutSubtreeIfNeeded()
        let h = max(button.bounds.height, 1)
        button.layer?.backgroundColor = (active
            ? StatusBarTitleComposer.caffeinateColor
            : StatusBarTitleComposer.clearColor).cgColor
        button.layer?.cornerRadius = active ? h / 2 : 0
        button.contentTintColor = active ? .white : nil
        // 去掉状态栏上的补间动画（闪现）。补间会受系统半透明材质干扰。
        button.layer?.removeAnimation(forKey: "caffeinateChrome.bg")
        button.layer?.removeAnimation(forKey: "caffeinateChrome.radius")
    }



    @MainActor
    private func refreshCaffeinateHeaderInPlace() {
        guard let item = caffeinateHeaderItem,
              let session = state.caffeinateSession else { return }
        let remaining = session.remainingSeconds(now: Date())
        item.title = "☕️ 阻止休眠 · 还剩 \(CountdownFormatter.format(remaining: remaining))"
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        caffeinateHeaderItem = nil

        if state.configMissing {
            menu.addItem(withTitle: "未检测到 omp 配置", action: nil, keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            addActionItem(menu, title: "打开 README", action: #selector(openReadme))
            menu.addItem(NSMenuItem.separator())
            addActionItem(menu, title: "刷新", action: #selector(forceRefresh), key: "r")
            addActionItem(menu, title: "退出", action: #selector(quit), key: "q")
            return
        }
        if let missing = state.missingCredential {
            menu.addItem(withTitle: "未找到 \(missing) 的 API key", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "请于 ~/.omp/agent/.env 设置", action: nil, keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            addActionItem(menu, title: "打开 README", action: #selector(openReadme))
            menu.addItem(NSMenuItem.separator())
            addActionItem(menu, title: "刷新", action: #selector(forceRefresh), key: "r")
            addActionItem(menu, title: "退出", action: #selector(quit), key: "q")
            return
        }
        if let balance = state.balance {
            menu.addItem(withTitle: "\(balance.result.provider.rawValue) (\(BalanceFormatter.statusBarText(balance.result)))", action: nil, keyEquivalent: "")
        } else if let err = state.lastBalanceError {
            menu.addItem(withTitle: "余额: \(err)", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "余额: ···", action: nil, keyEquivalent: "")
        }
        menu.addItem(NSMenuItem.separator())
        if let daily = state.daily {
            let s = daily.today
            let hit = CompactFormatter.format(Int((s.cacheHitRate * 100).rounded()))
            let line = "今日 · ↑\(CompactFormatter.format(s.inputTokens)) · ↓\(CompactFormatter.format(s.outputTokens)) · ⚡\(CompactFormatter.format(s.cacheReadTokens)) · 🎯\(hit)%"
            menu.addItem(withTitle: line, action: nil, keyEquivalent: "")
        } else if let err = state.lastDailyError {
            menu.addItem(withTitle: "今日: \(err)", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "今日: ···", action: nil, keyEquivalent: "")
        }
        if let daily = state.daily {
            let s = daily.last5h
            let hit = CompactFormatter.format(Int((s.cacheHitRate * 100).rounded()))
            let line = "近 5h · ↑\(CompactFormatter.format(s.inputTokens)) · ↓\(CompactFormatter.format(s.outputTokens)) · ⚡\(CompactFormatter.format(s.cacheReadTokens)) · 🎯\(hit)%"
            menu.addItem(withTitle: line, action: nil, keyEquivalent: "")
        }
        menu.addItem(NSMenuItem.separator())
        addCaffeinateMenuItems(to: menu)
        menu.addItem(NSMenuItem.separator())
        addActionItem(menu, title: "偏好…", action: #selector(showSettings), key: ",")
        addActionItem(menu, title: "立即刷新", action: #selector(forceRefresh), key: "r")
        menu.addItem(NSMenuItem.separator())
        addActionItem(menu, title: "退出", action: #selector(quit), key: "q")
    }

    public func menuDidClose(_ menu: NSMenu) {
        caffeinateHeaderItem = nil
    }

    private func addCaffeinateMenuItems(to menu: NSMenu) {
        if let session = state.caffeinateSession {
            let remaining = session.remainingSeconds(now: Date())
            let label = "☕️ 阻止休眠 · 还剩 \(CountdownFormatter.format(remaining: remaining))"
            let header = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            caffeinateHeaderItem = header
        }

        let parent = NSMenuItem(title: "阻止系统休眠", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let active = state.caffeinateSession
        for bucket in CaffeinateBucket.allCases {
            let item = NSMenuItem(
                title: "\(bucket.label)\(active?.bucket == bucket ? " ✓" : "")",
                action: #selector(caffeinateBucket(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bucket.rawValue
            sub.addItem(item)
        }
        parent.submenu = sub
        menu.addItem(parent)
        if active != nil {
            addActionItem(menu, title: "取消守护", action: #selector(caffeinateCancel))
        }
    }

    private func addActionItem(_ menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func forceRefresh() {
        Task { @MainActor in await controller.tick() }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func showSettings() {
        onShowSettings()
    }

    @objc private func openReadme() {
        if let url = URL(string: "https://github.com/alfred-zhong/omp-companion") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func caffeinateBucket(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let bucket = CaffeinateBucket(rawValue: raw) else { return }
        sleepGuard.start(bucket: bucket)
    }

    @objc private func caffeinateCancel() {
        sleepGuard.cancel()
    }
}
