import Foundation

/// ccccapi 登录/刷新语义化错误。账户特定，映射到菜单降级文案。
public enum CcccapiAuthError: Error, Sendable, Equatable {
    /// 偏好面板未配置邮箱/密码。
    case notConfigured
    /// 登录被拒（`INVALID_CREDENTIALS`），密码错 / 账号被禁用。
    case credentialInvalid
    /// 账户开启 TOTP 2FA，纯密码登录返回 `requires_2fa`，本 app 不自动处理。
    case requires2FA
    /// 刷新被拒（refresh token 失效 / 过期 / 被复用）。
    case refreshRejected
    /// 会话绑定不匹配（服务端按 IP/UA 绑定，变化时撤销整个会话家族）。
    case sessionBindingMismatch
}

/// ccccapi 凭据来源。由 `SettingsStore`（偏好面板）实现，避免 Balance 层依赖 UI 类型。
public protocol CcccapiCredentialSource: Sendable {
    var ccccapiEmail: String { get }
    var ccccapiPassword: String { get }
}

/// ccccapi 网页会话管理器：偏好凭据 + 仅内存 token 对 + 单飞登录/刷新。
///
/// 不落盘任何 token（ADR-0007）。生命周期：
/// - 首次取 token：用邮箱/密码 `POST /auth/login`。
/// - access token 临近过期（`refreshBuffer` 内）：`POST /auth/refresh` 轮转。
/// - profile 收到 401：`reauthorize()` 清空会话并重建。
/// - 刷新链失败：落到密码重登。
/// - 凭据无效失败：进入 `credentialCooldown` 冷却。
///
/// 并发：`withSingleFlight()` 保证同一时刻只有一个 task 在建立/刷新会话，
/// 避免多个 tick / 重试同时消费同一个 refresh token（轮转后旧 token 立即失效）。
public final class CcccapiSessionManager: @unchecked Sendable {
    private static let loginURL = URL(string: "https://ccccapi.cc/api/v1/auth/login")!
    private static let refreshURL = URL(string: "https://ccccapi.cc/api/v1/auth/refresh")!
    /// access token 距过期不足该时长时提前刷新（24h TTL → 实际约每天一次）。
    private static let refreshBuffer: TimeInterval = 5 * 3600
    /// 凭据无效后的冷却时长；冷却期内不再打 `/auth/login`。
    private static let credentialCooldown: TimeInterval = 300

    private let credentials: CcccapiCredentialSource
    private let http: HTTPClient
    private let clock: () -> Date

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date?
    private var inFlight: Task<String, Error>?
    private var lastCredentialFailure: Date?

    public init(
        credentials: CcccapiCredentialSource,
        http: HTTPClient,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.http = http
        self.clock = clock
    }

    /// 偏好面板是否已配置邮箱与密码。
    public func hasCredentials() -> Bool {
        !credentials.ccccapiEmail.isEmpty && !credentials.ccccapiPassword.isEmpty
    }

    /// 取一个可用的 access token。无效 / 临近过期 → 单飞刷新或登录。
    public func validAccessToken() async throws -> String {
        if let at = accessToken, let exp = expiresAt,
           clock().addingTimeInterval(Self.refreshBuffer) < exp {
            return at
        }
        return try await withSingleFlight()
    }

    /// profile 收到 401 后重建会话（清空内存 session，走一次登录）。
    public func reauthorize() async throws -> String {
        accessToken = nil
        refreshToken = nil
        expiresAt = nil
        return try await withSingleFlight()
    }

    /// 偏好面板"测试连接"：忽略冷却，强制建立一次会话。
    public func testConnection() async throws {
        accessToken = nil
        refreshToken = nil
        expiresAt = nil
        lastCredentialFailure = nil
        _ = try await withSingleFlight()
    }

    // MARK: - single-flight

    private func withSingleFlight() async throws -> String {
        if let t = inFlight { return try await t.value }
        let task = Task<String, Error> { try await self.obtainSession() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func obtainSession() async throws -> String {
        if let rt = refreshToken {
            do {
                return try await refresh(rt)
            } catch {
                // 刷新链失败（refresh token 失效 / 绑定不匹配 / 网络 / 解析）→ 密码重登建立新会话。
                // 登录失败才会抛出：成功则替换会话，失败则保留原 session（不清 refresh token）。
            }
        }
        return try await login()
    }

    // MARK: - login / refresh

    private func login() async throws -> String {
        if let fail = lastCredentialFailure, clock().timeIntervalSince(fail) < Self.credentialCooldown {
            throw CcccapiAuthError.credentialInvalid
        }
        guard hasCredentials() else { throw CcccapiAuthError.notConfigured }

        let body = try JSONSerialization.data(withJSONObject: [
            "email": credentials.ccccapiEmail,
            "password": credentials.ccccapiPassword,
        ])
        let (data, resp) = try await http.post(url: Self.loginURL, jsonBody: body, headers: [:], timeoutSeconds: 10)
        switch resp.statusCode {
        case 200..<300:
            let sess = try decodeSession(data)
            apply(accessToken: sess.access, refreshToken: sess.refresh, expiresIn: sess.expiresIn)
            lastCredentialFailure = nil
            return sess.access
        case 401:
            lastCredentialFailure = clock()
            throw CcccapiAuthError.credentialInvalid
        default:
            throw HTTPError.server(status: resp.statusCode)
        }
    }

    private func refresh(_ rt: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": rt])
        let (data, resp) = try await http.post(url: Self.refreshURL, jsonBody: body, headers: [:], timeoutSeconds: 10)
        switch resp.statusCode {
        case 200..<300:
            let sess = try decodeSession(data)
            apply(accessToken: sess.access, refreshToken: sess.refresh, expiresIn: sess.expiresIn)
            return sess.access
        case 401:
            throw refreshAuthReason(data)
        default:
            throw HTTPError.server(status: resp.statusCode)
        }
    }

    // MARK: - decode

    private struct SessionEnvelope: Decodable {
        let code: Int
        let data: SessionData?
    }

    private struct SessionData: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
        let requires_2fa: Bool?
    }

    private struct ErrorEnvelope: Decodable {
        let reason: String?
    }

    private func decodeSession(_ data: Data) throws -> (access: String, refresh: String, expiresIn: Int) {
        let env: SessionEnvelope
        do {
            env = try JSONDecoder().decode(SessionEnvelope.self, from: data)
        } catch {
            throw HTTPError.invalidResponse
        }
        guard env.code == 0, let d = env.data else { throw HTTPError.invalidResponse }
        if d.requires_2fa == true { throw CcccapiAuthError.requires2FA }
        guard let at = d.access_token, !at.isEmpty,
              let rt = d.refresh_token, !rt.isEmpty,
              let exp = d.expires_in, exp > 0 else {
            throw HTTPError.invalidResponse
        }
        return (at, rt, exp)
    }

    private func refreshAuthReason(_ data: Data) -> CcccapiAuthError {
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let r = env.reason {
            switch r {
            case "SESSION_BINDING_MISMATCH": return .sessionBindingMismatch
            default: return .refreshRejected
            }
        }
        return .refreshRejected
    }

    private func apply(accessToken: String, refreshToken: String, expiresIn: Int) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = clock().addingTimeInterval(TimeInterval(expiresIn))
    }
}
