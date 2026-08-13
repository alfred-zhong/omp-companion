import AppKit
import SwiftUI

public final class SettingsStore: ObservableObject, @unchecked Sendable {
    @Published public var intervalSeconds: Double {
        didSet { UserDefaults.standard.set(intervalSeconds, forKey: "intervalSeconds") }
    }
    @Published public var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }

    public init() {
        let stored = UserDefaults.standard.double(forKey: "intervalSeconds")
        self.intervalSeconds = stored > 0 ? stored : 60
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
    }
}

public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onIntervalChange: (Double) -> Void
    private weak var statusBar: StatusBarController?

    public init(onIntervalChange: @escaping (Double) -> Void) {
        self.onIntervalChange = onIntervalChange
    }

    public func attachStatusBar(_ bar: StatusBarController) {
        self.statusBar = bar
    }

    public func show(store: SettingsStore) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(store: store, onIntervalChange: { [weak self] v in
            self?.onIntervalChange(v)
            self?.statusBar?.restartTimer()
        })
        let host = NSHostingController(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.contentViewController = host
        w.title = "omp-companion 偏好"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let onIntervalChange: (Double) -> Void

    var body: some View {
        Form {
            Section(header: Text("刷新")) {
                HStack {
                    Text("刷新间隔")
                    Slider(value: $store.intervalSeconds, in: 20...600, step: 10) { editing in
                        if !editing { onIntervalChange(store.intervalSeconds) }
                    }
                    Text("\(Int(store.intervalSeconds))s")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            }
            Section(header: Text("启动")) {
                Toggle("开机自启（占位，本版本不启用）", isOn: $store.launchAtLogin)
                    .disabled(true)
            }
            Section(header: Text("关于")) {
                Button("打开 README") {
                    if let url = URL(string: "https://github.com/alfred-zhong/omp-companion") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
