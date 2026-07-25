import AppKit
import Foundation

enum FeishuReminderInput {
    static let leadMinutesRange = 1...1440
    static let repeatMinutesRange = 1...720

    static func parseMinutes(
        _ text: String,
        allowedRange: ClosedRange<Int>
    ) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(trimmed),
              allowedRange.contains(minutes) else {
            return nil
        }
        return minutes
    }
}

struct FeishuReminderPolicy {
    let leadMinutes: Int
    let repeatMinutes: Int

    func shouldAlert(
        eventStart: Date,
        lastAlert: Date?,
        now: Date
    ) -> Bool {
        let secondsUntilStart = eventStart.timeIntervalSince(now)
        let leadInterval = TimeInterval(max(1, leadMinutes) * 60)
        guard secondsUntilStart > 0,
              secondsUntilStart <= leadInterval else {
            return false
        }

        guard let lastAlert else { return true }
        let repeatInterval = TimeInterval(max(1, repeatMinutes) * 60)
        return now.timeIntervalSince(lastAlert) >= repeatInterval
    }
}

struct FeishuConfiguration {
    var appID: String
    var appSecret: String
    var calendarID: String
    var targetOpenID: String
    var leadMinutes: Int
    var repeatMinutes: Int

    var hasCredentials: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

final class FeishuConfigurationStore {
    private enum DefaultsKey {
        static let appID = "feishuAppID"
        static let calendarID = "feishuCalendarID"
        static let targetOpenID = "feishuTargetOpenID"
        static let leadMinutes = "feishuLeadMinutes"
        static let repeatMinutes = "feishuRepeatMinutes"
    }

    private let defaults = UserDefaults.standard
    func load() -> FeishuConfiguration {
        let savedLead = defaults.integer(forKey: DefaultsKey.leadMinutes)
        let savedRepeat = defaults.integer(forKey: DefaultsKey.repeatMinutes)
        // Automatic monitoring must never touch the login keychain. Local
        // development builds can otherwise trigger a system-password dialog
        // after a rebuild. The user-only 0600 file is the authoritative copy.
        let appSecret = readFallbackSecret() ?? ""
        return FeishuConfiguration(
            appID: defaults.string(forKey: DefaultsKey.appID) ?? "",
            appSecret: appSecret,
            calendarID: defaults.string(forKey: DefaultsKey.calendarID) ?? "",
            targetOpenID: defaults.string(forKey: DefaultsKey.targetOpenID) ?? "",
            leadMinutes: savedLead > 0 ? savedLead : 5,
            repeatMinutes: savedRepeat > 0 ? savedRepeat : 3
        )
    }

    func save(_ configuration: FeishuConfiguration) throws {
        defaults.set(configuration.appID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKey.appID)
        defaults.set(configuration.calendarID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKey.calendarID)
        defaults.set(configuration.targetOpenID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKey.targetOpenID)
        defaults.set(
            max(
                FeishuReminderInput.leadMinutesRange.lowerBound,
                min(
                    configuration.leadMinutes,
                    FeishuReminderInput.leadMinutesRange.upperBound
                )
            ),
            forKey: DefaultsKey.leadMinutes
        )
        defaults.set(
            max(
                FeishuReminderInput.repeatMinutesRange.lowerBound,
                min(
                    configuration.repeatMinutes,
                    FeishuReminderInput.repeatMinutesRange.upperBound
                )
            ),
            forKey: DefaultsKey.repeatMinutes
        )
        let secret = configuration.appSecret.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        try writeFallbackSecret(secret)
    }

    private var fallbackSecretURL: URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Kiwi", isDirectory: true)
            .appendingPathComponent("feishu-app-secret", isDirectory: false)
    }

    private func readFallbackSecret() -> String? {
        guard let url = fallbackSecretURL,
              let data = try? Data(contentsOf: url),
              let secret = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            return nil
        }
        return secret
    }

    private func writeFallbackSecret(_ secret: String) throws {
        guard let url = fallbackSecretURL else {
            throw FeishuCalendarError.invalidConfiguration
        }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        guard !secret.isEmpty else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }

        try Data(secret.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

}

struct FeishuCalendarEvent {
    let eventID: String
    let title: String
    let startDate: Date
    let isAllDay: Bool
    let status: String
}

struct FeishuSyncResult {
    let calendarID: String
    let events: [FeishuCalendarEvent]
}

