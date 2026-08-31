import Foundation

/// 凭据解析：与 omp .env 链镜像。
/// 顺序：process env → <cwd>/.env → agent/.env → ~/.omp/.env → ~/.env；agent 默认位于 ~/.omp/agent，PI_CODING_AGENT_DIR 可重定位。
public struct CredentialsResolver: Sendable {
    public let homeDir: String
    public let cwd: String
    public let environment: [String: String]

    public init(
        homeDir: String = NSHomeDirectory(),
        cwd: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDir = homeDir
        self.cwd = cwd
        self.environment = environment
    }

    /// 返回所有候选 .env 文件路径（按优先级从高到低）。
    public func candidateEnvFiles() -> [String] {
        let home = homeDir
        let agentDir: String
        if let override = environment["PI_CODING_AGENT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            agentDir = NSString(string: override).expandingTildeInPath
        } else {
            agentDir = "\(home)/.omp/agent"
        }
        return [
            "\(cwd)/.env",
            "\(agentDir)/.env",
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

    /// 合并后的最终 env：文件层 + 注入的进程环境（进程环境压过一切）。
    public func mergedEnv() -> [String: String] {
        var env = loadAll()
        for (k, v) in environment {
            env[k] = v
        }
        return env
    }

    /// 返回非空凭据；空字符串和全空白值视为缺失。
    public func resolve(_ key: String) -> String? {
        guard let value = mergedEnv()[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
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
