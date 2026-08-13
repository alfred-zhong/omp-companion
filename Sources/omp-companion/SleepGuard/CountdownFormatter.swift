import Foundation

/// 守护会话剩余时间文案。
///
/// - `≥ 1 分钟`：显示 `Xm`（逐分钟，分钟整数）
/// - `< 1 分钟`：显示 `Xs`（逐秒）
public enum CountdownFormatter {
    public static func format(remaining: TimeInterval) -> String {
        if remaining <= 0 { return "0s" }
        if remaining < 60 {
            let s = max(1, Int(remaining.rounded()))
            return "\(s)s"
        }
        let minutes = Int(remaining / 60)
        return "\(minutes)m"
    }
}