enum FeishuCalendarError: LocalizedError {
    case invalidConfiguration
    case invalidURL
    case invalidResponse
    case api(code: Int, message: String)
    case http(status: Int)
    case noApplicationCalendar
    case noUserCalendar
    case missingTargetUser

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "请先填写飞书 App ID 和 App Secret。"
        case .invalidURL:
            return "飞书接口地址无效。"
        case .invalidResponse:
            return "飞书返回了无法识别的数据。"
        case .api(let code, let message):
            return "飞书接口错误 \(code)：\(message)"
        case .http(let status):
            return "飞书网络请求失败（HTTP \(status)）。"
        case .noApplicationCalendar:
            return "没有找到 Kiwi 的应用主日历，请检查日历权限。"
        case .noUserCalendar:
            return "没有找到提醒对象的个人主日历，请检查 Open ID 和日历读取权限。"
        case .missingTargetUser:
            return "请填写要读取日历和接收提醒的用户 Open ID。"
        }
    }
}

final class FeishuCalendarService {
    private let apiRoot = URL(string: "https://open.feishu.cn/open-apis")!
    private let oauthService: FeishuOAuthService
    private var cachedToken: String?
    private var cachedTokenAppID: String?
    private var tokenExpiresAt = Date.distantPast

    init(oauthService: FeishuOAuthService = FeishuOAuthService()) {
        self.oauthService = oauthService
    }

    func upcomingEvents(
        configuration: FeishuConfiguration,
        from startDate: Date,
        to endDate: Date
    ) async throws -> FeishuSyncResult {
        let token = try await oauthService.userAccessToken(
            configuration: configuration
        )
        let calendarID = try await resolveReadCalendarID(
            configuration.calendarID,
            targetOpenID: configuration.targetOpenID,
            token: token
        )
        let events = try await listEvents(
            calendarID: calendarID,
            startDate: startDate,
            endDate: endDate,
            token: token
        )
        return FeishuSyncResult(calendarID: calendarID, events: events)
    }

    func createTestReminder(
        configuration: FeishuConfiguration
    ) async throws -> FeishuCalendarEvent {
        guard !configuration.targetOpenID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FeishuCalendarError.missingTargetUser
        }

