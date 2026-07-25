import Foundation
import Network

struct FeishuUserAuthorization: Codable {
    let appID: String
    let accessToken: String
    let refreshToken: String
    let accessTokenExpiresAt: Date
    let refreshTokenExpiresAt: Date?
    let openID: String
    let userName: String
}

enum FeishuOAuthError: LocalizedError {
    case invalidAuthorizationURL
    case callbackServerUnavailable
    case callbackTimedOut
    case callbackRejected(String)
    case invalidCallback
    case invalidTokenResponse
    case authorizationRequired
    case authorizationExpired
    case offlineAccessMissing
    case wrongUser(expected: String, actual: String)
    case api(code: Int, message: String)
    case http(status: Int)
    case tokenStorage

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL:
            return "无法生成飞书授权地址。"
        case .callbackServerUnavailable:
            return "无法启动本机授权回调，请确认 17653 端口没有被占用。"
        case .callbackTimedOut:
            return "飞书授权等待超时，请重新点击“登录飞书授权”。"
        case .callbackRejected(let message):
            return "飞书授权未完成：\(message)"
        case .invalidCallback:
            return "飞书返回了无效的授权结果，请重新授权。"
        case .invalidTokenResponse:
            return "飞书返回了无法识别的用户令牌。"
        case .authorizationRequired:
            return "请先点击“登录飞书授权”，Kiwi 才能读取真实日程标题。"
        case .authorizationExpired:
            return "飞书用户授权已过期，请重新登录授权。"
        case .offlineAccessMissing:
            return "飞书没有返回刷新令牌，请为应用开通“离线访问已授权数据”权限后重新授权。"
        case .wrongUser(let expected, let actual):
            return "登录账号与提醒对象不一致（期望 \(expected)，实际 \(actual)），请使用正确账号重新授权。"
        case .api(let code, let message):
            return "飞书授权错误 \(code)：\(message)"
        case .http(let status):
            return "飞书授权网络请求失败（HTTP \(status)）。"
        case .tokenStorage:
            return "无法把飞书用户授权保存到 Kiwi 的本地数据目录。"
        }
    }
}

