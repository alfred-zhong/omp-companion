import Foundation

/// 余额文案格式化:`statusBarText` 给状态栏标题(精简),`menuBarText` 给下拉菜单(详细)。
public enum BalanceFormatter {
    /// 状态栏标题文案:百分比类型**只展示使用额度**,不附带过期时间。
    public static func statusBarText(_ result: BalanceResult) -> String {
        switch result.currency {
        case .cny:
            return String(format: "¥%.2f", result.balance)
        case .percent:
            let used = Int(result.usedPercent ?? max(0, 100 - result.balance))
            return "\(used)%"
        }
    }

    /// 下拉菜单余额段(`BalanceResult` → 余额文案,不含 provider 前缀)。
    /// percent:始终返回 `"8%"`(有 reset 时,reset 另起一行由 `StatusBarPresenter` 拼装);cny:`"¥12.50"`。
    public static func menuBarText(_ result: BalanceResult) -> String {
        switch result.currency {
        case .cny:
            return String(format: "¥%.2f", result.balance)
        case .percent:
            let used = Int(result.usedPercent ?? max(0, 100 - result.balance))
            return "\(used)%"
        }
    }

    public static func formatHMS(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return "\(h)h\(m)m"
    }
}
