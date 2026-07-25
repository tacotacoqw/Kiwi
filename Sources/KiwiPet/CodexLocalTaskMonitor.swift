import Foundation

/// Reads Codex's own local task lifecycle events. This is more reliable than
/// inferring activity from UI text, while remaining entirely on-device.
final class CodexLocalTaskMonitor {
    private enum DefaultsKey {
        static let recentCompletionTurnIDs =
            "codexLocalMonitorRecentCompletionTurnIDs"
    }

    private static let launchCatchUpWindow: TimeInterval = 30 * 60
    /// A primary Codex session normally keeps appending lifecycle, message,
    /// reasoning, and tool events while work is in progress. If the session
    /// file has been completely idle for this long, an unmatched
    /// `task_started` belongs to an interrupted/abandoned turn rather than a
    /// task that is still running.
    static let activeTaskInactivityTimeout: TimeInterval = 15 * 60

    struct ActiveTask: Equatable {
        let threadID: String
        let turnID: String
        let startedAt: Date
    }

    struct Completion: Equatable {
        let threadID: String
        let turnID: String
        let startedAt: Date
        let finishedAt: Date

        var duration: TimeInterval {
            max(0, finishedAt.timeIntervalSince(startedAt))
        }
    }

    enum Status: Equatable {
        case stopped
        case unavailable(String)
        case watching
        case active(ActiveTask)
    }

    var onStatusChanged: ((Status) -> Void)?
    var onTaskCompleted: ((Completion) -> Void)?
    private(set) var status: Status = .stopped

    private struct SessionState {
        let threadID: String
        var offset: UInt64 = 0
        var remainder = Data()
        var activeTasks: [String: ActiveTask] = [:]
        var lastActivityAt = Date.distantPast
    }

    private enum LifecycleEvent {
        case started(turnID: String, at: Date)
        case completed(turnID: String, startedAt: Date?, at: Date)
    }

