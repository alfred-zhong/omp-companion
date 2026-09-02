import Foundation

public protocol BalanceProvider: Sendable {
    var id: ProviderID { get }
    /// 校验该 Provider 是否有可用的鉴权凭据。
    func hasCredential(creds: any CredentialSource) -> Bool
    /// 拉取余额。
    func fetch(creds: any CredentialSource, http: HTTPClient) async throws -> BalanceResult
}

// MARK: - DeepSeek

public struct DeepSeekProvider: BalanceProvider {
    public let id: ProviderID = .deepseek
    public init() {}

    public func hasCredential(creds: any CredentialSource) -> Bool {
        creds.resolve("DEEPSEEK_API_KEY") != nil
    }

    public func fetch(creds: any CredentialSource, http: HTTPClient) async throws -> BalanceResult {
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

    public func hasCredential(creds: any CredentialSource) -> Bool {
        creds.resolve(credentialKey) != nil
    }

    public func fetch(creds: any CredentialSource, http: HTTPClient) async throws -> BalanceResult {
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
        // interval 窗口起止（毫秒时间戳）：窗口大小 = end - start，随套餐可变
        // （文本配额数小时滚动、媒体配额按日，见上游 omp `intervalWindowId`），
        // 标签由此推导而非硬编码；缺起止时回退无窗口路径（左标签留空）。
        let startMs = (general?["start_time"] as? Double) ?? 0
        let endMs = (general?["end_time"] as? Double) ?? 0
        var quotaWindows: [QuotaWindow]?
        if startMs > 0, endMs > startMs {
            let windowLabel = Self.intervalWindowLabel(durationMs: endMs - startMs)
            let status: QuotaWindowStatus = (general?["current_interval_status"] as? Double) == 2 ? .rateLimited : .ok
            quotaWindows = [QuotaWindow(
                id: windowLabel,
                label: windowLabel,
                usedPercent: Int(usedPercent.rounded()),
                status: status,
                resetsAt: Date(timeIntervalSince1970: endMs / 1000)
            )]
        }
        return BalanceResult(
            provider: id,
            balance: remainingPercent,
            currency: .percent,
            usedPercent: usedPercent,
            resetRemaining: resetMs / 1000.0,
            quotaWindows: quotaWindows
        )
    }

    /// interval 窗口时长 → 标签：整小时输出 `5h`，非整小时按分钟 `240m`（与上游 omp 同规则）。
    private static func intervalWindowLabel(durationMs: Double) -> String {
        let hourMs: Double = 3_600_000
        if durationMs.truncatingRemainder(dividingBy: hourMs) == 0 {
            return "\(Int(durationMs / hourMs))h"
        }
        let minutes = Int((durationMs / 60_000).rounded())
        return minutes > 0 ? "\(minutes)m" : "Interval"
    }
}

// MARK: - OpenCode Go

/// OpenCode Go（opencode.ai 订阅网关）余额 provider：
/// `GET https://opencode.ai/zen/go/v1/usage`，`Authorization: Bearer <OPENCODE_API_KEY>`。
///
/// 端点 first-party 但未文档化（见 omp `@oh-my-pi/pi-ai/src/usage/opencode-go.ts`）：
/// 响应 `{ "usage": { rolling|weekly|monthly: { percent, status, resetsAt } } }`
/// - `percent`：**已用**百分比（0-100 整数，服务端 floor+clamp；展示层不换算）
/// - `status`：`"ok"` | `"rate-limited"`
/// - `resetsAt`：ISO 时间戳；monthly 锚定订阅周年（非 30 天滚动）
///
/// 状态栏主窗口取 rolling（5h），全部三窗口经 `BalanceResult.quotaWindows` 带出供菜单展示。
/// 解码 all-or-nothing：任一窗口缺失 / malformed → `invalidResponse`（与 omp 语义一致）。
public struct OpenCodeGoProvider: BalanceProvider {
    public let id: ProviderID = .opencodeGo
    private let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    public init() {}

    public func hasCredential(creds: any CredentialSource) -> Bool {
        creds.resolve("OPENCODE_API_KEY") != nil
    }

