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
    /// 按 provider + chrome 状态缓存 NSImage(caffeinate 激活时缓存白色副本)。
    /// key 形如 `provider.rawValue#idle|active`,避免每 tick 重新 lockFocus 渲染。
    private var logoCacheColored: [String: NSImage] = [:]
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

    private func wireState() {
        let bridge: () -> Void = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshAll() }
        }
        state.$balance.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$balanceUnavailableFor.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$daily.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$lastBalanceError.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$lastDailyError.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$configMissing.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$missingCredential.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$unmatchedProvider.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$currentProvider.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshLogo() }
        }.store(in: &cancellables)
        state.$caffeinateSession.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$countdownTick.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshCaffeinateHeaderInPlace() }
        }.store(in: &cancellables)
    }

    private func currentInputs() -> StatusBarPresenter.Inputs {
        StatusBarPresenter.Inputs(
            balance: state.balance,
            balanceUnavailableFor: state.balanceUnavailableFor,
            missingCredential: state.missingCredential,
            configMissing: state.configMissing,
            caffeinateSession: state.caffeinateSession,
            lastBalanceError: state.lastBalanceError,
            lastDailyError: state.lastDailyError,
            daily: state.daily,
            currentProvider: state.currentProvider,
            currentModel: state.currentModel,
            unmatchedProvider: state.unmatchedProvider
        )
    }

    // MARK: - Render forwarding

    @MainActor
    private func refreshAll() {
        let inputs = currentInputs()
        statusItem.button?.attributedTitle = StatusBarPresenter.renderTitle(inputs)
        applyChrome(StatusBarPresenter.renderChrome(inputs))
        refreshLogo()
    }

    /// 把当前 provider 的 logo 写到 status button。LogoCatalog 内部已 template 标记。
    /// caffeinate 激活时(template 在带背景色的 button 上渲染会失效)用一张预填白色的副本,
    /// 保证 logo 始终与胶囊文字同色。
    /// 缓存到本地字段,避免每次刷新触发 I/O。
    @MainActor
    private func refreshLogo() {
        let pid = state.currentProvider
        let key = pid ?? .unknown
        let active = state.caffeinateSession != nil
        let cacheKey = "\(key.rawValue)#\(active ? "active" : "idle")"
        let img: NSImage?
        if let cached = logoCacheColored[cacheKey] {
            img = cached
        } else if let base = LogoCatalog.image(for: key) {
            img = active ? Self.whiteFilled(template: base) : base
            logoCacheColored[cacheKey] = img
        } else {
            img = nil
        }
        statusItem.button?.image = img
        statusItem.button?.imagePosition = .imageLeft
    }


    /// 把 template image 重新绘制成"alpha mask + 纯白"版本,得到非 template 的白色 image。
    /// 用于 caffeinate 激活期:`button.contentTintColor` 在带 backgroundColor 的状态下不可靠,
    /// 直接预乘白色更稳。
    private static func whiteFilled(template: NSImage) -> NSImage {
        let size = template.size
        let out = NSImage(size: size)
        out.lockFocus()
        defer { out.unlockFocus() }
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        template.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: size),
            operation: .destinationIn,
            fraction: 1.0
        )
        out.setValue(false, forKey: "template")
        return out
    }

    @MainActor
    private func applyChrome(_ spec: StatusBarPresenter.ChromeSpec) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
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
        if let usageBar = spec.usageBar {
            let item = NSMenuItem()
            item.view = UsageBarMenuItemView(leftText: usageBar.leftText, value: usageBar.value, percentText: usageBar.percentText, resetText: usageBar.resetText)
            item.isEnabled = false
            menu.addItem(item)
            return item
        }
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
            _ = sleepGuard.start(bucket: bucket)
        }
    }

    @objc private func caffeinateCancel() {
        MainActor.assumeIsolated {
            sleepGuard.cancel()
        }
    }
}
