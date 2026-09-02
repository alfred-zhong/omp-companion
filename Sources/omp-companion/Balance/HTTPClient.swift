import Foundation

public protocol HTTPClient: Sendable {
    func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse)
    /// POST JSON，返回原始 `(Data, HTTPURLResponse)`（含非 2xx status）。
    /// 仅在 transport 层（超时 / 非法响应）throw；HTTP status 由调用方决定。
    /// 登录/刷新需要检查 401 的 `reason` 字段，故不在此处把非 2xx 转成 `HTTPError`。
    func post(url: URL, jsonBody: Data, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse)
}

extension HTTPClient {
    /// 默认实现：不真正发请求，仅用于让不关心 POST 的测试 fake 免改。
    public func post(url: URL, jsonBody: Data, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
        throw HTTPError.invalidResponse
    }
}

public enum HTTPError: Error, Equatable, Sendable {
    case timeout
    case unauthorized(status: Int)
    case rateLimited
    case server(status: Int)
    case invalidResponse
    case missingCredential
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpMethod = "GET"
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else { throw HTTPError.invalidResponse }
            switch http.statusCode {
            case 200..<300: return (data, http)
            case 401, 403: throw HTTPError.unauthorized(status: http.statusCode)
            case 429: throw HTTPError.rateLimited
            default: throw HTTPError.server(status: http.statusCode)
            }
        } catch let e as URLError where e.code == .timedOut {
            throw HTTPError.timeout
        }
    }

    public func post(url: URL, jsonBody: Data, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = jsonBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else { throw HTTPError.invalidResponse }
            return (data, http)
        } catch let e as URLError where e.code == .timedOut {
            throw HTTPError.timeout
        }
    }
}