        let token = try await tenantAccessToken(configuration: configuration)
        let calendarID = try await resolveApplicationCalendarID(token: token)
        let startDate = Date().addingTimeInterval(2 * 60)
        let endDate = startDate.addingTimeInterval(30 * 60)
        let event = try await createEvent(
            calendarID: calendarID,
            title: "Kiwi 飞书提醒测试",
            startDate: startDate,
            endDate: endDate,
            token: token
        )
        try await addAttendee(
            configuration.targetOpenID,
            calendarID: calendarID,
            eventID: event.eventID,
            token: token
        )
        return event
    }

    func sendCodexCompletionNotification(
        configuration: FeishuConfiguration,
        duration: TimeInterval,
        finishedAt: Date = Date()
    ) async throws {
        let openID = configuration.targetOpenID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !openID.isEmpty else {
            throw FeishuCalendarError.missingTargetUser
        }

        let token = try await tenantAccessToken(configuration: configuration)
        let baseURL = apiRoot
            .appendingPathComponent("im")
            .appendingPathComponent("v1")
            .appendingPathComponent("messages")
        var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "receive_id_type", value: "open_id")
        ]
        guard let url = components?.url else {
            throw FeishuCalendarError.invalidURL
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.timeZone = .current
        timeFormatter.dateFormat = "HH:mm"
        let content = try JSONSerialization.data(
            withJSONObject: [
                "text":
                    "🥝 AI Coding 已完成\n"
                    + "处理耗时：\(Self.formatDuration(duration))\n"
                    + "完成时间：\(timeFormatter.string(from: finishedAt))"
            ]
        )
        guard let contentString = String(data: content, encoding: .utf8) else {
            throw FeishuCalendarError.invalidResponse
        }

        _ = try await requestJSON(
            url: url,
            method: "POST",
            token: token,
            body: [
                "receive_id": openID,
                "msg_type": "text",
                "content": contentString
            ]
        )
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分钟"
        }
        if minutes > 0 {
            return "\(minutes) 分 \(seconds) 秒"
        }
        return "\(seconds) 秒"
    }

    private func tenantAccessToken(
        configuration: FeishuConfiguration
    ) async throws -> String {
        guard configuration.hasCredentials else {
            throw FeishuCalendarError.invalidConfiguration
        }
        let appID = configuration.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedToken,
           cachedTokenAppID == appID,
           Date() < tokenExpiresAt {
            return cachedToken
        }

        let url = apiRoot
            .appendingPathComponent("auth")
            .appendingPathComponent("v3")
            .appendingPathComponent("tenant_access_token")
            .appendingPathComponent("internal")
        let json = try await requestJSON(
            url: url,
            method: "POST",
            body: [
                "app_id": configuration.appID,
                "app_secret": configuration.appSecret
            ]
        )
        guard let token = json["tenant_access_token"] as? String, !token.isEmpty else {
            throw FeishuCalendarError.invalidResponse
        }
        let expiresIn = number(from: json["expire"]) ?? 7200
        cachedToken = token
        cachedTokenAppID = appID
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(max(60, expiresIn - 90)))
        return token
    }

    private func resolveReadCalendarID(
        _ configuredCalendarID: String,
        targetOpenID: String,
        token: String
    ) async throws -> String {
        let configured = configuredCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }

        let openID = targetOpenID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !openID.isEmpty else {
            throw FeishuCalendarError.missingTargetUser
        }

        let baseURL = apiRoot
            .appendingPathComponent("calendar")
            .appendingPathComponent("v4")
            .appendingPathComponent("calendars")
            .appendingPathComponent("primarys")
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user_id_type", value: "open_id")]
        guard let url = components?.url else {
            throw FeishuCalendarError.invalidURL
        }
        let json = try await requestJSON(
            url: url,
            method: "POST",
            token: token,
            body: ["user_ids": [openID]]
        )
        guard let data = json["data"] as? [String: Any],
              let calendars = data["calendars"] as? [[String: Any]] else {
            throw FeishuCalendarError.invalidResponse
        }
        let calendar = calendars.first?["calendar"] as? [String: Any]
        let calendarID = (calendar?["calendar_id"] as? String)
            ?? (calendars.first?["calendar_id"] as? String)
        guard let calendarID, !calendarID.isEmpty else {
            throw FeishuCalendarError.noUserCalendar
        }
        return calendarID
    }

    private func resolveApplicationCalendarID(token: String) async throws -> String {
        var components = URLComponents(
            url: apiRoot
                .appendingPathComponent("calendar")
                .appendingPathComponent("v4")
                .appendingPathComponent("calendars"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "page_size", value: "50")]
        guard let url = components?.url else {
            throw FeishuCalendarError.invalidURL
        }
        let json = try await requestJSON(url: url, token: token)
        guard let data = json["data"] as? [String: Any] else {
            throw FeishuCalendarError.invalidResponse
        }
        let calendars = (data["calendar_list"] as? [[String: Any]])
            ?? (data["items"] as? [[String: Any]])
            ?? []
        let primary = calendars.first { ($0["type"] as? String) == "primary" }
        guard let calendarID = (primary ?? calendars.first)?["calendar_id"] as? String,
              !calendarID.isEmpty else {
            throw FeishuCalendarError.noApplicationCalendar
        }
        return calendarID
    }

    private func listEvents(
        calendarID: String,
        startDate: Date,
        endDate: Date,
        token: String
    ) async throws -> [FeishuCalendarEvent] {
        var allEvents: [FeishuCalendarEvent] = []
        var pageToken: String?

        repeat {
            let baseURL = apiRoot
                .appendingPathComponent("calendar")
                .appendingPathComponent("v4")
                .appendingPathComponent("calendars")
                .appendingPathComponent(calendarID)
                .appendingPathComponent("events")
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            var queryItems = [
                URLQueryItem(name: "start_time", value: String(Int(startDate.timeIntervalSince1970))),
                URLQueryItem(name: "end_time", value: String(Int(endDate.timeIntervalSince1970))),
                URLQueryItem(name: "page_size", value: "50")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "page_token", value: pageToken))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else {
                throw FeishuCalendarError.invalidURL
            }

            let json = try await requestJSON(url: url, token: token)
            guard let data = json["data"] as? [String: Any] else {
                throw FeishuCalendarError.invalidResponse
            }
            let items = data["items"] as? [[String: Any]] ?? []
            allEvents.append(contentsOf: items.compactMap(parseEvent))
            let hasMore = data["has_more"] as? Bool ?? false
            pageToken = hasMore ? data["page_token"] as? String : nil
        } while pageToken != nil

        return allEvents
    }

    private func createEvent(
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        token: String
    ) async throws -> FeishuCalendarEvent {
        let url = apiRoot
            .appendingPathComponent("calendar")
            .appendingPathComponent("v4")
            .appendingPathComponent("calendars")
            .appendingPathComponent(calendarID)
            .appendingPathComponent("events")
        let timeZone = TimeZone.current.identifier
        let json = try await requestJSON(
            url: url,
            method: "POST",
            token: token,
            body: [
                "summary": title,
                "description": "由 Kiwi 桌宠创建的测试提醒。",
                "need_notification": true,
                "start_time": [
                    "timestamp": String(Int(startDate.timeIntervalSince1970)),
                    "timezone": timeZone
                ],
                "end_time": [
                    "timestamp": String(Int(endDate.timeIntervalSince1970)),
                    "timezone": timeZone
                ],
                "visibility": "default",
                "attendee_ability": "can_see_others",
                "free_busy_status": "busy",
                "reminders": [["minutes": 1]]
            ]
        )
        guard let data = json["data"] as? [String: Any],
              let eventJSON = data["event"] as? [String: Any],
              let event = parseEvent(eventJSON) else {
            throw FeishuCalendarError.invalidResponse
        }
        return event
    }

    private func addAttendee(
        _ openID: String,
        calendarID: String,
        eventID: String,
        token: String
    ) async throws {
        let baseURL = apiRoot
            .appendingPathComponent("calendar")
            .appendingPathComponent("v4")
            .appendingPathComponent("calendars")
            .appendingPathComponent(calendarID)
            .appendingPathComponent("events")
            .appendingPathComponent(eventID)
            .appendingPathComponent("attendees")
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user_id_type", value: "open_id")]
        guard let url = components?.url else {
            throw FeishuCalendarError.invalidURL
        }
        _ = try await requestJSON(
            url: url,
            method: "POST",
            token: token,
            body: [
                "attendees": [
                    [
                        "type": "user",
                        "user_id": openID.trimmingCharacters(in: .whitespacesAndNewlines)
                    ]
                ],
                "need_notification": true
            ]
        )
    }

    private func parseEvent(_ json: [String: Any]) -> FeishuCalendarEvent? {
        guard let eventID = json["event_id"] as? String,
              let start = json["start_time"] as? [String: Any],
              let startDate = parseTimeInfo(start) else {
            return nil
        }
        let rawTitle = (json["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FeishuCalendarEvent(
            eventID: eventID,
            title: rawTitle?.isEmpty == false ? rawTitle! : "标题不可见",
            startDate: startDate,
            isAllDay: start["date"] != nil,
            status: json["status"] as? String ?? "confirmed"
        )
    }

    private func parseTimeInfo(_ json: [String: Any]) -> Date? {
        if let timestamp = string(from: json["timestamp"]),
           let seconds = TimeInterval(timestamp) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let dateString = json["date"] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: json["timezone"] as? String ?? "")
            ?? TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString)
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
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeishuCalendarError.invalidResponse
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let json {
                let code = number(from: json["code"]) ?? httpResponse.statusCode
                throw FeishuCalendarError.api(
                    code: code,
                    message: json["msg"] as? String ?? "HTTP \(httpResponse.statusCode)"
                )
            }
            throw FeishuCalendarError.http(status: httpResponse.statusCode)
        }
        guard let json else {
            throw FeishuCalendarError.invalidResponse
        }
        let code = number(from: json["code"]) ?? 0
        if code != 0 {
            throw FeishuCalendarError.api(
                code: code,
                message: json["msg"] as? String ?? "未知错误"
            )
        }
        return json
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

    private func string(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}

