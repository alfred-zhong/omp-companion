import Foundation

/// 凭据解析：与 omp .env 链镜像。
/// 顺序：process env → <cwd>/.env → ~/.omp/agent/.env → ~/.omp/.env → ~/.env
public struct CredentialsResolver: Sendable {
    public let homeDir: String
    public let cwd: String

    public init(homeDir: String = NSHomeDirectory(), cwd: String = FileManager.default.currentDirectoryPath) {
        self.homeDir = homeDir
        self.cwd = cwd
    }

    /// 返回所有候选 .env 文件路径（按优先级从高到低）。
    public func candidateEnvFiles() -> [String] {
        let home = homeDir
        return [
            "\(cwd)/.env",
            "\(home)/.omp/agent/.env",
            "\(home)/.omp/.env",
            "\(home)/.env",
        ]
    }

    public func loadAll() -> [String: String] {
        var merged: [String: String] = [:]
        for path in candidateEnvFiles().reversed() {
            merged.merge(loadEnvFile(path: path), uniquingKeysWith: { _, new in new })
        }
        return merged
    }

    /// 合并后的最终 env：file 层 + process env（process env 压过一切）。
    public func mergedEnv() -> [String: String] {
        var env = loadAll()
        for (k, v) in ProcessInfo.processInfo.environment {
            env[k] = v
        }
        return env
    }

    public func resolve(_ key: String) -> String? {
        mergedEnv()[key]
    }

    // MARK: - .env parser

    static let keyPattern = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")

    func loadEnvFile(path: String) -> [String: String] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }
            guard let eq = stripped.firstIndex(of: "=") else { continue }
            let key = String(stripped[..<eq]).trimmingCharacters(in: .whitespaces)
            let keyRange = NSRange(key.startIndex..., in: key)
            guard Self.keyPattern.firstMatch(in: key, range: keyRange) != nil else { continue }
            var value = String(stripped[stripped.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.contains("\0") { continue }
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }
}
