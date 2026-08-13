import Foundation
import Yams

public struct OmpConfig: Sendable {
    public let defaultModel: String?

    public init(defaultModel: String?) {
        self.defaultModel = defaultModel
    }
}

/// 读 omp 配置：合并 `~/.omp/agent/config.yml` 与项目 `<cwd>/.omp/config.yml`。
/// 不读 runtime in-memory 覆盖（--model / --smol / PI_*_MODEL env vars）。
public struct ConfigSource: Sendable {
    public let homeDir: String
    public let cwd: String
    public let env: [String: String]

    public init(
        homeDir: String = NSHomeDirectory(),
        cwd: String = FileManager.default.currentDirectoryPath,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDir = homeDir
        self.cwd = cwd
        self.env = env
    }

    public var agentDir: String {
        if let override = env["PI_CODING_AGENT_DIR"], !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return "\(homeDir)/.omp/agent"
    }

    /// 全局配置文件路径（config.yml 优先，回退 config.yaml）。
    public var globalConfigPath: String {
        let yml = "\(agentDir)/config.yml"
        let yaml = "\(agentDir)/config.yaml"
        if FileManager.default.fileExists(atPath: yml) { return yml }
        return yaml
    }

    public var projectConfigPath: String {
        "\(cwd)/.omp/config.yml"
    }

    public func load() -> OmpConfig {
        var merged: [String: Any] = [:]
        if let global = loadYAML(path: globalConfigPath) {
            merged = deepMerge(base: merged, overlay: global)
        }
        if FileManager.default.fileExists(atPath: projectConfigPath),
           let project = loadYAML(path: projectConfigPath) {
            merged = deepMerge(base: merged, overlay: project)
        }
        let defaultModel = (merged["modelRoles"] as? [String: Any])?["default"] as? String
        return OmpConfig(defaultModel: defaultModel)
    }

    func loadYAML(path: String) -> [String: Any]? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        do {
            let parsed = try Yams.load(yaml: raw)
            return parsed as? [String: Any]
        } catch {
            return nil
        }
    }
}

/// omp 文档规定的对象 deep merge：高层 key 覆盖低层 key，但低层独有 key 保留；数组整体替换。
func deepMerge(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
    var result = base
    for (k, v) in overlay {
        if let baseDict = result[k] as? [String: Any], let overlayDict = v as? [String: Any] {
            result[k] = deepMerge(base: baseDict, overlay: overlayDict)
        } else {
            result[k] = v
        }
    }
    return result
}