    public func fetch(creds: any CredentialSource, http: HTTPClient) async throws -> BalanceResult {
        guard let key = creds.resolve("OPENCODE_API_KEY") else {
            throw HTTPError.missingCredential
        }
        let (data, _) = try await http.get(
            url: endpoint,
            headers: ["Authorization": "Bearer \(key)"],
            timeoutSeconds: 10
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let usage = json?["usage"] as? [String: Any] else {
            throw HTTPError.invalidResponse
        }
        let windows = try Self.decodeWindows(usage)
        guard let rolling = windows.first(where: { $0.id == "5h" }) else {
            throw HTTPError.invalidResponse
        }
        let used = rolling.usedPercent
        let reset = max(0, rolling.resetsAt.timeIntervalSince(Date()))
        return BalanceResult(
            provider: .opencodeGo,
            balance: Double(used),
            currency: .percent,
            usedPercent: Double(used),
            resetRemaining: reset,
            quotaWindows: windows
        )
    }

    /// 三窗口全量解码；任一窗口 malformed → throw，不返回半截报告。
    private static func decodeWindows(_ usage: [String: Any]) throws -> [QuotaWindow] {
        let descriptors: [(key: String, id: String, label: String)] = [
            ("rolling", "5h", "5h"),
            ("weekly", "7d", "7d"),
            ("monthly", "monthly", "月度"),
        ]
        var out: [QuotaWindow] = []
        out.reserveCapacity(descriptors.count)
        for d in descriptors {
            guard let raw = usage[d.key] as? [String: Any],
                  let percentNum = raw["percent"] as? NSNumber,
                  let statusRaw = raw["status"] as? String,
                  let resetsAtRaw = raw["resetsAt"] as? String,
                  let resetsAt = Self.parseISO(resetsAtRaw),
                  let status = QuotaWindowStatus(rawValue: statusRaw)
            else {
                throw HTTPError.invalidResponse
            }
            let percent = percentNum.doubleValue
            guard percent.isFinite, percent >= 0, percent <= 100 else {
                throw HTTPError.invalidResponse
            }
            out.append(QuotaWindow(
                id: d.id,
                label: d.label,
                usedPercent: Int(percent),
                status: status,
                resetsAt: resetsAt
            ))
        }
        return out
    }

    /// ISO 时间戳解析：默认格式先试（`…T12:00:00Z`），失败再试带小数秒（live 响应形状 `…T13:02:42.270Z`）。
    private static func parseISO(_ s: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

// MARK: - ccccapi

/// ccccapi（sub2api 系列网关）账户余额 provider。
/// 只读取用户资料响应中的 USD `balance`，不解析身份、API key 或订阅字段。
/// 凭据不再来自 `.env`（ADR-0007）：由注入的 `CcccapiSessionManager` 负责登录/刷新并提供 access token。
public struct CcccapiProvider: BalanceProvider {
    public let id: ProviderID = .ccccapi
    private let endpoint = URL(string: "https://ccccapi.cc/api/v1/user/profile")!
    private let session: CcccapiSessionManager?

    public init(session: CcccapiSessionManager? = nil) {
        self.session = session
    }

    public func hasCredential(creds: any CredentialSource) -> Bool {
        session?.hasCredentials() ?? false
    }

    public func fetch(creds: any CredentialSource, http: HTTPClient) async throws -> BalanceResult {
        guard let session else { throw HTTPError.missingCredential }
        var token = try await session.validAccessToken()
        do {
            return try await fetchProfile(token: token, http: http)
        } catch let e as HTTPError where e == .unauthorized(status: 401) {
            token = try await session.reauthorize()
            return try await fetchProfile(token: token, http: http)
        }
    }

    private func fetchProfile(token: String, http: HTTPClient) async throws -> BalanceResult {
        let (data, _) = try await http.get(
            url: endpoint,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutSeconds: 10
        )
        let response: APIResponse
        do {
            response = try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            throw HTTPError.invalidResponse
        }
        guard response.code == 0, response.data.balance.isFinite else {
            throw HTTPError.invalidResponse
        }
        return BalanceResult(
            provider: .ccccapi,
            balance: response.data.balance,
            currency: .usd
        )
    }

    private struct APIResponse: Decodable {
        let code: Int
        let message: String
        let data: Profile
    }

    private struct Profile: Decodable {
        let balance: Double
    }
}

// MARK: - Registry

public enum BalanceRegistry {
    public static func all() -> [BalanceProvider] {
        [DeepSeekProvider(), tokenPlan(), codingPlanCN(), opencodeGo(), ccccapi()]
    }

    public static func provider(for id: ProviderID, ccccapiSession: CcccapiSessionManager? = nil) -> BalanceProvider? {
        switch id {
        case .deepseek: return DeepSeekProvider()
        case .minimax: return tokenPlan()
        case .minimaxCodeCN: return codingPlanCN()
        case .opencodeGo: return opencodeGo()
        case .ccccapi: return ccccapi(session: ccccapiSession)
        case .unknown: return nil
        }
    }

    public static func opencodeGo() -> OpenCodeGoProvider {
        OpenCodeGoProvider()
    }
    public static func ccccapi(session: CcccapiSessionManager? = nil) -> CcccapiProvider {
        CcccapiProvider(session: session)
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
