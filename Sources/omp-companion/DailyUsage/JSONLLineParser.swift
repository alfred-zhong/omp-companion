import Foundation

/// JSONL 行解析：行预过滤 + JSON.parse + 结构校验 + (relPath, eventId) 复合去重键。
public struct JSONLLineParser: Sendable {
    public init() {}

    /// 解析单行。返回 `nil` 表示不计入统计。
    /// - Parameters:
    ///   - line: 原始一行（不含换行符）
    ///   - relPath: 相对 sessions 根目录的 POSIX 路径，用作去重键的 file 段
    public func parse(line: String, relPath: String) -> ParsedEvent? {
        // 行预过滤：必须同时含 "assistant" 与 "usage" 子串
        guard line.contains("\"assistant\""), line.contains("\"usage\"") else { return nil }
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (json["type"] as? String) == "message" else { return nil }
        guard let message = json["message"] as? [String: Any] else { return nil }
        guard (message["role"] as? String) == "assistant" else { return nil }
        guard let usage = message["usage"] as? [String: Any] else { return nil }

        // 时刻解析：message.timestamp（epoch ms）→ 事件级 timestamp（ISO 字符串）
        let tsMs: Int64
        if let mt = message["timestamp"] as? Double {
            tsMs = Int64(mt)
        } else if let mt = message["timestamp"] as? Int64 {
            tsMs = mt
        } else if let et = json["timestamp"] as? String, let parsed = parseISOMs(et) {
            tsMs = parsed
        } else {
            return nil
        }

        let input = intValue(usage["input"])
        let output = intValue(usage["output"])
        let cacheRead = intValue(usage["cacheRead"])
        let cacheWrite = intValue(usage["cacheWrite"])

        // 事件级 id（不在 message 对象内）
        let eventId = (json["id"] as? String) ?? ""

        return ParsedEvent(
            tsMs: tsMs,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            dedupeKey: "\(relPath):\(eventId)"
        )
    }

    private func intValue(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let i = Int(s) { return i }
        return 0
    }

    private func parseISOMs(_ s: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: s) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        return nil
    }
}

public struct ParsedEvent: Sendable, Equatable {
    public let tsMs: Int64
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let dedupeKey: String
}
