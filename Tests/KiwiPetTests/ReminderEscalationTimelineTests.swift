import AppKit
import XCTest
@testable import KiwiPet

final class ReminderEscalationTimelineTests: XCTestCase {
    func testReminderWaitsThirtySecondsBeforeEscalating() {
        XCTAssertEqual(ReminderEscalationTimeline.initialDelay, 30)
    }

    func testAnimationStaysVisibleForThirtyPlusSeconds() {
        XCTAssertGreaterThan(
            ReminderEscalationTimeline.visibleDuration,
            30
        )
        XCTAssertLessThan(
            ReminderEscalationTimeline.visibleDuration,
            40
        )
    }

    func testTimelineUsesNineExpressionsThenThreeExitFrames() {
        XCTAssertEqual(
            ReminderEscalationTimeline.frameIndex(
                at: 0,
                reduceMotion: false
            ),
            0
        )
        XCTAssertEqual(
            ReminderEscalationTimeline.frameIndex(
                at: 3.6,
                reduceMotion: false
            ),
            1
        )
        XCTAssertEqual(
            ReminderEscalationTimeline.frameIndex(
                at: 32.39,
                reduceMotion: false
            ),
            8
        )
        XCTAssertEqual(
            ReminderEscalationTimeline.frameIndex(
                at: 32.4,
                reduceMotion: false
            ),
            9
        )
        XCTAssertEqual(
            ReminderEscalationTimeline.frameIndex(
                at: 32.89,
                reduceMotion: false
            ),
            9
        )
        XCTAssertEqual(
            ReminderEscalationTimeline.frameIndex(
                at: 33.00,
                reduceMotion: false
            ),
            10
        )
        XCTAssertEqual(
            ReminderEscalationTimeline.frameIndex(
                at: 33.50,
                reduceMotion: false
            ),
            11
        )
        XCTAssertNil(
            ReminderEscalationTimeline.frameIndex(
                at: ReminderEscalationTimeline.visibleDuration,
                reduceMotion: false
            )
        )
    }

    func testExitFramesAreAdvancedOneByOneAndStayVisible() {
        var indices = [
            ReminderEscalationTimeline.firstExitFrameIndex
        ]
        while let next = ReminderEscalationTimeline.nextExitFrame(
            after: indices.last!
        ) {
            indices.append(next)
        }

        XCTAssertEqual(indices, [9, 10, 11])
        XCTAssertGreaterThanOrEqual(
            ReminderEscalationTimeline.exitFrameDuration,
            0.5
        )
    }

    func testReducedMotionKeepsOneStaticFrame() {
        XCTAssertEqual(
            ReminderEscalationTimeline.frameIndex(
                at: 18,
                reduceMotion: true
            ),
            0
        )
    }

    func testAllSuppliedReminderFramesAreAvailableAtOneSize() {
        let frames = (1...12).compactMap {
            AssetLoader.frame(
                named: String(
                    format: "persistent-reminder-%02d.png",
                    $0
                )
            )
        }
        XCTAssertEqual(frames.count, 12)
        let expectedSize = frames.first?.size
        XCTAssertTrue(
            frames.allSatisfy { $0.size == expectedSize }
        )
    }

    func testEscalationBubbleUsesTheRequestedMessage() {
        XCTAssertEqual(
            ReminderEscalationBubbleLayout.message,
            "Kiwi 正在盯着你，快行动"
        )
    }

    func testEscalationBubbleStaysInsideTheScreenAboveKiwi() {
        for size in [
            NSSize(width: 1194, height: 834),
            NSSize(width: 1728, height: 1117)
        ] {
            let bounds = NSRect(origin: .zero, size: size)
            let frame = ReminderEscalationBubbleLayout.frame(
                in: bounds
            )
            XCTAssertTrue(bounds.contains(frame))
            XCTAssertGreaterThan(frame.minY, bounds.height * 0.40)
            XCTAssertGreaterThan(frame.minX, bounds.width * 0.45)
        }
    }
}
