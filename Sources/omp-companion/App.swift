import AppKit
import Foundation

@main
public enum OmpCompanion {
    public static func main() {
        if CommandLine.arguments.contains("--self-check") {
            let code = SelfCheck.run()
            exit(Int32(code))
        }
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 关键：无 Dock 图标
        app.delegate = delegate
        app.run()
    }
}
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var settingsController: SettingsWindowController?
    private var state = AppState()
    private var refreshController: RefreshController?
    private var sleepGuard: SleepGuard?
    private var settingsStore = SettingsStore()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let home = NSHomeDirectory()
        let env = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath
        let agentDir: String = {
            if let p = env["PI_CODING_AGENT_DIR"], !p.isEmpty { return NSString(string: p).expandingTildeInPath }
            return "\(home)/.omp/agent"
        }()
        let sessionsRoot = "\(agentDir)/sessions"

        let config = ConfigSource(homeDir: home, cwd: cwd, env: env)
        let scanner = DailyUsageScanner(sessionsRoot: sessionsRoot)
        let ccccapiSession = CcccapiSessionManager(credentials: settingsStore, http: URLSessionHTTPClient())
        let balanceSource = LiveBalanceSource(config: config, creds: settingsStore, ccccapiSession: ccccapiSession)
        let dailySource = LiveDailyUsageSource(scanner: scanner)
        let controller = RefreshController(
            balanceSource: balanceSource,
            dailySource: dailySource,
            state: state,
            intervalSeconds: settingsStore.intervalSeconds.seconds
        )
        self.refreshController = controller

        let guard_ = SleepGuard(state: state)
        self.sleepGuard = guard_

        let settingsCtrl = SettingsWindowController(
            onIntervalChange: { [weak controller] newInterval in
                controller?.intervalSeconds = newInterval.seconds
            },
            onTestConnection: { [weak ccccapiSession] in
                guard let s = ccccapiSession else { return "ccccapi 未配置" }
                do {
                    try await s.testConnection()
                    return nil
                } catch {
                    return LiveBalanceSource.humanReadable(error)
                }
            }
        )
        self.settingsController = settingsCtrl

        let bar = StatusBarController(
            controller: controller,
            state: state,
            sleepGuard: guard_,
            onShowSettings: { [weak settingsCtrl, weak settingsStore] in
                guard let s = settingsStore else { return }
                settingsCtrl?.show(store: s)
            }
        )
        settingsCtrl.attachStatusBar(bar)
        self.statusBar = bar
    }

    /// 菜单栏 accessory 应用无默认主菜单：装一个最小 Edit 菜单，让设置窗口的文本域
    /// 能响应 Cmd+V / Cmd+C / Cmd+X / Cmd+A 等编辑快捷键（粘贴等经 `paste:` 路由到 first responder）。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 omp-companion", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 omp-companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSTextView.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSTextView.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSTextView.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSTextView.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // 退出时静默 release；SleepGuard.deinit 也会兜底。
        sleepGuard?.cancel()
    }
}
