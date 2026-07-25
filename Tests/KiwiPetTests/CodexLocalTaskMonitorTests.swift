import Foundation
import XCTest
@testable import KiwiPet

final class CodexLocalTaskMonitorTests: XCTestCase {
    private var monitors: [CodexLocalTaskMonitor] = []
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        monitors.forEach { $0.stop() }
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    func testLaunchIgnoresUnmatchedTaskFromInactiveSession() throws {
        let now = Date()
        let fixture = try makeSession(
            event: taskStartedEvent(
                turnID: "stale-turn",
                startedAt: now.addingTimeInterval(-60 * 60)
            ),
            modifiedAt: now.addingTimeInterval(-45 * 60)
        )
        let defaults = makeUserDefaults()
        let monitor = CodexLocalTaskMonitor(
            sessionsRoot: fixture.root,
            scanInterval: 0.05,
            activeTaskInactivityTimeout: 15 * 60,
            userDefaults: defaults
        )
        monitors.append(monitor)
        let watching = expectation(description: "stale task is discarded")
        monitor.onStatusChanged = { status in
            if status == .watching {
                watching.fulfill()
            }
        }

        monitor.start()

        wait(for: [watching], timeout: 2)
        XCTAssertEqual(monitor.status, .watching)
    }

    func testLaunchRestoresTaskFromRecentlyActiveSession() throws {
        let now = Date()
        let fixture = try makeSession(
            event: taskStartedEvent(
                turnID: "fresh-turn",
                startedAt: now.addingTimeInterval(-30)
            ),
            modifiedAt: now
        )
        let monitor = CodexLocalTaskMonitor(
            sessionsRoot: fixture.root,
            scanInterval: 0.05,
            activeTaskInactivityTimeout: 15 * 60,
            userDefaults: makeUserDefaults()
        )
        monitors.append(monitor)
        let active = expectation(description: "fresh task is restored")
        monitor.onStatusChanged = { status in
            guard case .active(let task) = status else { return }
            XCTAssertEqual(task.turnID, "fresh-turn")
            active.fulfill()
        }

        monitor.start()

        wait(for: [active], timeout: 2)
    }

    func testActiveTaskExpiresWhenSessionStopsChanging() throws {
        let now = Date()
        let fixture = try makeSession(
            event: taskStartedEvent(
                turnID: "abandoned-turn",
                startedAt: now
            ),
            modifiedAt: now
        )
        let monitor = CodexLocalTaskMonitor(
            sessionsRoot: fixture.root,
            scanInterval: 0.03,
            activeTaskInactivityTimeout: 0.2,
            userDefaults: makeUserDefaults()
        )
        monitors.append(monitor)
        let active = expectation(description: "task becomes active")
        let watching = expectation(description: "inactive task expires")
        var sawActive = false
        monitor.onStatusChanged = { status in
            switch status {
            case .active:
                guard !sawActive else { return }
                sawActive = true
                active.fulfill()
            case .watching where sawActive:
                watching.fulfill()
            default:
                break
            }
        }

        monitor.start()

        wait(for: [active, watching], timeout: 2)
        XCTAssertEqual(monitor.status, .watching)
    }

    func testNewTaskSupersedesOlderUnmatchedTaskInSameSession() throws {
        let fixture = try makeSession(event: nil, modifiedAt: Date())
        let monitor = CodexLocalTaskMonitor(
            sessionsRoot: fixture.root,
            scanInterval: 0.03,
            userDefaults: makeUserDefaults()
        )
        monitors.append(monitor)
        let initialWatching = expectation(description: "initial watching")
        monitor.onStatusChanged = { status in
            if status == .watching {
                initialWatching.fulfill()
            }
        }
        monitor.start()
        wait(for: [initialWatching], timeout: 2)

        let firstActive = expectation(description: "first task starts")
        monitor.onStatusChanged = { status in
            guard case .active(let task) = status,
                  task.turnID == "abandoned-turn" else {
                return
            }
            firstActive.fulfill()
        }
        try append(
            taskStartedEvent(
                turnID: "abandoned-turn",
                startedAt: Date()
            ),
            to: fixture.file
        )
        wait(for: [firstActive], timeout: 2)

        let secondActive = expectation(description: "second task supersedes")
        monitor.onStatusChanged = { status in
            guard case .active(let task) = status,
                  task.turnID == "new-turn" else {
                return
            }
            secondActive.fulfill()
        }
        let secondStart = Date()
        try append(
            taskStartedEvent(
                turnID: "new-turn",
                startedAt: secondStart
            ),
            to: fixture.file
        )
        wait(for: [secondActive], timeout: 2)

        let finalWatching = expectation(
            description: "older unmatched task does not return"
        )
        monitor.onStatusChanged = { status in
            if status == .watching {
                finalWatching.fulfill()
            }
        }
        try append(
            taskCompletedEvent(
                turnID: "new-turn",
                startedAt: secondStart,
                completedAt: Date()
            ),
            to: fixture.file
        )
        wait(for: [finalWatching], timeout: 2)
        XCTAssertEqual(monitor.status, .watching)
    }

    private func makeSession(
        event: String?,
        modifiedAt: Date
    ) throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Kiwi-CodexLocalTaskMonitorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryRoots.append(root)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: Date()
        )
        let day = root
            .appendingPathComponent(
                String(format: "%04d", try XCTUnwrap(components.year))
            )
            .appendingPathComponent(
                String(format: "%02d", try XCTUnwrap(components.month))
            )
            .appendingPathComponent(
                String(format: "%02d", try XCTUnwrap(components.day))
            )
        try FileManager.default.createDirectory(
            at: day,
            withIntermediateDirectories: true
        )
        let file = day.appendingPathComponent("rollout-test.jsonl")
        let metadata =
            #"{"type":"session_meta","payload":{"id":"test-thread","source":"vscode"},"session_id":"test-thread","source":"vscode"}"#
        let content = event.map { "\(metadata)\n\($0)\n" }
            ?? "\(metadata)\n"
        try content.write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: file.path
        )
        return (root, file)
    }

    private func taskStartedEvent(
        turnID: String,
        startedAt: Date
    ) -> String {
        let timestamp = ISO8601DateFormatter().string(from: startedAt)
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"\(turnID)","started_at":\(startedAt.timeIntervalSince1970)}}
        """
    }

    private func taskCompletedEvent(
        turnID: String,
        startedAt: Date,
        completedAt: Date
    ) -> String {
        let timestamp = ISO8601DateFormatter().string(from: completedAt)
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(turnID)","started_at":\(startedAt.timeIntervalSince1970),"completed_at":\(completedAt.timeIntervalSince1970)}}
        """
    }

    private func append(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(line)\n".utf8))
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName =
            "KiwiCodexLocalTaskMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
