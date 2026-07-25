import XCTest
@testable import KiwiPet

final class FeishuReminderPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testStartsAlertingInsideUserLeadWindow() {
        let policy = FeishuReminderPolicy(
            leadMinutes: 30,
            repeatMinutes: 15
        )

        XCTAssertTrue(
            policy.shouldAlert(
                eventStart: now.addingTimeInterval(30 * 60),
                lastAlert: nil,
                now: now
            )
        )
    }

    func testDoesNotAlertBeforeUserLeadWindow() {
        let policy = FeishuReminderPolicy(
            leadMinutes: 30,
            repeatMinutes: 15
        )

        XCTAssertFalse(
            policy.shouldAlert(
                eventStart: now.addingTimeInterval(31 * 60),
                lastAlert: nil,
                now: now
            )
        )
    }

    func testRepeatsOnlyAfterUserInterval() {
        let policy = FeishuReminderPolicy(
            leadMinutes: 30,
            repeatMinutes: 15
        )
        let eventStart = now.addingTimeInterval(20 * 60)

        XCTAssertFalse(
            policy.shouldAlert(
                eventStart: eventStart,
                lastAlert: now.addingTimeInterval(-14 * 60),
                now: now
            )
        )
        XCTAssertTrue(
            policy.shouldAlert(
                eventStart: eventStart,
                lastAlert: now.addingTimeInterval(-15 * 60),
                now: now
            )
        )
    }

    func testStopsAlertingWhenTaskStarts() {
        let policy = FeishuReminderPolicy(
            leadMinutes: 30,
            repeatMinutes: 15
        )

        XCTAssertFalse(
            policy.shouldAlert(
                eventStart: now,
                lastAlert: nil,
                now: now
            )
        )
        XCTAssertFalse(
            policy.shouldAlert(
                eventStart: now.addingTimeInterval(-60),
                lastAlert: nil,
                now: now
            )
        )
    }

    func testCustomMinuteValidation() {
        XCTAssertEqual(
            FeishuReminderInput.parseMinutes(
                " 30 ",
                allowedRange: FeishuReminderInput.leadMinutesRange
            ),
            30
        )
        XCTAssertEqual(
            FeishuReminderInput.parseMinutes(
                "15",
                allowedRange: FeishuReminderInput.repeatMinutesRange
            ),
            15
        )
        XCTAssertNil(
            FeishuReminderInput.parseMinutes(
                "0",
                allowedRange: FeishuReminderInput.leadMinutesRange
            )
        )
        XCTAssertNil(
            FeishuReminderInput.parseMinutes(
                "15.5",
                allowedRange: FeishuReminderInput.repeatMinutesRange
            )
        )
    }
}
