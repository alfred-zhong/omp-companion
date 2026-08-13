import AppKit
import QuartzCore
import Combine
import Foundation

/// StatusBar controller:Timer / Combine 订阅 / 把 StatusBarPresenter 输出写到 NSStatusItem + NSMenu。
/// 全部"AppState → 视觉"逻辑已迁出到 `StatusBarPresenter`(纯函数)。
public final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: RefreshController
    private let state: AppState
    private let sleepGuard: SleepGuard
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var onShowSettings: () -> Void
    private var caffeinateHeaderItem: NSMenuItem?
    private var caffeinateHeaderSpec: StatusBarPresenter.MenuItemSpec?

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

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: controller.intervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.controller.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Wiring

    private func wireState() {
        let bridge: (Any) -> Void = { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshAll() }
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

    private func currentInputs() -> StatusBarPresenter.Inputs {
        StatusBarPresenter.Inputs(
            balance: state.balance,
            missingCredential: state.missingCredential,
            configMissing: state.configMissing,
            caffeinateSession: state.caffeinateSession,
            lastBalanceError: state.lastBalanceError,
            lastDailyError: state.lastDailyError,
            daily: state.daily
        )
    }

    // MARK: - Render forwarding

    @MainActor
    private func refreshAll() {
        let inputs = currentInputs()
        statusItem.button?.attributedTitle = StatusBarPresenter.renderTitle(inputs)
        applyChrome(StatusBarPresenter.renderChrome(inputs))
    }

    @MainActor
    private func applyChrome(_ spec: StatusBarPresenter.ChromeSpec) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layoutSubtreeIfNeeded()
        let h = max(button.bounds.height, 1)
        button.layer?.backgroundColor = spec.background.cgColor
        button.layer?.cornerRadius = spec == .clear
            ? 0
            : StatusBarChromeMetrics.cornerRadius(buttonHeight: h)
        button.contentTintColor = spec.contentTint
        // 去掉状态栏上的补间动画(闪现)。补间会受系统半透明材质干扰。
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

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        caffeinateHeaderItem = nil
        caffeinateHeaderSpec = nil
        let specs = StatusBarPresenter.renderMenu(currentInputs(), now: Date())
        for spec in specs {
            if let item = installItem(spec, into: menu) {
                if spec.tickable {
                    caffeinateHeaderItem = item
                    caffeinateHeaderSpec = spec
                }
            }
        }
    }

    public func menuDidClose(_ menu: NSMenu) {
        caffeinateHeaderItem = nil
        caffeinateHeaderSpec = nil
    }

    // MARK: - MenuItem installation

    @MainActor
    private func installItem(
        _ spec: StatusBarPresenter.MenuItemSpec,
        into menu: NSMenu
    ) -> NSMenuItem? {
        if spec.submenu == nil && spec.action == nil && spec.title.isEmpty {
            menu.addItem(NSMenuItem.separator())
            return nil
        }
        let item = NSMenuItem(
            title: spec.title,
            action: actionSelector(for: spec.action),
            keyEquivalent: spec.key
        )
        item.target = self
        item.isEnabled = spec.enabled
        if let bucket = spec.representedBucket {
            item.representedObject = bucket
        }
        if let sub = spec.submenu {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in sub {
                _ = installItem(child, into: submenu)
            }
            item.submenu = submenu
        }
        menu.addItem(item)
        return item
    }

    private func actionSelector(for action: StatusBarPresenter.MenuItemSpec.MenuAction?) -> Selector? {
        switch action {
        case .forceRefresh: return #selector(forceRefresh)
        case .quit: return #selector(quit)
        case .showSettings: return #selector(showSettings)
        case .openReadme: return #selector(openReadme)
        case .caffeinateBucket: return #selector(caffeinateBucket(_:))
        case .caffeinateCancel: return #selector(caffeinateCancel)
        case nil: return nil
        }
    }

    // MARK: - Actions

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
        MainActor.assumeIsolated {
            sleepGuard.start(bucket: bucket)
        }
    }

    @objc private func caffeinateCancel() {
        MainActor.assumeIsolated {
            sleepGuard.cancel()
        }
    }
}