    private let queue = DispatchQueue(
        label: "com.leo.kiwipet.codex-local-events",
        qos: .utility
    )
    private let fileManager = FileManager.default
    private let userDefaults: UserDefaults
    private let sessionsRoot: URL
    private let scanInterval: TimeInterval
    private let activeTaskInactivityTimeout: TimeInterval
    private let lifecycleMarkers = [
        Data(#""type":"task_started""#.utf8),
        Data(#""type":"task_complete""#.utf8)
    ]
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()

    private var requestedRunning = false
    private var timer: DispatchSourceTimer?
    private var sessions: [String: SessionState] = [:]
    private var completedInitialScan = false
    private var emittedCompletionTurnIDs: Set<String>
    private var recentCompletionTurnIDs: [String]

    init(
        sessionsRoot: URL? = nil,
        scanInterval: TimeInterval = 5,
        activeTaskInactivityTimeout: TimeInterval =
            CodexLocalTaskMonitor.activeTaskInactivityTimeout,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        self.sessionsRoot = sessionsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
                .appendingPathComponent("sessions")
        self.scanInterval = scanInterval
        self.activeTaskInactivityTimeout = activeTaskInactivityTimeout
        let recentIDs = userDefaults.stringArray(
            forKey: DefaultsKey.recentCompletionTurnIDs
        ) ?? []
        self.recentCompletionTurnIDs = recentIDs
        self.emittedCompletionTurnIDs = Set(recentIDs)
    }

    func start() {
        guard !requestedRunning else { return }
        requestedRunning = true
        queue.async { [weak self] in
            guard let self else { return }
            self.scan()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + self.scanInterval,
                repeating: self.scanInterval,
                leeway: .milliseconds(350)
            )
            timer.setEventHandler { [weak self] in
                self?.scan()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        requestedRunning = false
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.sessions.removeAll()
            self.completedInitialScan = false
            self.publish(.stopped)
        }
    }

    private func scan() {
        guard requestedRunning else { return }
        let root = sessionsRoot
        guard fileManager.fileExists(atPath: root.path) else {
            publish(.unavailable("找不到 Codex 本地任务记录"))
            return
        }

        do {
            let candidates = try recentSessionFiles(in: root)
            var retainedPaths = Set<String>()

            for url in candidates {
                let path = url.path
                if sessions[path] == nil {
                    guard let threadID = primaryThreadID(in: url) else {
                        continue
                    }
                    if completedInitialScan {
                        // This file appeared after Kiwi started. Consume it
                        // from the beginning so a task that starts and ends
                        // between two five-second scans is still reported.
                        sessions[path] = SessionState(threadID: threadID)
                    } else {
                        // On launch, establish state without replaying old
                        // completion notifications from session history.
                        sessions[path] = try initialSessionState(
                            for: url,
                            threadID: threadID
                        )
                    }
                }
                retainedPaths.insert(path)
                try readNewEvents(from: url)
            }

            discardInactiveTasks(now: Date())
            sessions = sessions.filter {
                retainedPaths.contains($0.key) || !$0.value.activeTasks.isEmpty
            }
            let activeTask = sessions.values
                .flatMap { $0.activeTasks.values }
                .max { $0.startedAt < $1.startedAt }
            completedInitialScan = true
            publish(activeTask.map(Status.active) ?? .watching)
        } catch {
            publish(.unavailable(error.localizedDescription))
        }
    }

    private func recentSessionFiles(in root: URL) throws -> [URL] {
        let calendar = Calendar.current
        var urls: [URL] = []
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey
        ]

        for dayOffset in 0...1 {
            guard let date = calendar.date(
                byAdding: .day,
                value: -dayOffset,
                to: Date()
            ) else {
                continue
            }
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: date
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                continue
            }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            guard fileManager.fileExists(atPath: directory.path) else {
                continue
            }
            let dayFiles = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            urls.append(
                contentsOf: dayFiles.filter { $0.pathExtension == "jsonl" }
            )
        }

        return try urls
            .map { url -> (URL, Date) in
                let values = try url.resourceValues(forKeys: keys)
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(40)
            .map(\.0)
    }

    /// Main desktop tasks use a string source such as "vscode". Guardian and
    /// other internal subagents store a dictionary source and must be ignored.
    private func primaryThreadID(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        // The first session_meta record can be much larger than 16 KB because
        // it embeds Codex's instructions. Its identifying fields are near the
        // beginning, so inspect only the prefix instead of requiring the full
        // first JSON line.
        let data = handle.readData(ofLength: 4_096)
        guard let prefix = String(data: data, encoding: .utf8),
              prefix.contains(#""type":"session_meta""#),
              prefix.contains(#""source":""#) else {
            return nil
        }
        return quotedValue(after: #""session_id":""#, in: prefix)
            ?? quotedValue(after: #""id":""#, in: prefix)
    }

    private func quotedValue(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let remainder = text[markerRange.upperBound...]
        guard let closingQuote = remainder.firstIndex(of: "\"") else {
            return nil
        }
        return String(remainder[..<closingQuote])
    }

    /// At launch, only the most recent lifecycle event in each JSONL file is
    /// needed to know whether that task is active. Read backwards in chunks
    /// instead of parsing years of tool output from the beginning.
    private func initialSessionState(
        for url: URL,
        threadID: String
    ) throws -> SessionState {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt =
            attributes[.modificationDate] as? Date ?? .distantPast
        var state = SessionState(
            threadID: threadID,
            offset: size,
            lastActivityAt: modifiedAt
        )
        guard size > 0 else { return state }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunkSize: UInt64 = 256 * 1_024
        var position = size
        var carry = Data()
        var capturedTrailingRemainder = false

        while position > 0 {
            let length = min(chunkSize, position)
            let start = position - length
            handle.seek(toFileOffset: start)
            var combined = handle.readData(ofLength: Int(length))
            combined.append(carry)
            var scanEnd = combined.endIndex

            if !capturedTrailingRemainder {
                if combined.last == 0x0A {
                    scanEnd = combined.index(before: combined.endIndex)
                } else if let newline = combined.lastIndex(of: 0x0A) {
                    state.remainder = Data(combined[combined.index(after: newline)...])
                    scanEnd = newline
                } else {
                    carry = combined
                    position = start
                    continue
                }
                capturedTrailingRemainder = true
            }

            while scanEnd > combined.startIndex,
                  let newline = combined[..<scanEnd].lastIndex(of: 0x0A) {
                let lineStart = combined.index(after: newline)
                if let event = lifecycleEvent(in: combined[lineStart..<scanEnd]) {
                    applyInitial(event, to: &state)
                    return state
                }
                scanEnd = newline
            }

            if start == 0, scanEnd > combined.startIndex,
               let event = lifecycleEvent(
                    in: combined[combined.startIndex..<scanEnd]
               ) {
                applyInitial(event, to: &state)
                return state
            }

            carry = Data(combined[combined.startIndex..<scanEnd])
            position = start
        }
        return state
    }

    private func applyInitial(
        _ event: LifecycleEvent,
        to state: inout SessionState
    ) {
        switch event {
        case .started(let turnID, let date):
            state.activeTasks.removeAll(keepingCapacity: true)
            state.activeTasks[turnID] = ActiveTask(
                threadID: state.threadID,
                turnID: turnID,
                startedAt: date
            )
        case .completed(let turnID, let startedAt, let finishedAt):
            state.activeTasks.removeAll()
            let age = Date().timeIntervalSince(finishedAt)
            guard age >= -60,
                  age <= Self.launchCatchUpWindow,
                  let startedAt,
                  claimCompletion(turnID: turnID) else {
                return
            }
            // Kiwi may be relaunched by a build a few seconds after Codex
            // finishes. Catch up that recent event instead of silently losing
            // it, while the persisted turn ID prevents duplicate delivery.
            publishCompletion(
                Completion(
                    threadID: state.threadID,
                    turnID: turnID,
                    startedAt: startedAt,
                    finishedAt: finishedAt
                )
            )
        }
    }

    private func readNewEvents(from url: URL) throws {
        let path = url.path
        guard var state = sessions[path] else { return }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        state.lastActivityAt =
            attributes[.modificationDate] as? Date ?? state.lastActivityAt
        if size < state.offset {
            state.offset = 0
            state.remainder.removeAll()
            state.activeTasks.removeAll()
        }
        guard size > state.offset else {
            sessions[path] = state
            return
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        handle.seek(toFileOffset: state.offset)
        let newData = handle.readDataToEndOfFile()
        state.offset = handle.offsetInFile
        state.remainder.append(newData)

        while let newline = state.remainder.firstIndex(of: 0x0A) {
            let line = state.remainder[..<newline]
            consume(line, state: &state)
            state.remainder.removeSubrange(...newline)
        }
        sessions[path] = state
    }

    private func discardInactiveTasks(now: Date) {
        for path in sessions.keys {
            guard var state = sessions[path],
                  !state.activeTasks.isEmpty else {
                continue
            }
            state.activeTasks = state.activeTasks.filter { _, task in
                let latestEvidence = max(
                    task.startedAt,
                    state.lastActivityAt
                )
                return now.timeIntervalSince(latestEvidence)
                    <= activeTaskInactivityTimeout
            }
            sessions[path] = state
        }
    }

    private func consume(
        _ line: Data.SubSequence,
        state: inout SessionState
    ) {
        guard let event = lifecycleEvent(in: line) else { return }
        switch event {
        case .started(let turnID, let date):
            // A primary Codex thread can run only one turn at a time. A new
            // start therefore supersedes an older unmatched start from the
            // same session instead of allowing the abandoned turn to return
            // after the newer task completes.
            state.activeTasks.removeAll(keepingCapacity: true)
            state.activeTasks[turnID] = ActiveTask(
                threadID: state.threadID,
                turnID: turnID,
                startedAt: date
            )
        case .completed(let turnID, let payloadStartedAt, let finishedAt):
            let activeTask = state.activeTasks.removeValue(forKey: turnID)
            guard claimCompletion(turnID: turnID),
                  let startedAt = activeTask?.startedAt ?? payloadStartedAt else {
                return
            }
            publishCompletion(
                Completion(
                    threadID: state.threadID,
                    turnID: turnID,
                    startedAt: startedAt,
                    finishedAt: finishedAt
                )
            )
        }
    }

    private func claimCompletion(turnID: String) -> Bool {
        guard emittedCompletionTurnIDs.insert(turnID).inserted else {
            return false
        }
        recentCompletionTurnIDs.removeAll { $0 == turnID }
        recentCompletionTurnIDs.append(turnID)
        if recentCompletionTurnIDs.count > 200 {
            let overflow = recentCompletionTurnIDs.count - 200
            let removed = recentCompletionTurnIDs.prefix(overflow)
            recentCompletionTurnIDs.removeFirst(overflow)
            for oldTurnID in removed {
                emittedCompletionTurnIDs.remove(oldTurnID)
            }
        }
        userDefaults.set(
            recentCompletionTurnIDs,
            forKey: DefaultsKey.recentCompletionTurnIDs
        )
        return true
    }

    private func lifecycleEvent(
        in line: Data.SubSequence
    ) -> LifecycleEvent? {
        guard !line.isEmpty,
              lifecycleMarkers.contains(where: { line.range(of: $0) != nil }),
              let object = try? JSONSerialization.jsonObject(with: Data(line)),
              let row = object as? [String: Any],
              row["type"] as? String == "event_msg",
              let payload = row["payload"] as? [String: Any],
              let eventType = payload["type"] as? String,
              let turnID = payload["turn_id"] as? String else {
            return nil
        }

        switch eventType {
        case "task_started":
            guard let date = eventDate(
                payloadValue: payload["started_at"],
                rowTimestamp: row["timestamp"]
            ) else {
                return nil
            }
            return .started(turnID: turnID, at: date)
        case "task_complete":
            guard let finishedAt = eventDate(
                payloadValue: payload["completed_at"],
                rowTimestamp: row["timestamp"]
            ) else {
                return nil
            }
            return .completed(
                turnID: turnID,
                startedAt: eventDate(
                    payloadValue: payload["started_at"],
                    rowTimestamp: nil
                ),
                at: finishedAt
            )
        default:
            return nil
        }
    }

    private func eventDate(
        payloadValue: Any?,
        rowTimestamp: Any?
    ) -> Date? {
        if let number = payloadValue as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let seconds = payloadValue as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let timestamp = rowTimestamp as? String else { return nil }
        if let date = timestampFormatter.date(from: timestamp) {
            return date
        }
        return ISO8601DateFormatter().date(from: timestamp)
    }

    private func publishCompletion(_ completion: Completion) {
        DispatchQueue.main.async { [weak self] in
            self?.onTaskCompleted?(completion)
        }
    }

    private func publish(_ newStatus: Status) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status != newStatus else { return }
            self.status = newStatus
            self.onStatusChanged?(newStatus)
        }
    }
}
