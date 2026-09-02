import AppKit
import SwiftUI

public final class SettingsStore: ObservableObject, @unchecked Sendable, CcccapiCredentialSource, CredentialSource {
    @Published public var intervalSeconds: RefreshInterval {
        didSet { UserDefaults.standard.set(intervalSeconds.rawValue, forKey: "intervalSeconds") }
    }
    /// ccccapi 登录邮箱（ADR-0007：偏好面板配置，非 `.env`）。
    @Published public var ccccapiEmail: String {
        didSet { UserDefaults.standard.set(ccccapiEmail, forKey: "ccccapiEmail") }
    }
    /// ccccapi 登录密码（ADR-0007：偏好面板配置，非 `.env`；UserDefaults 明文，接受此取舍）。
    @Published public var ccccapiPassword: String {
        didSet { UserDefaults.standard.set(ccccapiPassword, forKey: "ccccapiPassword") }
    }
    /// DeepSeek API key（ADR-0008：偏好面板配置，非 `.env`；UserDefaults 明文）。
    @Published public var deepseekApiKey: String {
        didSet { UserDefaults.standard.set(deepseekApiKey, forKey: "deepseekApiKey") }
    }
    /// MiniMax Token Plan API key（ADR-0008：偏好面板配置，非 `.env`；UserDefaults 明文）。
    @Published public var minimaxApiKey: String {
        didSet { UserDefaults.standard.set(minimaxApiKey, forKey: "minimaxApiKey") }
    }
    /// MiniMax Coding Plan CN API key（ADR-0008：偏好面板配置，非 `.env`；UserDefaults 明文）。
    @Published public var minimaxCodeCNApiKey: String {
        didSet { UserDefaults.standard.set(minimaxCodeCNApiKey, forKey: "minimaxCodeCNApiKey") }
    }
    /// OpenCode Go API key（ADR-0008：偏好面板配置，非 `.env`；UserDefaults 明文）。
    @Published public var opencodeApiKey: String {
        didSet { UserDefaults.standard.set(opencodeApiKey, forKey: "opencodeApiKey") }
    }

    public init() {
        let stored = UserDefaults.standard.double(forKey: "intervalSeconds")
        let interval = RefreshInterval(rawValue: Int(stored)) ?? .default
        if stored > 0, interval.rawValue != Int(stored) {
            // 存量脏值（非 30/60/120）回退默认并写回自愈。
            UserDefaults.standard.set(interval.rawValue, forKey: "intervalSeconds")
        }
        self.intervalSeconds = interval
        self.ccccapiEmail = UserDefaults.standard.string(forKey: "ccccapiEmail") ?? ""
        self.ccccapiPassword = UserDefaults.standard.string(forKey: "ccccapiPassword") ?? ""
        self.deepseekApiKey = UserDefaults.standard.string(forKey: "deepseekApiKey") ?? ""
        self.minimaxApiKey = UserDefaults.standard.string(forKey: "minimaxApiKey") ?? ""
        self.minimaxCodeCNApiKey = UserDefaults.standard.string(forKey: "minimaxCodeCNApiKey") ?? ""
        self.opencodeApiKey = UserDefaults.standard.string(forKey: "opencodeApiKey") ?? ""
    }

    /// `CredentialSource` 实现：把旧 `.env` 变量名映射到偏好面板字段。
    /// 空 / 全空白视为缺失（保持 provider `hasCredential` 语义不变）。
    public func resolve(_ name: String) -> String? {
        let raw: String
        switch name {
        case "DEEPSEEK_API_KEY": raw = deepseekApiKey
        case "MINIMAX_API_KEY": raw = minimaxApiKey
        case "MINIMAX_CODE_CN_API_KEY": raw = minimaxCodeCNApiKey
        case "OPENCODE_API_KEY": raw = opencodeApiKey
        default: return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onIntervalChange: (RefreshInterval) -> Void
    private let onTestConnection: () async -> String?
    private weak var statusBar: StatusBarController?

    public init(
        onIntervalChange: @escaping (RefreshInterval) -> Void,
        onTestConnection: @escaping () async -> String? = { nil }
    ) {
        self.onIntervalChange = onIntervalChange
        self.onTestConnection = onTestConnection
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
        let view = SettingsView(
            store: store,
            onIntervalChange: { [weak self] v in
                self?.onIntervalChange(v)
                self?.statusBar?.restartTimer()
            },
            onTestConnection: onTestConnection
        )
        let host = NSHostingController(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
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
    let onTestConnection: () async -> String?
    @State private var testResult: String?   // nil = 未测; 空 = 成功; 非空 = 失败文案
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("ccccapi 账号").font(.headline)
                TextField("邮箱", text: $store.ccccapiEmail)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $store.ccccapiPassword)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button("测试连接") { runTest() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let r = testResult {
                    Text(r.isEmpty ? "连接成功" : r)
                        .font(.caption)
                        .foregroundColor(r.isEmpty ? .green : .red)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Provider API Keys").font(.headline)
                SecureField("DeepSeek API Key", text: $store.deepseekApiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("MiniMax API Key（Token Plan）", text: $store.minimaxApiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("MiniMax Coding Plan CN API Key", text: $store.minimaxCodeCNApiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("OpenCode Go API Key", text: $store.opencodeApiKey)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            let res = await onTestConnection()
            await MainActor.run {
                testResult = res
                testing = false
            }
        }
    }
}