final class FeishuSettingsWindowController: NSWindowController {
    var onSave: ((FeishuConfiguration, Bool) -> Void)?
    var onAuthorize: ((FeishuConfiguration) -> Void)?

    private let appIDField = NSTextField()
    private let appSecretField = NSSecureTextField()
    private let calendarIDField = NSTextField()
    private let targetOpenIDField = NSTextField()
    private let leadMinutesField = NSTextField()
    private let repeatMinutesField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    init(configuration: FeishuConfiguration) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "飞书日历与提醒设置"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildInterface()
        update(configuration: configuration)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(configuration: FeishuConfiguration) {
        appIDField.stringValue = configuration.appID
        appSecretField.stringValue = configuration.appSecret
        calendarIDField.stringValue = configuration.calendarID
        targetOpenIDField.stringValue = configuration.targetOpenID
        leadMinutesField.stringValue = String(configuration.leadMinutes)
        repeatMinutesField.stringValue = String(configuration.repeatMinutes)
    }

    func setStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        appIDField.placeholderString = "cli_xxxxxxxxxx"
        appSecretField.placeholderString = "安全保存；Kiwi 更新后不再要求系统密码"
        calendarIDField.placeholderString = "可留空，自动使用提醒对象的个人主日历"
        targetOpenIDField.placeholderString = "ou_xxxxxxxxxx"
        configureMinuteField(
            leadMinutesField,
            placeholder: "例如 30"
        )
        configureMinuteField(
            repeatMinutesField,
            placeholder: "例如 15"
        )

