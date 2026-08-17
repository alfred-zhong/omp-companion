import AppKit
import Foundation

/// StatusBar 展示层:把 AppState 转成 NSAttributedString / ChromeSpec / [NSMenuItem]。
///
/// interface 收敛为三个纯函数;StatusBarController 只剩 Timer、Combine 订阅、转发到 NSStatusItem。
/// - `renderTitle` 处理 4 路优先级 (CONTEXT.md: missingCredential > configMissing > balance > "···")
/// - `renderChrome` 输出胶囊外观参数
/// - `renderMenu` 重建弹出菜单 (含倒计时 header in-place 刷新 hook)
public enum StatusBarPresenter {

    // MARK: - Inputs
    /// 状态栏 / 菜单渲染所需的状态聚合。Controller 负责从 AppState 拉平后传入。
    public struct Inputs: Sendable {
        public let balance: BalanceSnapshot?
        public let missingCredential: String?
        public let configMissing: Bool
        public let caffeinateSession: CaffeinateSession?
        public let lastBalanceError: String?
        public let lastDailyError: String?
        public let daily: DailyUsageSnapshot?
        /// 当前 provider，logo 由 Controller 独立写 button.image；这里只是传递用，
        /// 未来 menu/popover 想展示品牌名时也能复用到。
        public let currentProvider: ProviderID?

        public init(
            balance: BalanceSnapshot? = nil,
            missingCredential: String? = nil,
            configMissing: Bool = false,
            caffeinateSession: CaffeinateSession? = nil,
            lastBalanceError: String? = nil,
            lastDailyError: String? = nil,
            daily: DailyUsageSnapshot? = nil,
            currentProvider: ProviderID? = nil
        ) {
            self.balance = balance
            self.missingCredential = missingCredential
            self.configMissing = configMissing
            self.caffeinateSession = caffeinateSession
            self.lastBalanceError = lastBalanceError
            self.lastDailyError = lastDailyError
            self.daily = daily
            self.currentProvider = currentProvider
        }
    }
    // MARK: - ChromeSpec

    /// 状态栏 button 的视觉参数。Controller 负责套到 NSButton 上,Presenter 不知道 NSButton 的存在。
    public struct ChromeSpec: Equatable, Sendable {
        public let background: NSColor
        public let cornerRadius: CGFloat
        public let contentTint: NSColor?

        public static let clear = ChromeSpec(background: .clear, cornerRadius: 0, contentTint: nil)
    }

    // MARK: - MenuSpec (倒计时 in-place 刷新 hook)

    /// 渲染菜单项:含可挂回调的钩子,Controller 用来 in-place 刷新倒计时文字。
    public struct MenuItemSpec {
        public let title: String
        public let enabled: Bool
        public let key: String
        /// `.separator` 时忽略
        public let action: MenuAction?
        /// 是否需要 in-place tick;Controller 会把这个 item 存为 `caffeinateHeaderItem` 并每 tick 调一次。
        public let tickable: Bool
        /// `representedObject == CaffeinateBucket.rawValue` 时勾选
        public let representedBucket: Int?
        public let submenu: [MenuItemSpec]?

        public enum MenuAction: Equatable, Sendable {
            case forceRefresh
            case quit
            case showSettings
            case openReadme
            case caffeinateBucket
            case caffeinateCancel
        }

        public static let separator = MenuItemSpec(
            title: "", enabled: true, key: "", action: nil, tickable: false,
            representedBucket: nil, submenu: nil
        )

        public init(
            title: String,
            enabled: Bool = true,
            key: String = "",
            action: MenuAction? = nil,
            tickable: Bool = false,
            representedBucket: Int? = nil,
            submenu: [MenuItemSpec]? = nil
        ) {
            self.title = title
            self.enabled = enabled
            self.key = key
            self.action = action
            self.tickable = tickable
            self.representedBucket = representedBucket
            self.submenu = submenu
        }
    }

    // MARK: - Constants

