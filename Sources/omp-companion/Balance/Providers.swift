import Foundation

public protocol BalanceProvider: Sendable {
    var id: ProviderID { get }
    /// 校验该 Provider 是否有可用的鉴权凭据。
    func hasCredential(creds: CredentialsResolver) -> Bool
    /// 拉取余额。
    func fetch(creds: CredentialsResolver, http: HTTPClient) async throws -> BalanceResult
}

// MARK: - DeepSeek

public struct DeepSeekProvider: BalanceProvider {
    public let id: ProviderID = .deepseek
    public init() {}

    public func hasCredential(creds: CredentialsResolver) -> Bool {
        creds.resolve("DEEPSEEK_API_KEY") != nil
    }

    public func fetch(creds: CredentialsResolver, http: HTTPClient) async throws -> BalanceResult {
        guard let key = creds.resolve("DEEPSEEK_API_KEY") else {
            throw HTTPError.missingCredential
        }
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        let (data, _) = try await http.get(
            url: url,
            headers: ["Authorization": "Bearer \(key)"],
            timeoutSeconds: 10
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // DeepSeek 响应: { is_available, balance_infos: [{ currency, total_balance, granted_balance, topped_up_balance }] }
        // 字段是 total_balance(字符串),非 balance
        let balanceInfos = (json?["balance_infos"] as? [[String: Any]]) ?? []
        var totalBalance: Double = 0
        if let first = balanceInfos.first {
            if let s = first["total_balance"] as? String, let v = Double(s) {
                totalBalance = v
            } else if let d = first["total_balance"] as? Double {
                totalBalance = d
            }
        }
        return BalanceResult(
            provider: .deepseek,
            balance: totalBalance,
            currency: .cny
        )
    }
}

// MARK: - MiniMax (Token Plan / Coding Plan CN 共享)

/// MiniMax 系列余额 provider:`/v1/{token_plan|coding_plan}/remains` 端点,响应 schema 一致。
///
/// 差异只在三个字段:`endpoint` URL、`credentialKey` 环境变量名、`id` 路由结果。
/// `BalanceRegistry` 注册时各填一份。
public struct MiniMaxRemainsProvider: BalanceProvider {
    public let id: ProviderID
    public let endpoint: URL
    public let credentialKey: String

    public init(id: ProviderID, endpoint: URL, credentialKey: String) {
        self.id = id
        self.endpoint = endpoint
        self.credentialKey = credentialKey
    }

    public func hasCredential(creds: CredentialsResolver) -> Bool {
        creds.resolve(credentialKey) != nil
    }

    public func fetch(creds: CredentialsResolver, http: HTTPClient) async throws -> BalanceResult {
        guard let key = creds.resolve(credentialKey) else {
            throw HTTPError.missingCredential
        }
        let (data, _) = try await http.get(
            url: endpoint,
            headers: ["Authorization": "Bearer \(key)"],
            timeoutSeconds: 10
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let modelRemains = (json?["model_remains"] as? [[String: Any]]) ?? []
        let general = modelRemains.first { ($0["model_name"] as? String) == "general" }
        let remainingPercent = (general?["current_interval_remaining_percent"] as? Double) ?? 0
        let usedPercent = max(0, 100 - remainingPercent)
        let resetMs = (general?["remains_time"] as? Double) ?? 0
        return BalanceResult(
            provider: id,
            balance: remainingPercent,
            currency: .percent,
            usedPercent: usedPercent,
            resetRemaining: resetMs / 1000.0
        )
    }
}

// MARK: - Registry

public enum BalanceRegistry {
    public static func all() -> [BalanceProvider] {
        [DeepSeekProvider(), tokenPlan(), codingPlanCN()]
    }

    public static func provider(for id: ProviderID) -> BalanceProvider? {
        switch id {
        case .deepseek: return DeepSeekProvider()
        case .minimax: return tokenPlan()
        case .minimaxCodeCN: return codingPlanCN()
        case .unknown: return nil
        }
    }

    public static func tokenPlan() -> MiniMaxRemainsProvider {
        MiniMaxRemainsProvider(
            id: .minimax,
            endpoint: URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!,
            credentialKey: "MINIMAX_API_KEY"
        )
    }

    public static func codingPlanCN() -> MiniMaxRemainsProvider {
        MiniMaxRemainsProvider(
            id: .minimaxCodeCN,
            endpoint: URL(string: "https://api.minimaxi.com/v1/coding_plan/remains")!,
            credentialKey: "MINIMAX_CODE_CN_API_KEY"
        )
    }

    /// 从 `provider/model-id[:thinking]` 中解出 provider id。
    public static func providerID(fromDefaultModel model: String) -> ProviderID {
        guard let slash = model.firstIndex(of: "/") else { return .unknown }
        return ProviderID(rawLowercased: String(model[..<slash]).lowercased())
    }
}