final class FeishuOAuthTokenStore {
    // Kiwi development builds are replaced frequently. Reading OAuth data
    // from the login keychain after a rebuild can make macOS show a system
    // password dialog. Keep the token in a user-only 0600 file instead and
    // never query the keychain, so Kiwi itself cannot trigger that dialog.
    private var authorizationURL: URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Kiwi", isDirectory: true)
            .appendingPathComponent(
                "feishu-user-authorization.json",
                isDirectory: false
            )
    }

    func load(for appID: String) -> FeishuUserAuthorization? {
        guard let url = authorizationURL,
              let data = try? Data(contentsOf: url),
              let authorization = try? JSONDecoder().decode(
                FeishuUserAuthorization.self,
                from: data
              ),
              authorization.appID == appID else {
            return nil
        }
        return authorization
    }

    func save(_ authorization: FeishuUserAuthorization) throws {
        guard let url = authorizationURL else {
            throw FeishuOAuthError.tokenStorage
        }
        let data = try JSONEncoder().encode(authorization)
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw FeishuOAuthError.tokenStorage
        }
    }

    func clear() {
        guard let url = authorizationURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

final class FeishuOAuthService {
    static let redirectURI = "http://127.0.0.1:17653/feishu/oauth/callback"

    private let apiRoot = URL(string: "https://open.feishu.cn/open-apis")!
    private let authorizationRoot = URL(
        string: "https://accounts.feishu.cn/open-apis/authen/v1/authorize"
    )!
    private let tokenStore = FeishuOAuthTokenStore()

    func hasAuthorization(for appID: String) -> Bool {
        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let authorization = tokenStore.load(for: normalizedAppID) else {
            return false
        }
        if Date() < authorization.accessTokenExpiresAt {
            return true
        }
        if let refreshExpiresAt = authorization.refreshTokenExpiresAt {
            return Date() < refreshExpiresAt
        }
        return !authorization.refreshToken.isEmpty
    }

    func authorizationURL(
        configuration: FeishuConfiguration,
        state: String
    ) throws -> URL {
        guard configuration.hasCredentials else {
            throw FeishuCalendarError.invalidConfiguration
        }
        var components = URLComponents(
            url: authorizationRoot,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "client_id",
                value: configuration.appID.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(
                name: "scope",
                value: "calendar:calendar:readonly offline_access"
            ),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else {
            throw FeishuOAuthError.invalidAuthorizationURL
        }
        return url
    }

    func exchangeAuthorizationCode(
        _ code: String,
        configuration: FeishuConfiguration
    ) async throws -> FeishuUserAuthorization {
        let json = try await requestToken(
            body: [
                "grant_type": "authorization_code",
                "client_id": configuration.appID,
                "client_secret": configuration.appSecret,
                "code": code,
                "redirect_uri": Self.redirectURI
            ]
        )
        let authorization = try await makeAuthorization(
            from: json,
            appID: configuration.appID,
            fallbackRefreshToken: nil,
            fallbackRefreshExpiry: nil
        )
        try tokenStore.save(authorization)
        return authorization
    }

    func userAccessToken(
        configuration: FeishuConfiguration
    ) async throws -> String {
        let appID = configuration.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let authorization = tokenStore.load(for: appID) else {
            throw FeishuOAuthError.authorizationRequired
        }
        if Date().addingTimeInterval(120) < authorization.accessTokenExpiresAt {
            return authorization.accessToken
        }
        if let refreshExpiresAt = authorization.refreshTokenExpiresAt,
           Date().addingTimeInterval(120) >= refreshExpiresAt {
            throw FeishuOAuthError.authorizationExpired
        }
        guard !authorization.refreshToken.isEmpty else {
            throw FeishuOAuthError.offlineAccessMissing
        }

        let json = try await requestToken(
            body: [
                "grant_type": "refresh_token",
                "client_id": configuration.appID,
                "client_secret": configuration.appSecret,
                "refresh_token": authorization.refreshToken
            ]
        )
        let refreshed = try await makeAuthorization(
            from: json,
            appID: appID,
            fallbackRefreshToken: authorization.refreshToken,
            fallbackRefreshExpiry: authorization.refreshTokenExpiresAt
        )
        try tokenStore.save(refreshed)
        return refreshed.accessToken
    }

    func clearAuthorization() {
        tokenStore.clear()
    }

    private func makeAuthorization(
        from json: [String: Any],
        appID: String,
        fallbackRefreshToken: String?,
        fallbackRefreshExpiry: Date?
    ) async throws -> FeishuUserAuthorization {
        guard let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw FeishuOAuthError.invalidTokenResponse
        }
        let refreshToken = (json["refresh_token"] as? String)
            ?? fallbackRefreshToken
            ?? ""
        guard !refreshToken.isEmpty else {
            throw FeishuOAuthError.offlineAccessMissing
        }

        let now = Date()
        let expiresIn = number(from: json["expires_in"]) ?? 7200
        let refreshExpiresAt: Date?
        if let refreshExpiresIn = number(from: json["refresh_token_expires_in"]) {
            refreshExpiresAt = now.addingTimeInterval(TimeInterval(refreshExpiresIn))
        } else {
            refreshExpiresAt = fallbackRefreshExpiry
        }

        let userInfo = try await requestJSON(
            url: apiRoot
                .appendingPathComponent("authen")
                .appendingPathComponent("v1")
                .appendingPathComponent("user_info"),
            token: accessToken
        )
        guard let data = userInfo["data"] as? [String: Any],
              let openID = data["open_id"] as? String,
              !openID.isEmpty else {
            throw FeishuOAuthError.invalidTokenResponse
        }
        let userName = (data["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FeishuUserAuthorization(
            appID: appID.trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
            refreshTokenExpiresAt: refreshExpiresAt,
            openID: openID,
            userName: userName?.isEmpty == false ? userName! : "飞书用户"
        )
    }

    private func requestToken(body: [String: Any]) async throws -> [String: Any] {
        try await requestJSON(
            url: apiRoot
                .appendingPathComponent("authen")
                .appendingPathComponent("v2")
                .appendingPathComponent("oauth")
                .appendingPathComponent("token"),
            method: "POST",
            body: body
        )
    }

    private func requestJSON(
        url: URL,
        method: String = "GET",
        token: String? = nil,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FeishuOAuthError.invalidTokenResponse
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            if let json {
                throw FeishuOAuthError.api(
                    code: number(from: json["code"]) ?? response.statusCode,
                    message: errorMessage(from: json) ?? "HTTP \(response.statusCode)"
                )
            }
            throw FeishuOAuthError.http(status: response.statusCode)
        }
        guard let json else {
            throw FeishuOAuthError.invalidTokenResponse
        }
        let code = number(from: json["code"]) ?? 0
        guard code == 0 else {
            throw FeishuOAuthError.api(
                code: code,
                message: errorMessage(from: json) ?? "未知错误"
            )
        }
        return json
    }

    private func errorMessage(from json: [String: Any]) -> String? {
        (json["msg"] as? String)
            ?? (json["error_description"] as? String)
            ?? (json["error"] as? String)
    }

    private func number(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}

final class FeishuOAuthCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.leo.kiwipet.feishu-oauth")
    private let port = NWEndpoint.Port(rawValue: 17653)!
    private var listener: NWListener?
    private var expectedState = ""
    private var resultContinuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    func start(expectedState: String) async throws {
        self.expectedState = expectedState
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            throw FeishuOAuthError.callbackServerUnavailable
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener = listener

        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: ())
                    self?.scheduleTimeout()
                case .failed:
                    listener.stateUpdateHandler = nil
                    continuation.resume(
                        throwing: FeishuOAuthError.callbackServerUnavailable
                    )
                    self?.stop()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(
                        throwing: FeishuOAuthError.callbackServerUnavailable
                    )
                    return
                }
                if let pendingResult {
                    self.pendingResult = nil
                    continuation.resume(with: pendingResult)
                } else {
                    self.resultContinuation = continuation
                }
            }
        }
    }

    func stop() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1024
        ) { [weak self] data, _, _, _ in
            guard let self else { return }
            let result = self.parseRequest(data)
            self.sendResponse(for: result, through: connection)
            self.finish(result)
        }
    }

    private func parseRequest(_ data: Data?) -> Result<String, Error> {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            return .failure(FeishuOAuthError.invalidCallback)
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(
                string: "http://127.0.0.1\(parts[1])"
              ),
              components.path == "/feishu/oauth/callback" else {
            return .failure(FeishuOAuthError.invalidCallback)
        }
        let query: [String: String] = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                guard let value = $0.value else { return nil }
                return ($0.name as String, value as String)
            }
        )
        guard query["state"] == expectedState else {
            return .failure(FeishuOAuthError.invalidCallback)
        }
        if let error = query["error"] {
            return .failure(
                FeishuOAuthError.callbackRejected(
                    query["error_description"] ?? error
                )
            )
        }
        guard let code = query["code"], !code.isEmpty else {
            return .failure(FeishuOAuthError.invalidCallback)
        }
        return .success(code)
    }

    private func sendResponse(
        for result: Result<String, Error>,
        through connection: NWConnection
    ) {
        let title: String
        let detail: String
        switch result {
        case .success:
            title = "Kiwi 已获得飞书授权"
            detail = "可以关闭这个页面，Kiwi 会自动读取日程标题。"
        case .failure:
            title = "Kiwi 飞书授权失败"
            detail = "请回到 Kiwi 菜单重新尝试。"
        }
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;\
        background:#f5f2eb;color:#332a22;display:grid;place-items:center;\
        min-height:100vh;margin:0">
        <main style="background:white;padding:36px 42px;border-radius:24px;\
        box-shadow:0 18px 50px #3a2f241c;text-align:center;max-width:480px">
        <div style="font-size:54px">🥝</div>
        <h1 style="font-size:24px">\(title)</h1>
        <p style="line-height:1.7;color:#6c5b4d">\(detail)</p>
        </main></body></html>
        """
        let body = Data(html.utf8)
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutWorkItem?.cancel()
        if let resultContinuation {
            self.resultContinuation = nil
            resultContinuation.resume(with: result)
        } else {
            pendingResult = result
        }
        stop()
    }

    private func scheduleTimeout() {
        let item = DispatchWorkItem { [weak self] in
            self?.finish(.failure(FeishuOAuthError.callbackTimedOut))
        }
        timeoutWorkItem = item
        queue.asyncAfter(deadline: .now() + 5 * 60, execute: item)
    }
}
