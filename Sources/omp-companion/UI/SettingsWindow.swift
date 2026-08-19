import AppKit
import SwiftUI

public final class SettingsStore: ObservableObject, @unchecked Sendable {
    @Published public var intervalSeconds: RefreshInterval {
        didSet { UserDefaults.standard.set(intervalSeconds.rawValue, forKey: "intervalSeconds") }
    }

    public init() {
        let stored = UserDefaults.standard.double(forKey: "intervalSeconds")
        let interval = RefreshInterval(rawValue: Int(stored)) ?? .default
        if stored > 0, interval.rawValue != Int(stored) {
            // 存量脏值（非 30/60/120）回退默认并写回自愈。
            UserDefaults.standard.set(interval.rawValue, forKey: "intervalSeconds")
        }
        self.intervalSeconds = interval
    }
}

public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onIntervalChange: (RefreshInterval) -> Void
    private weak var statusBar: StatusBarController?

    public init(onIntervalChange: @escaping (RefreshInterval) -> Void) {
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 90),
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
    let onIntervalChange: (RefreshInterval) -> Void

    var body: some View {
        HStack {
            Text("刷新间隔")
            Picker("刷新间隔", selection: $store.intervalSeconds) {
                ForEach(RefreshInterval.allCases, id: \.self) { option in
                    Text("\(option.rawValue)s").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: store.intervalSeconds) { newValue in
                onIntervalChange(newValue)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