    /// 咖啡色近似值 (#8B5A2B),与 macOS Control Center 模块同色系。
    public static let caffeinateColor = NSColor(
        calibratedRed: 0x8B / 255.0,
        green: 0x5A / 255.0,
        blue: 0x2B / 255.0,
        alpha: 1.0
    )

    // MARK: - renderTitle

    /// 状态栏标题:missingCredential > configMissing > balance > "···"。
    /// 守护激活时在余额右侧追加 " ☕"(咖啡色),把视觉焦点留给主信息;
    /// balance text 周围按需补空格,避免胶囊裁切。
    /// 所有分支统一在头部补两个 Thin Space(\u{2009} ≈ 0.5pt),拉开 logo 与文字的间距;
    /// NSButton .imageLeft 自带约 4-5pt 系统间距,这段 padding 让视觉上有一档可感间距差。
    private static let logoTextGap: String = "\u{2009}\u{2009}"
    private static let caffeinateSuffix: String = " \u{2615}"
    public static func renderTitle(_ inputs: Inputs) -> NSAttributedString {
        let body: NSAttributedString
        if let missing = inputs.missingCredential {
            body = NSAttributedString(string: "\(logoTextGap)⚠︎\(missing.prefix(6))")
        } else if inputs.configMissing {
            body = NSAttributedString(string: "\(logoTextGap)?omp")
        } else if let balance = inputs.balance {
            let text = BalanceFormatter.statusBarText(balance.result)
            let active = inputs.caffeinateSession != nil
            let padded = active ? " \(text) " : text
            body = composeBalanced(balanceText: padded, isStale: balance.isStale, caffeinateActive: active)
        } else {
            body = NSAttributedString(string: "\(logoTextGap)···")
        }
        return body
    }