        let title = NSTextField(labelWithString: "让 Kiwi 读取飞书日程，并邀请指定用户收到日历提醒")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "保存应用信息后，请点击“登录飞书授权”。Kiwi 只会在任务进入你设定的提前提醒窗口后开始提示，并按设定频率重复；任务开始后立即停止提醒。"
        )
        detail.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [makeLabel("App ID"), appIDField],
            [makeLabel("App Secret"), appSecretField],
            [makeLabel("Calendar ID"), calendarIDField],
            [makeLabel("提醒对象 Open ID"), targetOpenIDField],
            [makeLabel("提前提醒（分钟）"), leadMinutesField],
            [makeLabel("重复间隔（分钟）"), repeatMinutesField]
        ])
        grid.rowSpacing = 11
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let saveButton = NSButton(
            title: "保存",
            target: self,
            action: #selector(saveConfiguration)
        )
        saveButton.keyEquivalent = "\r"
        let testButton = NSButton(
            title: "保存并测试连接",
            target: self,
            action: #selector(testConfiguration)
        )
        let authorizeButton = NSButton(
            title: "登录飞书授权",
            target: self,
            action: #selector(authorizeUser)
        )
        authorizeButton.bezelStyle = .rounded
        authorizeButton.contentTintColor = .controlAccentColor
        let buttons = NSStackView(views: [authorizeButton, testButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let root = NSStackView(views: [title, detail, grid, statusLabel, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.setCustomSpacing(22, after: detail)
        root.setCustomSpacing(20, after: grid)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -26),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 25),
            grid.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func configureMinuteField(
        _ field: NSTextField,
        placeholder: String
    ) {
        field.placeholderString = placeholder
        field.alignment = .right
        field.formatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            formatter.minimum = 1
            formatter.maximum = 1440
            return formatter
        }()
    }

    private func currentConfiguration() -> FeishuConfiguration? {
        guard let lead = FeishuReminderInput.parseMinutes(
            leadMinutesField.stringValue,
            allowedRange: FeishuReminderInput.leadMinutesRange
        ) else {
            setStatus("提前提醒请输入 1–1440 的整数分钟。", isError: true)
            window?.makeFirstResponder(leadMinutesField)
            return nil
        }
        guard let repeatMinutes = FeishuReminderInput.parseMinutes(
            repeatMinutesField.stringValue,
            allowedRange: FeishuReminderInput.repeatMinutesRange
        ) else {
            setStatus("重复间隔请输入 1–720 的整数分钟。", isError: true)
            window?.makeFirstResponder(repeatMinutesField)
            return nil
        }
        return FeishuConfiguration(
            appID: appIDField.stringValue,
            appSecret: appSecretField.stringValue,
            calendarID: calendarIDField.stringValue,
            targetOpenID: targetOpenIDField.stringValue,
            leadMinutes: lead,
            repeatMinutes: repeatMinutes
        )
    }

    @objc private func saveConfiguration() {
        guard let configuration = currentConfiguration() else { return }
        onSave?(configuration, false)
    }

    @objc private func testConfiguration() {
        guard let configuration = currentConfiguration() else { return }
        onSave?(configuration, true)
    }

    @objc private func authorizeUser() {
        guard let configuration = currentConfiguration() else { return }
        onAuthorize?(configuration)
    }
}
