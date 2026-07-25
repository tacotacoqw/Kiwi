import XCTest
@testable import KiwiPet

final class HydrationTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000)

    func testReminderRepeatsUntilDrinkIsConfirmed() {
        let tracker = HydrationTracker(
            reminderInterval: 45 * 60,
            isEnabled: true
        )
        tracker.repeatInterval = 120
        tracker.updatePresence(true, now: start)

        XCTAssertEqual(
            tracker.tick(now: start.addingTimeInterval(45 * 60)),
            .reminder
        )
        XCTAssertTrue(tracker.isAwaitingDrink)
        XCTAssertNil(
            tracker.tick(now: start.addingTimeInterval(45 * 60 + 119))
        )
        XCTAssertEqual(
            tracker.tick(now: start.addingTimeInterval(45 * 60 + 120)),
            .reminder
        )
    }

    func testConfirmedDrinkStartsANewInterval() {
        let tracker = HydrationTracker(
            reminderInterval: 60,
            isEnabled: true
        )
        tracker.updatePresence(true, now: start)
        _ = tracker.tick(now: start.addingTimeInterval(60))

        XCTAssertTrue(
            tracker.confirmDrink(now: start.addingTimeInterval(65))
        )
        XCTAssertFalse(tracker.isAwaitingDrink)
        XCTAssertNil(tracker.tick(now: start.addingTimeInterval(124)))
        XCTAssertEqual(
            tracker.tick(now: start.addingTimeInterval(125)),
            .reminder
        )
    }

    func testDisabledReminderDoesNotFire() {
        let tracker = HydrationTracker(
            reminderInterval: 10,
            isEnabled: false
        )
        tracker.updatePresence(true, now: start)
        XCTAssertNil(tracker.tick(now: start.addingTimeInterval(100)))
    }
}

final class DrinkingGestureDetectorTests: XCTestCase {
    func testNoVisibleHandArmsARealisticDrinkAndRelease() {
        var detector = DrinkingGestureDetector()

        XCTAssertFalse(detector.ingest(.noHand, at: 0))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 0.5))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 1))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 1.5))
        XCTAssertFalse(detector.ingest(.noHand, at: 2))
        XCTAssertTrue(detector.ingest(.noHand, at: 2.5))
    }

    func testBriefHandOcclusionDuringSipDoesNotLoseProgress() {
        var detector = DrinkingGestureDetector()

        XCTAssertFalse(detector.ingest(.noHand, at: 0))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 0.5))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 1))
        XCTAssertFalse(detector.ingest(.noHand, at: 1.5))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 2))
        XCTAssertFalse(detector.ingest(.noHand, at: 2.5))
        XCTAssertTrue(detector.ingest(.noHand, at: 3))
    }

    func testRequiresReadyHoldAndReleaseSequence() {
        var detector = DrinkingGestureDetector()

        XCTAssertFalse(detector.ingest(.away, at: 0))
        XCTAssertFalse(detector.ingest(.away, at: 0.5))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 1))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 1.5))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 2))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 2.5))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 3))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 3.5))
        XCTAssertFalse(detector.ingest(.away, at: 4))
        XCTAssertTrue(detector.ingest(.away, at: 4.5))
    }

    func testHandAlreadyNearFaceDoesNotCountAsDrinking() {
        var detector = DrinkingGestureDetector()

        for index in 0..<8 {
            XCTAssertFalse(
                detector.ingest(
                    .nearMouth,
                    at: TimeInterval(index) * 0.5
                )
            )
        }
        XCTAssertFalse(detector.ingest(.away, at: 4))
        XCTAssertFalse(detector.ingest(.away, at: 4.5))
    }

    func testBriefFaceTouchDoesNotCountAsDrinking() {
        var detector = DrinkingGestureDetector()

        XCTAssertFalse(detector.ingest(.away, at: 0))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 0.5))
        XCTAssertFalse(detector.ingest(.nearMouth, at: 1))
        XCTAssertFalse(detector.ingest(.away, at: 1.5))
        XCTAssertFalse(detector.ingest(.away, at: 2))
    }

    func testMouthRegionUsesPalmCenterAndTightEllipse() {
        let mouth = CGPoint(x: 0.5, y: 0.6)
        let faceSize = CGSize(width: 0.2, height: 0.24)

        XCTAssertTrue(
            DrinkingGestureGeometry.isNearMouth(
                palm: CGPoint(x: 0.56, y: 0.62),
                mouth: mouth,
                faceSize: faceSize
            )
        )
        XCTAssertFalse(
            DrinkingGestureGeometry.isNearMouth(
                palm: CGPoint(x: 0.78, y: 0.62),
                mouth: mouth,
                faceSize: faceSize
            )
        )
        XCTAssertFalse(
            DrinkingGestureGeometry.isNearMouth(
                palm: CGPoint(x: 0.56, y: 0.84),
                mouth: mouth,
                faceSize: faceSize
            )
        )
    }
}
