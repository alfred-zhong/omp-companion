import Foundation

/// 扫描 sessions 目录，mtime 剪枝 + 递归，调用 parser 收集事件。
public struct DailyUsageScanner: Sendable {
    public let sessionsRoot: String
    public let parser: JSONLLineParser

    public init(sessionsRoot: String, parser: JSONLLineParser = JSONLLineParser()) {
        self.sessionsRoot = sessionsRoot
        self.parser = parser
    }

    public func scan(now: Date = Date()) -> [ParsedEvent] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsRoot) else { return [] }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let todayStartMs = todayStartMs(now: now)
        let pruneBoundaryMs = min(todayStartMs, nowMs - Int64(HOUR_BUCKET_COUNT) * HOUR_MS)
        var seen = Set<String>()
        var events: [ParsedEvent] = []
        collect(
            dir: sessionsRoot,
            relPath: "",
            nowMs: nowMs,
            pruneBoundaryMs: pruneBoundaryMs,
            seen: &seen,
            out: &events
        )
        return events
    }

    private func collect(
        dir: String,
        relPath: String,
        nowMs: Int64,
        pruneBoundaryMs: Int64,
        seen: inout Set<String>,
        out: inout [ParsedEvent]
    ) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: dir)
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return
        }
        for entry in entries {
            let name = entry.lastPathComponent
            let childRel = relPath.isEmpty ? name : "\(relPath)/\(name)"
            let childPath = entry.path
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                collect(dir: childPath, relPath: childRel, nowMs: nowMs, pruneBoundaryMs: pruneBoundaryMs, seen: &seen, out: &out)
            } else if name.hasSuffix(".jsonl") {
                guard let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                    continue
                }
                let mtimeMs = Int64(mtime.timeIntervalSince1970 * 1000)
                // mtime 剪枝：mtime < pruneBoundaryMs 跳过
                guard mtimeMs >= pruneBoundaryMs else { continue }
                processFile(path: childPath, relPath: childRel, seen: &seen, out: &out)
            }
        }
    }

    private func processFile(path: String, relPath: String, seen: inout Set<String>, out: inout [ParsedEvent]) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let ev = parser.parse(line: String(line), relPath: relPath) else { continue }
            if seen.insert(ev.dedupeKey).inserted {
                out.append(ev)
            }
        }
    }

    /// 本机时区当日零点（ms）。
    public func todayStartMs(now: Date) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let startOfDay = cal.date(from: comps) ?? now
        return Int64(startOfDay.timeIntervalSince1970 * 1000)
    }
}
