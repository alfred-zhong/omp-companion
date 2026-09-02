import Foundation

/// 生产 BalanceSource:持有 ConfigSource + CredentialSource + HTTPClient。
/// Provider 路由走 BalanceRegistry 静态方法(与 SelfCheck 对齐)。
public struct LiveBalanceSource: BalanceSource {
    public let config: ConfigSource
    public let creds: any CredentialSource
    public let http: HTTPClient
    /// ccccapi 会话管理器（ADR-0007）；nil 时 ccccapi 视为无凭据。
    public let ccccapiSession: CcccapiSessionManager?

    public init(
        config: ConfigSource,
        creds: any CredentialSource,
        http: HTTPClient = URLSessionHTTPClient(),
        ccccapiSession: CcccapiSessionManager? = nil
    ) {
        self.config = config
        self.creds = creds
        self.http = http
        self.ccccapiSession = ccccapiSession
    }

    public func capture(now: Date) async -> (BalanceSnapshot?, SnapshotError?, model: String?) {
        let cfg = config.load()
        let model = cfg.defaultModel
        guard let defaultModel = model, !defaultModel.isEmpty else {
            return (nil, .configMissing, model: model)
        }
        let trimmedModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmedModel.firstIndex(of: "/"),
              slash != trimmedModel.startIndex,
              trimmedModel.index(after: slash) != trimmedModel.endIndex else {
            return (nil, .fetchError("默认模型格式无效（\(defaultModel)）"), model: defaultModel)
        }
        let providerName = String(trimmedModel[..<slash])
        let pid = BalanceRegistry.providerID(fromDefaultModel: trimmedModel)
        guard let provider = BalanceRegistry.provider(for: pid, ccccapiSession: ccccapiSession) else {
            return (nil, .unmatchedProvider(providerName), model: trimmedModel)
        }
        guard provider.hasCredential(creds: creds) else {
            return (nil, .missingCredential(pid.rawValue), model: model)
        }
        do {
            let result = try await provider.fetch(creds: creds, http: http)
            let snap = BalanceSnapshot(
                result: result,
                capturedAt: now,
                quotaWindows: result.quotaWindows
            )
            return (snap, nil, model: model)
        } catch {
            return (nil, .fetchError(Self.humanReadable(error)), model: model)
        }
    }

    static func humanReadable(_ error: Error) -> String {
        if let cccc = error as? CcccapiAuthError {
            switch cccc {
            case .notConfigured: return "ccccapi 未配置邮箱/密码"
            case .credentialInvalid: return "账号登录失败: 凭据无效"
            case .requires2FA: return "账户开启了 2FA，暂不支持自动登录"
            case .refreshRejected: return "刷新被拒绝，请重新登录"
            case .sessionBindingMismatch: return "会话绑定不匹配，请重新登录"
            }
        }
        if let http = error as? HTTPError {
            switch http {
            case .timeout: return "请求超时 (10 秒)"
            case .unauthorized(let status): return "鉴权失败 (\(status))"
            case .rateLimited: return "请求过快 (429)"
            case .server(let s): return "服务异常 (\(s))"
            case .invalidResponse: return "响应解析失败"
            case .missingCredential: return "凭据缺失"
            }
        }
        return error.localizedDescription
    }
}
