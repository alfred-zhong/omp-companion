import Foundation

/// 把 BalanceResult 格式化为状态栏展示文案。
public enum BalanceFormatter {
    public static func statusBarText(_ result: BalanceResult) -> String {
        switch result.currency {
        case .cny:
            return String(format: "¥%.2f", result.balance)
        case .percent:
            let used = Int(result.usedPercent ?? max(0, 100 - result.balance))
            if let reset = result.resetRemaining, reset > 0 {
                return "\(used)%: \(formatHMS(reset))"
            }
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
