import Foundation

/// 生产 BalanceSource:持有 ConfigSource + CredentialsResolver + HTTPClient。
/// Provider 路由走 BalanceRegistry 静态方法(与 SelfCheck 对齐)。
public struct LiveBalanceSource: BalanceSource {
    public let config: ConfigSource
    public let creds: CredentialsResolver
    public let http: HTTPClient

    public init(
        config: ConfigSource,
        creds: CredentialsResolver,
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.config = config
        self.creds = creds
        self.http = http
    }

    public func capture(now: Date) async -> (BalanceSnapshot?, SnapshotError?) {
        let cfg = config.load()
        guard let defaultModel = cfg.defaultModel, !defaultModel.isEmpty else {
            return (nil, .configMissing)
        }
        let pid = BalanceRegistry.providerID(fromDefaultModel: defaultModel)
        guard let provider = BalanceRegistry.provider(for: pid) else {
            return (nil, .fetchError("未匹配到服务商（\(defaultModel)）"))
        }
        guard provider.hasCredential(creds: creds) else {
            return (nil, .missingCredential(pid.rawValue))
        }
        do {
            let result = try await provider.fetch(creds: creds, http: http)
            let snap = BalanceSnapshot(
                result: result,
                capturedAt: now,
                quotaWindows: result.quotaWindows
            )
            return (snap, nil)
        } catch {
            return (nil, .fetchError(humanReadable(error)))
        }
    }

    private func humanReadable(_ error: Error) -> String {
        if let http = error as? HTTPError {
            switch http {
            case .timeout: return "请求超时 (10 秒)"
            case .unauthorized: return "鉴权失败 (401)"
            case .rateLimited: return "请求过快 (429)"
            case .server(let s): return "服务异常 (\(s))"
            case .invalidResponse: return "响应解析失败"
            case .missingCredential: return "凭据缺失"
            }
        }
        return error.localizedDescription
    }
}
