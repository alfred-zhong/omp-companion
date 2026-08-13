import AppKit
import Combine
import SwiftUI

public final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: RefreshController
    private let state: AppState
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var onShowSettings: () -> Void

    public init(
        controller: RefreshController,
        state: AppState,
        onShowSettings: @escaping () -> Void
    ) {
        self.controller = controller
        self.state = state
        self.onShowSettings = onShowSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        self.statusItem.button?.title = "···"
        self.statusItem.menu = NSMenu()
        self.statusItem.menu?.delegate = self
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
    }

    @MainActor
    private func updateTitle() {
        if let missing = state.missingCredential {
            statusItem.button?.title = "⚠︎\(missing.prefix(6))"
        } else if state.configMissing {
            statusItem.button?.title = "?omp"
        } else if let balance = state.balance {
            statusItem.button?.title = BalanceFormatter.statusBarText(balance.result) + (balance.isStale ? "·off" : "")
        } else {
            statusItem.button?.title = "···"
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
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
        addActionItem(menu, title: "偏好…", action: #selector(showSettings), key: ",")
        addActionItem(menu, title: "立即刷新", action: #selector(forceRefresh), key: "r")
        menu.addItem(NSMenuItem.separator())
        addActionItem(menu, title: "退出", action: #selector(quit), key: "q")
    }

    /// 创建带 target 的菜单项：不设 target 时 menu 自动禁用（灰色）。
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
}