    private static func composeBalanced(
        balanceText: String,
        isStale: Bool,
        caffeinateActive: Bool
    ) -> NSAttributedString {
        let text = balanceText + (isStale ? "·off" : "")
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: logoTextGap))
        result.append(NSAttributedString(string: text))
        if caffeinateActive {
            let suffix = NSAttributedString(
                string: caffeinateSuffix,
                attributes: [.foregroundColor: caffeinateColor]
            )
            result.append(suffix)
        }
        return result
    }


    // MARK: - renderChrome

    /// 状态栏 button 胶囊参数。`active = caffeinateSession != nil`。
    public static func renderChrome(_ inputs: Inputs) -> ChromeSpec {
        if inputs.caffeinateSession != nil {
            return ChromeSpec(
                background: caffeinateColor,
                cornerRadius: StatusBarChromeMetrics.cornerRadius(buttonHeight: 18),
                contentTint: .white
            )
        }
        return .clear
    }

    // MARK: - renderMenu

    /// 弹出菜单:全部状态分支 + Caffeinate 子菜单 + 倒计时 header。
    public static func renderMenu(_ inputs: Inputs, now: Date = Date()) -> [MenuItemSpec] {
        if inputs.configMissing {
            return configMissingMenu()
        }
        if let missing = inputs.missingCredential {
            return missingCredentialMenu(missing)
        }
        return normalMenu(inputs, now: now)
    }

    private static func configMissingMenu() -> [MenuItemSpec] {
        return [
            MenuItemSpec(title: "未检测到 omp 配置", enabled: false),
            .separator,
            MenuItemSpec(title: "打开 README", action: .openReadme),
            .separator,
            MenuItemSpec(title: "刷新", key: "r", action: .forceRefresh),
            MenuItemSpec(title: "退出", key: "q", action: .quit),
        ]
    }

    private static func missingCredentialMenu(_ missing: String) -> [MenuItemSpec] {
        return [
            MenuItemSpec(title: "未找到 \(missing) 的 API key", enabled: false),
            MenuItemSpec(title: "请于 ~/.omp/agent/.env 设置", enabled: false),
            .separator,
            MenuItemSpec(title: "打开 README", action: .openReadme),
            .separator,
            MenuItemSpec(title: "刷新", key: "r", action: .forceRefresh),
            MenuItemSpec(title: "退出", key: "q", action: .quit),
        ]
    }

    private static func normalMenu(_ inputs: Inputs, now: Date) -> [MenuItemSpec] {
        var items: [MenuItemSpec] = []
        // 余额行
        if let balance = inputs.balance {
            let text = BalanceFormatter.menuBarText(balance.result)
            items.append(MenuItemSpec(
                title: "\(balance.result.provider.rawValue): \(text)",
                enabled: false
            ))
            if balance.result.currency == .percent,
               let reset = balance.result.resetRemaining,
               reset > 0 {
                items.append(MenuItemSpec(
                    title: "重置剩余时间: \(BalanceFormatter.formatHMS(reset))",
                    enabled: false
                ))
            }
        } else if let err = inputs.lastBalanceError {
            items.append(MenuItemSpec(title: "余额: \(err)", enabled: false))
        } else {
            items.append(MenuItemSpec(title: "余额: ···", enabled: false))
        }
        items.append(.separator)

        // 今日行
        if let daily = inputs.daily {
            items.append(MenuItemSpec(title: dailyLine(prefix: "今日", stats: daily.today), enabled: false))
        } else if let err = inputs.lastDailyError {
            items.append(MenuItemSpec(title: "今日: \(err)", enabled: false))
        } else {
            items.append(MenuItemSpec(title: "今日: ···", enabled: false))
        }
        // 近 5h
        if let daily = inputs.daily {
            items.append(MenuItemSpec(title: dailyLine(prefix: "近 5h", stats: daily.last5h), enabled: false))
        }
        items.append(.separator)

        // Caffeinate
        items.append(contentsOf: caffeinateItems(inputs, now: now))
        items.append(.separator)

        // 底部动作
        items.append(MenuItemSpec(title: "偏好…", key: ",", action: .showSettings))
        items.append(MenuItemSpec(title: "立即刷新", key: "r", action: .forceRefresh))
        items.append(.separator)
        items.append(MenuItemSpec(title: "退出", key: "q", action: .quit))
        return items
    }

    private static func dailyLine(prefix: String, stats: TokenStats) -> String {
        let hit = CompactFormatter.format(Int((stats.cacheHitRate * 100).rounded()))
        return "\(prefix) · ↑\(CompactFormatter.format(stats.inputTokens)) · ↓\(CompactFormatter.format(stats.outputTokens)) · ⚡\(CompactFormatter.format(stats.cacheReadTokens)) · 🎯\(hit)%"
    }

    private static func caffeinateItems(_ inputs: Inputs, now: Date) -> [MenuItemSpec] {
        var items: [MenuItemSpec] = []
        if let session = inputs.caffeinateSession {
            let remaining = session.remainingSeconds(now: now)
            let label = "☕️ 阻止休眠 · 还剩 \(CountdownFormatter.format(remaining: remaining))"
            items.append(MenuItemSpec(
                title: label, enabled: false, tickable: true
            ))
        }
        let activeBucket = inputs.caffeinateSession?.bucket
        let sub = CaffeinateBucket.allCases.map { b in
            MenuItemSpec(
                title: "\(b.label)\(activeBucket == b ? " ✓" : "")",
                action: .caffeinateBucket,
                representedBucket: b.rawValue
            )
        }
        items.append(MenuItemSpec(title: "阻止系统休眠", submenu: sub))
        if inputs.caffeinateSession != nil {
            items.append(MenuItemSpec(title: "取消守护", action: .caffeinateCancel))
        }
        return items
    }
}

/// 胶囊圆角:取 button 当前高度一半;Controller 已知 button 高度,这里只按默认值估。
/// 视觉差与现在 0.5% 内等价 —— 之前 inline `h / 2` 同样靠 `layoutSubtreeIfNeeded` 后读 bounds。
public enum StatusBarChromeMetrics {
    public static func cornerRadius(buttonHeight: CGFloat) -> CGFloat {
        max(buttonHeight, 1) / 2
    }
}
