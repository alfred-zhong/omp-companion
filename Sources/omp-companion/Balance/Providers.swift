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
        // 字段是 total_balance（字符串），非 balance
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

// MARK: - MiniMax Token Plan

public struct MiniMaxTokenPlanProvider: BalanceProvider {
    public let id: ProviderID = .minimax
    public init() {}

    public func hasCredential(creds: CredentialsResolver) -> Bool {
        creds.resolve("MINIMAX_API_KEY") != nil
    }

    public func fetch(creds: CredentialsResolver, http: HTTPClient) async throws -> BalanceResult {
        guard let key = creds.resolve("MINIMAX_API_KEY") else {
            throw HTTPError.missingCredential
        }
        let url = URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!
        let (data, _) = try await http.get(
            url: url,
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
            provider: .minimax,
            balance: remainingPercent,
            currency: .percent,
            usedPercent: usedPercent,
            resetRemaining: resetMs / 1000.0
        )
    }
}

// MARK: - MiniMax Coding Plan (CN)

public struct MiniMaxCodingPlanCNProvider: BalanceProvider {
    public let id: ProviderID = .minimaxCodeCN
    public init() {}

    public func hasCredential(creds: CredentialsResolver) -> Bool {
        creds.resolve("MINIMAX_CODE_CN_API_KEY") != nil
    }

    public func fetch(creds: CredentialsResolver, http: HTTPClient) async throws -> BalanceResult {
        guard let key = creds.resolve("MINIMAX_CODE_CN_API_KEY") else {
            throw HTTPError.missingCredential
        }
        let url = URL(string: "https://api.minimaxi.com/v1/coding_plan/remains")!
        let (data, _) = try await http.get(
            url: url,
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
            provider: .minimaxCodeCN,
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
        [DeepSeekProvider(), MiniMaxTokenPlanProvider(), MiniMaxCodingPlanCNProvider()]
    }

    public static func provider(for id: ProviderID) -> BalanceProvider? {
        switch id {
        case .deepseek: return DeepSeekProvider()
        case .minimax: return MiniMaxTokenPlanProvider()
        case .minimaxCodeCN: return MiniMaxCodingPlanCNProvider()
        case .unknown: return nil
        }
    }

    /// 从 `provider/model-id[:thinking]` 中解出 provider id。
    public static func providerID(fromDefaultModel model: String) -> ProviderID {
        guard let slash = model.firstIndex(of: "/") else { return .unknown }
        return ProviderID(rawLowercased: String(model[..<slash]).lowercased())
    }
}
