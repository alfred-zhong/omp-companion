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
    private var settingsStore = SettingsStore()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let home = NSHomeDirectory()
        let env = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath
        let agentDir: String = {
            if let p = env["PI_CODING_AGENT_DIR"], !p.isEmpty { return NSString(string: p).expandingTildeInPath }
            return "\(home)/.omp/agent"
        }()
        let sessionsRoot = "\(agentDir)/sessions"

        let creds = CredentialsResolver(homeDir: home, cwd: cwd)
        let config = ConfigSource(homeDir: home, cwd: cwd, env: env)
        let scanner = DailyUsageScanner(sessionsRoot: sessionsRoot)
        let controller = RefreshController(
            config: config,
            creds: creds,
            scanner: scanner,
            state: state,
            intervalSeconds: settingsStore.intervalSeconds
        )
        self.refreshController = controller

        let settingsCtrl = SettingsWindowController { [weak controller] newInterval in
            controller?.intervalSeconds = newInterval
        }
        self.settingsController = settingsCtrl

        let bar = StatusBarController(
            controller: controller,
            state: state,
            onShowSettings: { [weak settingsCtrl, weak settingsStore] in
                guard let s = settingsStore else { return }
                settingsCtrl?.show(store: s)
            }
        )
        settingsCtrl.attachStatusBar(bar)
        self.statusBar = bar
    }
}
