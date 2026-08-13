import Foundation

public enum CompactFormatter {
    /// K/M/B 进位：999_950 → "1.0M"（避免出现 "1000K"）。
    public static func format(_ n: Int) -> String {
        let absN = abs(n)
        if absN < 1_000 { return "\(n)" }
        if absN < 1_000_000 {
            let v = Double(n) / 1_000
            if absN >= 999_500 { return "1.0M" }
            return trimNumber(String(v)) + "K"
        }
        if absN < 1_000_000_000 {
            let v = Double(n) / 1_000_000
            return trimNumber(String(v)) + "M"
        }
        let v = Double(n) / 1_000_000_000
        return trimNumber(String(v)) + "B"
    }

    private static func trimNumber(_ s: String) -> String {
        // 仅处理数字字符串，保留 1 位小数（"1.0"、"1.5"、"12.3"）
        guard let dot = s.firstIndex(of: ".") else { return s }
        let after = s.index(after: dot)
        let frac = s[after...]
        if frac.isEmpty { return String(s[..<dot]) }
        let oneDigit = String(frac.prefix(1))
        return String(s[..<after]) + oneDigit
    }

    private static func trim(_ s: String) -> String {
        // 期望：保留 1 位小数（"1.0K"、"1.5K"、"12.3K"、"1.0M"）
        // 整数无小数点直接返回
        guard let dot = s.firstIndex(of: ".") else { return s }
        let after = s.index(after: dot)
        let frac = s[after...]
        if frac.isEmpty { return String(s[..<dot]) }
        // 始终保留 1 位小数
        let oneDigit = String(frac.prefix(1))
        return String(s[..<after]) + oneDigit
    }
}
