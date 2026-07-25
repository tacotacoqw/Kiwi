import AppKit
import WebKit
import XCTest
@testable import KiwiPet

final class SittingTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testReminderFiresAfterContinuousPresenceAndReschedules() {
        let tracker = SittingTracker(reminderInterval: 10)
        tracker.updatePresence(true, now: start)

        XCTAssertNil(tracker.tick(now: start.addingTimeInterval(9.9)))
        XCTAssertEqual(
            tracker.tick(now: start.addingTimeInterval(10)),
            .reminder
        )
        XCTAssertNil(tracker.tick(now: start.addingTimeInterval(19.9)))
        XCTAssertEqual(
            tracker.tick(now: start.addingTimeInterval(20)),
            .reminder
        )
    }

    func testBriefDetectionLossKeepsTheSession() {
        let tracker = SittingTracker(reminderInterval: 60)
        tracker.absenceGracePeriod = 20
        tracker.updatePresence(true, now: start)
        tracker.updatePresence(false, now: start.addingTimeInterval(10))
        _ = tracker.tick(now: start.addingTimeInterval(25))
        tracker.updatePresence(true, now: start.addingTimeInterval(26))

        XCTAssertEqual(
            tracker.elapsed(now: start.addingTimeInterval(30)),
            30,
            accuracy: 0.001
        )
    }

    func testLongAbsenceResetsTheSession() {
        let tracker = SittingTracker(reminderInterval: 60)
        tracker.absenceGracePeriod = 20
        tracker.updatePresence(true, now: start)
        tracker.updatePresence(false, now: start.addingTimeInterval(10))
        _ = tracker.tick(now: start.addingTimeInterval(30))

        XCTAssertEqual(tracker.elapsed(now: start.addingTimeInterval(31)), 0)
        XCTAssertFalse(tracker.isPresent)
        XCTAssertNil(tracker.timeUntilNextReminder(now: start))
    }

    func testRemainingTimeCountsDown() {
        let tracker = SittingTracker(reminderInterval: 45)
        tracker.updatePresence(true, now: start)

        XCTAssertEqual(
            tracker.timeUntilNextReminder(
                now: start.addingTimeInterval(12)
            ),
            33
        )
    }
}

final class StandingGestureDetectorTests: XCTestCase {
    private func frame(
        faceY: CGFloat? = nil,
        faceHeight: CGFloat = 0.20,
        upperBodyY: CGFloat? = nil,
        upperBodyHeight: CGFloat = 0.50,
        shoulderY: CGFloat? = nil,
        hips: [CGPoint] = [],
        knees: [CGPoint] = [],
        ankles: [CGPoint] = [],
        legs: [StandingLegPose] = [],
        body3D: StandingBodyPose3DSample? = nil
    ) -> StandingFrameSample {
        StandingFrameSample(
            face: faceY.map {
                StandingRegionSample(
                    centerY: $0,
                    height: faceHeight
                )
            },
            upperBody: upperBodyY.map {
                StandingRegionSample(
                    centerY: $0,
                    height: upperBodyHeight
                )
            },
            body: shoulderY.map {
                StandingBodyPoseSample(
                    shoulderY: $0,
                    hips: hips,
                    knees: knees,
                    ankles: ankles,
                    legs: legs
                )
            },
            body3D: body3D
        )
    }

    func testRequiresTenContinuousSecondsOfStanding() {
        var detector = StandingGestureDetector()

        for index in 0..<20 {
            XCTAssertFalse(
                detector.ingest(
                    .standing,
                    at: TimeInterval(index) * 0.5
                )
            )
        }
        XCTAssertTrue(detector.ingest(.standing, at: 10))
        XCTAssertFalse(detector.ingest(.standing, at: 10.5))
    }

    func testThreeSecondsOfConfirmedSittingRestartConfirmation() {
        var detector = StandingGestureDetector()

        XCTAssertFalse(detector.ingest(.standing, at: 0))
        XCTAssertFalse(detector.ingest(.standing, at: 0.5))
        XCTAssertFalse(detector.ingest(.standing, at: 1))
        for index in 0...6 {
            XCTAssertFalse(
                detector.ingest(
                    .notStanding,
                    at: 1.5 + TimeInterval(index) * 0.5
                )
            )
        }
        for index in 0..<20 {
            XCTAssertFalse(
                detector.ingest(
                    .standing,
                    at: 5 + TimeInterval(index) * 0.5
                )
            )
        }
        XCTAssertTrue(detector.ingest(.standing, at: 15))
    }

    func testOneVisionMisclassificationDoesNotEraseProgress() {
        var detector = StandingGestureDetector()

        for index in 0..<9 {
            XCTAssertFalse(
                detector.ingest(
                    .standing,
                    at: TimeInterval(index) * 0.5
                )
            )
        }
        XCTAssertFalse(detector.ingest(.notStanding, at: 4.5))
        for index in 10..<20 {
            XCTAssertFalse(
                detector.ingest(
                    .standing,
                    at: TimeInterval(index) * 0.5
                )
            )
        }
        XCTAssertFalse(detector.ingest(.standing, at: 10))
        XCTAssertFalse(detector.ingest(.standing, at: 10.5))
        XCTAssertTrue(detector.ingest(.standing, at: 11))
    }

    func testBriefUnavailableFramesAreToleratedLikeDrinkDetection() {
        var detector = StandingGestureDetector()

        XCTAssertFalse(detector.ingest(.standing, at: 0))
        XCTAssertFalse(detector.ingest(.standing, at: 0.5))
        XCTAssertFalse(detector.ingest(.unavailable, at: 1))
        for index in 0..<17 {
            XCTAssertFalse(
                detector.ingest(
                    .standing,
                    at: 1.5 + TimeInterval(index) * 0.5
                )
            )
        }
        XCTAssertFalse(detector.ingest(.standing, at: 10))
        XCTAssertFalse(detector.ingest(.standing, at: 10.5))
        XCTAssertTrue(detector.ingest(.standing, at: 11))
    }

    func testEightSecondsUnavailableRestartsConfirmation() {
        var detector = StandingGestureDetector()

        XCTAssertFalse(detector.ingest(.standing, at: 0))
        XCTAssertFalse(detector.ingest(.standing, at: 0.5))
        for index in 0...16 {
            XCTAssertFalse(
                detector.ingest(
                    .unavailable,
                    at: 1 + TimeInterval(index) * 0.5
                )
            )
        }
        XCTAssertEqual(detector.confirmedDuration(at: 9), 0)
    }

    func testLargeGapBetweenFramesRestartsConfirmation() {
        var detector = StandingGestureDetector()

        XCTAssertFalse(detector.ingest(.standing, at: 0))
        XCTAssertFalse(detector.ingest(.standing, at: 0.5))
        XCTAssertFalse(detector.ingest(.standing, at: 2))
        XCTAssertFalse(detector.ingest(.standing, at: 11.9))
        XCTAssertFalse(detector.ingest(.standing, at: 12.4))
    }

    func testShoulderRiseWithoutLowerBodyIsNotEnough() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(shoulderY: 0.40)
        )

        XCTAssertEqual(
            classifier.classify(
                frame(shoulderY: 0.45)
            ),
            .unavailable
        )
    }

    func testStraightVisibleLegCountsAsStanding() {
        var classifier = StandingPoseClassifier()
        let straightLeg = StandingLegPose(
            hip: CGPoint(x: 0.5, y: 0.62),
            knee: CGPoint(x: 0.5, y: 0.36),
            ankle: CGPoint(x: 0.5, y: 0.10)
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    shoulderY: 0.78,
                    legs: [straightLeg]
                )
            ),
            .standing
        )
    }

    func testThreeDimensionalSkeletonConfirmsStandingWithoutHead() {
        var classifier = StandingPoseClassifier()

        XCTAssertEqual(
            classifier.classify(
                frame(
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 171,
                        rightKneeAngle: 168,
                        hasVisibleLowerBody: true
                    )
                )
            ),
            .standing
        )
    }

    func testThreeDimensionalBentLegsDoNotConfirmStanding() {
        var classifier = StandingPoseClassifier()

        XCTAssertEqual(
            classifier.classify(
                frame(
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 92,
                        rightKneeAngle: 96,
                        hasVisibleLowerBody: true
                    )
                )
            ),
            .notStanding
        )
    }

    func testVisibleBent3DLegsOverrideNoisyHeadRise() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.54,
                faceHeight: 0.11,
                upperBodyY: 0.66,
                upperBodyHeight: 0.46,
                shoulderY: 0.71
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.80,
                    faceHeight: 0.11,
                    upperBodyY: 0.70,
                    upperBodyHeight: 0.45,
                    shoulderY: 0.73,
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 34,
                        rightKneeAngle: 31,
                        hasVisibleLowerBody: true
                    )
                )
            ),
            .notStanding
        )
    }

    func testThreeDimensionalStandingToleratesCameraPerspective() {
        var classifier = StandingPoseClassifier()

        XCTAssertEqual(
            classifier.classify(
                frame(
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 126,
                        rightKneeAngle: 139,
                        hasVisibleLowerBody: true
                    )
                )
            ),
            .standing
        )
    }

    func testInferred3DLegsCannotConfirmStandingWhenSitting() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.488,
                faceHeight: 0.121,
                upperBodyY: 0.595,
                upperBodyHeight: 0.573,
                shoulderY: 0.592
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.489,
                    faceHeight: 0.126,
                    shoulderY: 0.594,
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 137,
                        rightKneeAngle: 144,
                        hasVisibleLowerBody: false
                    )
                )
            ),
            .unavailable
        )
    }

    func testThreeDimensionalAsymmetricBadFrameIsNotStanding() {
        var classifier = StandingPoseClassifier()

        XCTAssertEqual(
            classifier.classify(
                frame(
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 130,
                        rightKneeAngle: 170
                    )
                )
            ),
            .unavailable
        )
    }

    func testCroppedLowerBodyDoesNotResetOnUnreliableBentEstimate() {
        var classifier = StandingPoseClassifier()

        XCTAssertEqual(
            classifier.classify(
                frame(
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 72,
                        rightKneeAngle: 79,
                        hasVisibleLowerBody: false
                    )
                )
            ),
            .unavailable
        )
    }

    func testPartialLowerBodyNeedsShoulderRiseFromSeatedBaseline() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                shoulderY: 0.72,
                hips: [
                    CGPoint(x: 0.45, y: 0.56),
                    CGPoint(x: 0.55, y: 0.56)
                ],
                knees: [
                    CGPoint(x: 0.46, y: 0.38),
                    CGPoint(x: 0.54, y: 0.38)
                ],
                ankles: [
                    CGPoint(x: 0.47, y: 0.12)
                ]
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    shoulderY: 0.82,
                    hips: [
                        CGPoint(x: 0.45, y: 0.60),
                        CGPoint(x: 0.55, y: 0.60)
                    ],
                    knees: [
                        CGPoint(x: 0.46, y: 0.38),
                        CGPoint(x: 0.54, y: 0.38)
                    ],
                    ankles: [
                        CGPoint(x: 0.47, y: 0.12)
                    ]
                )
            ),
            .standing
        )
    }

    func testStaticPartialSkeletonDoesNotMistakeSittingForStanding() {
        var classifier = StandingPoseClassifier()
        let sittingFrame = frame(
            shoulderY: 0.72,
            hips: [
                CGPoint(x: 0.45, y: 0.56),
                CGPoint(x: 0.55, y: 0.56)
            ],
            knees: [
                CGPoint(x: 0.46, y: 0.38),
                CGPoint(x: 0.54, y: 0.38)
            ],
            ankles: [
                CGPoint(x: 0.47, y: 0.12)
            ]
        )
        classifier.observeSeatedReference(sittingFrame)

        XCTAssertEqual(
            classifier.classify(sittingFrame),
            .notStanding
        )
    }

    func testNearPresetDoesNotTrustUpperBodyWhenHeadLeavesFrame() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.72,
                faceHeight: 0.20,
                upperBodyY: 0.70,
                upperBodyHeight: 0.40,
                shoulderY: 0.40
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    upperBodyY: 0.76,
                    upperBodyHeight: 0.40,
                    shoulderY: 0.48,
                    hips: [
                        CGPoint(x: 0.44, y: 0.36),
                        CGPoint(x: 0.56, y: 0.36)
                    ]
                )
            ),
            .unavailable
        )
    }

    func testNearPresetAcceptsHeadRiseWithVerifiedUpperBody() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.692,
                faceHeight: 0.186,
                upperBodyY: 0.509,
                upperBodyHeight: 0.759,
                shoulderY: 0.502
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.753,
                    faceHeight: 0.226,
                    upperBodyY: 0.477,
                    upperBodyHeight: 0.915,
                    shoulderY: 0.580,
                    hips: [
                        CGPoint(x: 0.44, y: 0.36),
                        CGPoint(x: 0.56, y: 0.36)
                    ]
                )
            ),
            .standing
        )
    }

    func testNearPresetStillRejectsHeadRiseWithoutUpperBody() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.692,
                faceHeight: 0.186,
                upperBodyY: 0.509,
                upperBodyHeight: 0.759,
                shoulderY: 0.502
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.753,
                    faceHeight: 0.226
                )
            ),
            .unavailable
        )
    }

    func testNearPresetRejectsHeadRiseWithUnchangedTorso() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.692,
                faceHeight: 0.186,
                upperBodyY: 0.509,
                upperBodyHeight: 0.759,
                shoulderY: 0.502
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.753,
                    faceHeight: 0.226,
                    upperBodyY: 0.500,
                    upperBodyHeight: 0.770,
                    shoulderY: 0.505
                )
            ),
            .notStanding
        )
    }

    func testCompactSpaceStandingDoesNotRequireVisibleLegs() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.543,
                faceHeight: 0.130,
                upperBodyY: 0.535,
                upperBodyHeight: 0.779,
                shoulderY: 0.497
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.748,
                    faceHeight: 0.218,
                    upperBodyY: 0.474,
                    upperBodyHeight: 0.890,
                    shoulderY: 0.570,
                    hips: [
                        CGPoint(x: 0.44, y: 0.35),
                        CGPoint(x: 0.56, y: 0.35)
                    ],
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 90,
                        rightKneeAngle: 40,
                        hasVisibleLowerBody: false
                    )
                )
            ),
            .standing
        )
    }

    func testCompactSpaceMinorSeatedMovementIsNotStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.543,
                faceHeight: 0.130,
                upperBodyY: 0.535,
                upperBodyHeight: 0.779,
                shoulderY: 0.497
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.575,
                    faceHeight: 0.140,
                    upperBodyY: 0.550,
                    upperBodyHeight: 0.810,
                    shoulderY: 0.505
                )
            ),
            .notStanding
        )
    }

    func testCompactSpaceSaturatedTorsoUsesSustainedBodyDisplacement() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.599,
                faceHeight: 0.127,
                upperBodyY: 0.517,
                upperBodyHeight: 0.955,
                shoulderY: 0.702
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.738,
                    faceHeight: 0.210,
                    upperBodyY: 0.459,
                    upperBodyHeight: 0.910,
                    shoulderY: 0.620,
                    hips: [
                        CGPoint(x: 0.44, y: 0.34),
                        CGPoint(x: 0.56, y: 0.34)
                    ],
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 77,
                        rightKneeAngle: 77,
                        hasVisibleLowerBody: false
                    )
                )
            ),
            .standing
        )
    }

    func testSeatedFaceDetectorJumpWithoutHipsCannotStartStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.617,
                faceHeight: 0.134,
                upperBodyY: 0.585,
                upperBodyHeight: 0.382,
                shoulderY: 0.533
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.517,
                    faceHeight: 0.102,
                    upperBodyY: 0.565,
                    upperBodyHeight: 0.352,
                    shoulderY: 0.504
                )
            ),
            .notStanding
        )
    }

    func testCompactSpaceTorsoShrinkUsesShouldersAndHipsWithoutLegs() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.594,
                faceHeight: 0.137,
                upperBodyY: 0.549,
                upperBodyHeight: 0.525,
                shoulderY: 0.603
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.595,
                    faceHeight: 0.147,
                    upperBodyY: 0.587,
                    upperBodyHeight: 0.302,
                    shoulderY: 0.500,
                    hips: [
                        CGPoint(x: 0.44, y: 0.36),
                        CGPoint(x: 0.56, y: 0.36)
                    ],
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 75,
                        rightKneeAngle: 117,
                        hasVisibleLowerBody: false
                    )
                )
            ),
            .standing
        )
    }

    func testCompactSpaceTorsoShrinkWithoutTwoHipsIsNotStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.594,
                faceHeight: 0.137,
                upperBodyY: 0.549,
                upperBodyHeight: 0.525,
                shoulderY: 0.603
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.595,
                    faceHeight: 0.147,
                    upperBodyY: 0.587,
                    upperBodyHeight: 0.302,
                    shoulderY: 0.759,
                    hips: [
                        CGPoint(x: 0.44, y: 0.36)
                    ]
                )
            ),
            .notStanding
        )
    }

    func testBentLegDoesNotCountAsStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(shoulderY: 0.52)
        )
        let bentLeg = StandingLegPose(
            hip: CGPoint(x: 0.5, y: 0.62),
            knee: CGPoint(x: 0.5, y: 0.36),
            ankle: CGPoint(x: 0.72, y: 0.34)
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    shoulderY: 0.52,
                    legs: [bentLeg]
                )
            ),
            .notStanding
        )
    }

    func testSeatedPoseDoesNotCountAsStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.50,
                upperBodyY: 0.45,
                shoulderY: 0.42
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.52,
                    upperBodyY: 0.47,
                    shoulderY: 0.44
                )
            ),
            .notStanding
        )
    }

    func testOnlyVisibleHeadCannotConfirmStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(frame(faceY: 0.50))

        XCTAssertEqual(
            classifier.classify(frame(faceY: 0.55)),
            .unavailable
        )
    }

    func testModerateFaceRiseAndSmallerFaceConfirmStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.50,
                faceHeight: 0.24,
                upperBodyY: 0.45,
                upperBodyHeight: 0.50,
                shoulderY: 0.36
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.53,
                    faceHeight: 0.18,
                    upperBodyY: 0.50,
                    upperBodyHeight: 0.50,
                    shoulderY: 0.50,
                    hips: [
                        CGPoint(x: 0.44, y: 0.36),
                        CGPoint(x: 0.56, y: 0.36)
                    ]
                )
            ),
            .standing
        )
    }

    func testMuchSmallerFaceCanConfirmStandingWithoutLargeRise() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.50,
                faceHeight: 0.24,
                upperBodyY: 0.45,
                upperBodyHeight: 0.50,
                shoulderY: 0.36
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.50,
                    faceHeight: 0.16,
                    upperBodyY: 0.50,
                    upperBodyHeight: 0.50,
                    shoulderY: 0.44,
                    hips: [
                        CGPoint(x: 0.44, y: 0.36),
                        CGPoint(x: 0.56, y: 0.36)
                    ]
                )
            ),
            .standing
        )
    }

    func testLargeFaceSelectsNearHeadPreset() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.50,
                faceHeight: 0.20,
                shoulderY: 0.42
            )
        )

        XCTAssertEqual(classifier.activePreset, .nearHead)
    }

    func testSmallFaceSelectsFarSkeletonPreset() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.50,
                faceHeight: 0.10,
                upperBodyY: 0.42,
                upperBodyHeight: 0.36,
                shoulderY: 0.42
            )
        )

        XCTAssertEqual(classifier.activePreset, .farSkeleton)
    }

    func testFarPresetFallsBackToHeadWhenLowerBodyIsNotVisible() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.50,
                faceHeight: 0.10,
                upperBodyY: 0.42,
                upperBodyHeight: 0.36,
                shoulderY: 0.42
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.58,
                    faceHeight: 0.10,
                    upperBodyY: 0.48,
                    upperBodyHeight: 0.36,
                    shoulderY: 0.50,
                    hips: [
                        CGPoint(x: 0.44, y: 0.36),
                        CGPoint(x: 0.56, y: 0.36)
                    ]
                )
            ),
            .standing
        )
    }

    func testFarPresetUsesRealCameraTorsoRevealWhenLegsAreOutOfFrame() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.687,
                faceHeight: 0.089,
                upperBodyY: 0.717,
                upperBodyHeight: 0.505,
                shoulderY: 0.550,
                hips: [
                    CGPoint(x: 0.45, y: 0.46),
                    CGPoint(x: 0.55, y: 0.46)
                ]
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.640,
                    faceHeight: 0.084,
                    upperBodyY: 0.709,
                    upperBodyHeight: 0.545,
                    shoulderY: 0.620,
                    hips: [
                        CGPoint(x: 0.45, y: 0.43),
                        CGPoint(x: 0.55, y: 0.43)
                    ]
                )
            ),
            .standing
        )
    }

    func testTorsoRevealStillRequiresBothHips() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.687,
                faceHeight: 0.089,
                upperBodyY: 0.717,
                upperBodyHeight: 0.505,
                shoulderY: 0.550,
                hips: [
                    CGPoint(x: 0.45, y: 0.46),
                    CGPoint(x: 0.55, y: 0.46)
                ]
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.640,
                    faceHeight: 0.084,
                    upperBodyY: 0.709,
                    upperBodyHeight: 0.545,
                    shoulderY: 0.620,
                    hips: [CGPoint(x: 0.45, y: 0.43)]
                )
            ),
            .notStanding
        )
    }

    func testOneBentLegFrameCannotVetoHeadAndUpperBodyRise() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.50,
                faceHeight: 0.10,
                upperBodyY: 0.42,
                upperBodyHeight: 0.36,
                shoulderY: 0.42
            )
        )
        let noisyBentLeg = StandingLegPose(
            hip: CGPoint(x: 0.48, y: 0.60),
            knee: CGPoint(x: 0.50, y: 0.38),
            ankle: CGPoint(x: 0.70, y: 0.36)
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.58,
                    faceHeight: 0.10,
                    upperBodyY: 0.48,
                    upperBodyHeight: 0.36,
                    shoulderY: 0.50,
                    hips: [
                        CGPoint(x: 0.44, y: 0.36),
                        CGPoint(x: 0.56, y: 0.36)
                    ],
                    legs: [noisyBentLeg]
                )
            ),
            .standing
        )
    }

    func testFarPresetAlsoRejectsHeadWithoutTorso() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.50,
                faceHeight: 0.10
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.58,
                    faceHeight: 0.10
                )
            ),
            .unavailable
        )
    }

    func testMissingPersonIsUnavailableInsteadOfLatchedStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.50,
                upperBodyY: 0.45,
                shoulderY: 0.42
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.58,
                    upperBodyY: 0.51,
                    shoulderY: 0.50,
                    hips: [
                        CGPoint(x: 0.44, y: 0.36),
                        CGPoint(x: 0.56, y: 0.36)
                    ]
                )
            ),
            .standing
        )
        XCTAssertEqual(
            classifier.classify(frame()),
            .unavailable
        )
    }

    func testSeatedBaselineDriftWithHipsCannotStartStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.636,
                faceHeight: 0.247,
                upperBodyY: 0.506,
                upperBodyHeight: 0.978,
                shoulderY: 0.711
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.718,
                    faceHeight: 0.218,
                    upperBodyY: 0.455,
                    upperBodyHeight: 0.874,
                    shoulderY: 0.758,
                    hips: [
                        CGPoint(x: 0.44, y: 0.35),
                        CGPoint(x: 0.56, y: 0.35)
                    ],
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 140,
                        rightKneeAngle: 29,
                        hasVisibleLowerBody: false
                    )
                )
            ),
            .unavailable
        )
    }

    func testMismatchedFaceBelowShouldersCannotConfirmStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.741,
                faceHeight: 0.267,
                upperBodyY: 0.507,
                upperBodyHeight: 0.856,
                shoulderY: 0.559
            )
        )

        XCTAssertEqual(
            classifier.classify(
                frame(
                    faceY: 0.575,
                    faceHeight: 0.130,
                    upperBodyY: 0.751,
                    upperBodyHeight: 0.186,
                    shoulderY: 0.757,
                    hips: [
                        CGPoint(x: 0.44, y: 0.58),
                        CGPoint(x: 0.56, y: 0.58)
                    ],
                    body3D: StandingBodyPose3DSample(
                        leftKneeAngle: 140,
                        rightKneeAngle: 131,
                        hasVisibleLowerBody: false
                    )
                )
            ),
            .unavailable
        )
    }

    func testStableCroppedTorsoExpansionConfirmsWithoutHipsOrLegs() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.531,
                faceHeight: 0.148,
                upperBodyY: 0.491,
                upperBodyHeight: 0.589,
                shoulderY: 0.487
            )
        )
        let standingFrame = frame(
            faceY: 0.525,
            faceHeight: 0.144,
            upperBodyY: 0.509,
            upperBodyHeight: 0.969,
            shoulderY: 0.485,
            body3D: StandingBodyPose3DSample(
                leftKneeAngle: 137,
                rightKneeAngle: 139,
                hasVisibleLowerBody: false
            )
        )

        XCTAssertNotEqual(
            classifier.classify(standingFrame),
            .standing
        )
        XCTAssertNotEqual(
            classifier.classify(standingFrame),
            .standing
        )
        XCTAssertEqual(
            classifier.classify(standingFrame),
            .standing
        )
    }

    func testOneCroppedTorsoScaleJumpCannotConfirmStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.531,
                faceHeight: 0.148,
                upperBodyY: 0.491,
                upperBodyHeight: 0.589,
                shoulderY: 0.487
            )
        )

        XCTAssertNotEqual(
            classifier.classify(
                frame(
                    faceY: 0.525,
                    faceHeight: 0.144,
                    upperBodyY: 0.509,
                    upperBodyHeight: 0.969,
                    shoulderY: 0.485
                )
            ),
            .standing
        )
    }

    func testRealStandingShoulderRiseWithHipsConfirmsAfterVoting() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.508,
                faceHeight: 0.106,
                upperBodyY: 0.531,
                upperBodyHeight: 0.369,
                shoulderY: 0.555
            )
        )
        let standingFrame = frame(
            faceY: 0.529,
            faceHeight: 0.145,
            upperBodyY: 0.529,
            upperBodyHeight: 0.325,
            shoulderY: 0.744,
            hips: [
                CGPoint(x: 0.44, y: 0.38),
                CGPoint(x: 0.56, y: 0.38)
            ]
        )

        XCTAssertNotEqual(classifier.classify(standingFrame), .standing)
        XCTAssertNotEqual(classifier.classify(standingFrame), .standing)
        XCTAssertEqual(classifier.classify(standingFrame), .standing)
    }

    func testRealCloseStandingScaleChangeConfirmsWithoutVisibleLegs() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.508,
                faceHeight: 0.106,
                upperBodyY: 0.531,
                upperBodyHeight: 0.369,
                shoulderY: 0.555
            )
        )
        let standingFrame = frame(
            faceY: 0.721,
            faceHeight: 0.223,
            upperBodyY: 0.462,
            upperBodyHeight: 0.890,
            shoulderY: 0.505
        )

        XCTAssertNotEqual(classifier.classify(standingFrame), .standing)
        XCTAssertNotEqual(classifier.classify(standingFrame), .standing)
        XCTAssertEqual(classifier.classify(standingFrame), .standing)
    }

    func testCenterStageStandingUsesTorsoChangeWithStableFace() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.594,
                faceHeight: 0.145,
                upperBodyY: 0.447,
                upperBodyHeight: 0.666,
                shoulderY: 0.628
            )
        )
        let standingFrame = frame(
            faceY: 0.579,
            faceHeight: 0.128,
            upperBodyY: 0.526,
            upperBodyHeight: 0.920,
            shoulderY: 0.688
        )

        XCTAssertNotEqual(classifier.classify(standingFrame), .standing)
        XCTAssertNotEqual(classifier.classify(standingFrame), .standing)
        XCTAssertEqual(classifier.classify(standingFrame), .standing)
    }

    func testCroppedHeadUsesTorsoScaleAndShoulderRise() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.594,
                faceHeight: 0.145,
                upperBodyY: 0.447,
                upperBodyHeight: 0.666,
                shoulderY: 0.628
            )
        )
        let standingFrame = frame(
            upperBodyY: 0.508,
            upperBodyHeight: 0.969,
            shoulderY: 0.801
        )

        XCTAssertNotEqual(classifier.classify(standingFrame), .standing)
        XCTAssertNotEqual(classifier.classify(standingFrame), .standing)
        XCTAssertEqual(classifier.classify(standingFrame), .standing)
    }

    func testRepeatedMismatchedDetectorsDoNotConfirmStanding() {
        var classifier = StandingPoseClassifier()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.741,
                faceHeight: 0.267,
                upperBodyY: 0.507,
                upperBodyHeight: 0.856,
                shoulderY: 0.559
            )
        )
        let mismatchedFrame = frame(
            faceY: 0.575,
            faceHeight: 0.130,
            upperBodyY: 0.751,
            upperBodyHeight: 0.186,
            shoulderY: 0.757,
            hips: [
                CGPoint(x: 0.44, y: 0.58),
                CGPoint(x: 0.56, y: 0.58)
            ]
        )

        for _ in 0..<8 {
            XCTAssertNotEqual(
                classifier.classify(mismatchedFrame),
                .standing
            )
        }
    }

    func testRecordedCloseStandingCompletesFullConfirmationPipeline() {
        var classifier = StandingPoseClassifier()
        var smoother = StandingObservationSmoother()
        var detector = StandingGestureDetector()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.508,
                faceHeight: 0.106,
                upperBodyY: 0.531,
                upperBodyHeight: 0.369,
                shoulderY: 0.555
            )
        )
        let recordedStandingFrame = frame(
            faceY: 0.721,
            faceHeight: 0.223,
            upperBodyY: 0.462,
            upperBodyHeight: 0.890,
            shoulderY: 0.505,
            body3D: StandingBodyPose3DSample(
                leftKneeAngle: 126,
                rightKneeAngle: 127,
                hasVisibleLowerBody: false
            )
        )

        var confirmed = false
        for index in 0..<28 {
            let rawObservation = classifier.classify(
                recordedStandingFrame
            )
            let observation = smoother.ingest(rawObservation)
            confirmed = detector.ingest(
                observation,
                at: TimeInterval(index) * 0.5
            ) || confirmed
        }

        XCTAssertTrue(confirmed)
        XCTAssertEqual(detector.confirmedDuration(at: 14), 10)
    }

    func testRecordedCenterStageStandingCompletesFullPipeline() {
        var classifier = StandingPoseClassifier()
        var smoother = StandingObservationSmoother()
        var detector = StandingGestureDetector()
        classifier.observeSeatedReference(
            frame(
                faceY: 0.594,
                faceHeight: 0.145,
                upperBodyY: 0.447,
                upperBodyHeight: 0.666,
                shoulderY: 0.628
            )
        )
        let recordedStandingFrame = frame(
            faceY: 0.579,
            faceHeight: 0.128,
            upperBodyY: 0.526,
            upperBodyHeight: 0.920,
            shoulderY: 0.688,
            body3D: StandingBodyPose3DSample(
                leftKneeAngle: 102,
                rightKneeAngle: 114,
                hasVisibleLowerBody: false
            )
        )

        var confirmed = false
        for index in 0..<28 {
            let rawObservation = classifier.classify(
                recordedStandingFrame
            )
            let observation = smoother.ingest(rawObservation)
            confirmed = detector.ingest(
                observation,
                at: TimeInterval(index) * 0.5
            ) || confirmed
        }

        XCTAssertTrue(confirmed)
        XCTAssertEqual(detector.confirmedDuration(at: 14), 10)
    }

    func testProgressReportsContinuousStandingSeconds() {
        var detector = StandingGestureDetector()

        for index in 0...9 {
            XCTAssertFalse(
                detector.ingest(
                    .standing,
                    at: 20 + TimeInterval(index) * 0.5
                )
            )
        }
        XCTAssertEqual(detector.confirmedDuration(at: 24.5), 4.5)
        XCTAssertFalse(detector.ingest(.notStanding, at: 25))
        XCTAssertEqual(detector.confirmedDuration(at: 25), 4.5)
        for index in 1...6 {
            XCTAssertFalse(
                detector.ingest(
                    .notStanding,
                    at: 25 + TimeInterval(index) * 0.5
                )
            )
        }
        XCTAssertEqual(detector.confirmedDuration(at: 28), 0)
    }
}

final class StandingObservationSmootherTests: XCTestCase {
    func testSingleVisionDropoutKeepsStableStandingResult() {
        var smoother = StandingObservationSmoother()

        for _ in 0..<5 {
            XCTAssertEqual(smoother.ingest(.standing), .standing)
        }
        XCTAssertEqual(smoother.ingest(.notStanding), .standing)
        XCTAssertEqual(smoother.ingest(.unavailable), .standing)
    }

    func testStableSittingRequiresFourVotesInRecentWindow() {
        var smoother = StandingObservationSmoother()
        for _ in 0..<5 {
            _ = smoother.ingest(.standing)
        }

        XCTAssertEqual(smoother.ingest(.notStanding), .standing)
        XCTAssertEqual(smoother.ingest(.notStanding), .standing)
        XCTAssertEqual(smoother.ingest(.notStanding), .unavailable)
        XCTAssertEqual(smoother.ingest(.notStanding), .notStanding)
    }
}

final class StandingBodyPose3DStabilizerTests: XCTestCase {
    func testMedianRejectsSingleWildKneeFrame() {
        var stabilizer = StandingBodyPose3DStabilizer()
        let samples: [(CGFloat, CGFloat)] = [
            (138, 141),
            (136, 140),
            (83, 10),
            (137, 142),
            (139, 143)
        ]

        var result: StandingBodyPose3DSample?
        for sample in samples {
            result = stabilizer.ingest(
                StandingBodyPose3DSample(
                    leftKneeAngle: sample.0,
                    rightKneeAngle: sample.1
                )
            )
        }

        XCTAssertEqual(result?.leftKneeAngle, 137)
        XCTAssertEqual(result?.rightKneeAngle, 141)
    }

    func testVisibilityRequiresMostRecentSamplesToAgree() {
        var stabilizer = StandingBodyPose3DStabilizer()

        for isVisible in [true, false, true, false, false] {
            _ = stabilizer.ingest(
                StandingBodyPose3DSample(
                    leftKneeAngle: 90,
                    rightKneeAngle: 92,
                    hasVisibleLowerBody: isVisible
                )
            )
        }

        XCTAssertFalse(
            stabilizer.ingest(
                StandingBodyPose3DSample(
                    leftKneeAngle: 90,
                    rightKneeAngle: 92,
                    hasVisibleLowerBody: false
                )
            )?.hasVisibleLowerBody ?? true
        )
    }
}

final class PresenceSmootherTests: XCTestCase {
    func testRequiresTwoPositiveFramesToPublishPresence() {
        var smoother = PresenceSmoother()

        XCTAssertNil(smoother.ingest(true))
        XCTAssertEqual(smoother.ingest(true), true)
        XCTAssertTrue(smoother.isPresent)
    }

    func testRequiresFourNegativeFramesToPublishAbsence() {
        var smoother = PresenceSmoother()
        _ = smoother.ingest(true)
        _ = smoother.ingest(true)

        XCTAssertNil(smoother.ingest(false))
        XCTAssertNil(smoother.ingest(false))
        XCTAssertNil(smoother.ingest(false))
        XCTAssertEqual(smoother.ingest(false), false)
        XCTAssertFalse(smoother.isPresent)
    }
}

final class ReminderIntervalInputTests: XCTestCase {
    func testAcceptsCustomMinutesWithinRange() {
        XCTAssertEqual(ReminderIntervalInput.parseMinutes(" 90 "), 90)
        XCTAssertEqual(ReminderIntervalInput.parseMinutes("1"), 1)
        XCTAssertEqual(ReminderIntervalInput.parseMinutes("720"), 720)
    }

    func testRejectsInvalidOrOutOfRangeMinutes() {
        XCTAssertNil(ReminderIntervalInput.parseMinutes("0"))
        XCTAssertNil(ReminderIntervalInput.parseMinutes("721"))
        XCTAssertNil(ReminderIntervalInput.parseMinutes("45.5"))
        XCTAssertNil(ReminderIntervalInput.parseMinutes("喝水"))
    }
}

final class WalkAnimationVariantTests: XCTestCase {
    func testBothWalkVariantsParticipateInRandomSelection() {
        XCTAssertEqual(
            Set(WalkAnimationVariant.allCases),
            Set([.natural, .alternate])
        )
    }

    func testAlternateWalkKeepsTheAuthoredForwardFrameOrder() {
        XCTAssertEqual(
            WalkAnimationVariant.alternate.prepareFrames,
            [0, 1, 2, 3, 4, 5]
        )
        XCTAssertEqual(
            WalkAnimationVariant.alternate.strideFrames,
            [6, 7, 8, 9, 10, 11, 12, 13]
        )
        XCTAssertEqual(
            WalkAnimationVariant.alternate.settleFrames,
            [5, 4, 3, 2, 1, 0]
        )
    }

    func testExistingWalkRetainsItsCorrectedStrideOrder() {
        XCTAssertEqual(
            WalkAnimationVariant.natural.strideFrames,
            [8, 13, 12, 11, 10, 9]
        )
    }

    func testBothWalkFrameSetsAreAvailable() {
        for index in 1...21 {
            XCTAssertNotNil(
                AssetLoader.frame(
                    named: String(
                        format: "natural-walk-%02d.png",
                        index
                    )
                )
            )
        }
        for index in 1...14 {
            XCTAssertNotNil(
                AssetLoader.frame(
                    named: String(
                        format: "alternate-walk-%02d.png",
                        index
                    )
                )
            )
        }
    }
}

final class FeedingInteractionTests: XCTestCase {
    func testBackendQuickActionProvidesMenuBarFallback() {
        XCTAssertEqual(PetView.QuickAction.status.title, "后台")
        XCTAssertEqual(
            PetView.QuickAction.status.symbolName,
            "slider.horizontal.3"
        )
        XCTAssertEqual(PetView.QuickAction.status.iconName, "settings.svg")
        XCTAssertNotNil(AssetLoader.icon(named: "kiwi.svg"))
    }

    func testCameraQuickActionIsReplacedByFeedingOnly() {
        XCTAssertEqual(PetView.QuickAction.feed.title, "喂食")
        XCTAssertEqual(PetView.QuickAction.feed.iconName, "feed.svg")
        XCTAssertFalse(
            PetView.QuickAction.allCases.contains {
                $0.title == "相机"
            }
        )
    }

    func testSuppliedBagAndFoodAssetsAreAvailable() {
        XCTAssertNotNil(AssetLoader.frame(named: "feed-bag.png"))
        XCTAssertNotNil(
            AssetLoader.frame(named: "feed-bag-empty.png")
        )
        XCTAssertNotNil(AssetLoader.frame(named: "feed-food.png"))
        for index in 1...4 {
            XCTAssertNotNil(
                AssetLoader.frame(
                    named: String(
                        format: "feed-action-%02d.png",
                        index
                    )
                )
            )
        }
        XCTAssertNotNil(AssetLoader.icon(named: "feed.svg"))
    }

    func testFeedingStartsInASeparateMovableDesktopWindow() {
        let petWindow = PetWindow(
            frame: NSRect(
                origin: NSPoint(x: 200, y: 160),
                size: PetView.preferredWindowSize
            )
        )
        let petView = PetView(
            frame: NSRect(
                origin: .zero,
                size: PetView.preferredWindowSize
            )
        )
        petWindow.contentView = petView
        petView.startFeeding()
        var feedingWindows = NSApp.windows.compactMap {
            $0 as? FeedingDesktopWindow
        }
        defer {
            petView.cancelFeeding()
            feedingWindows.forEach { $0.close() }
            petWindow.close()
        }

        XCTAssertTrue(
            feedingWindows.contains {
                abs($0.frame.width - 124) < 0.1
                    && abs($0.frame.height - 108) < 0.1
            },
            "The full bag must be independent from the pet window."
        )

        let bagWindow = feedingWindows.first {
            abs($0.frame.width - 124) < 0.1
                && abs($0.frame.height - 108) < 0.1
        }
        bagWindow?.onClick?()
        feedingWindows = NSApp.windows.compactMap {
            $0 as? FeedingDesktopWindow
        }
        XCTAssertTrue(
            feedingWindows.contains {
                abs($0.frame.width - 112) < 0.1
                    && abs($0.frame.height - 58) < 0.1
            },
            "Opening the bag must create an independently draggable food window."
        )
        let emptyBagImage = (bagWindow?.contentView as? NSImageView)?
            .image
        XCTAssertEqual(
            emptyBagImage?.size,
            AssetLoader.frame(named: "feed-bag-empty.png")?.size
        )

        if let snapshotPath = ProcessInfo.processInfo.environment[
            "KIWI_FEEDING_SNAPSHOT"
        ],
           let bagView = bagWindow?.contentView,
           let representation =
               bagView.bitmapImageRepForCachingDisplay(
                   in: bagView.bounds
               ) {
            bagView.cacheDisplay(
                in: bagView.bounds,
                to: representation
            )
            let data = representation.representation(
                using: .png,
                properties: [:]
            )
            try? data?.write(
                to: URL(fileURLWithPath: snapshotPath)
            )
        }
    }

    func testPathPlannerWalksTowardFoodAndStaysOnScreen() {
        let visibleFrame = NSRect(
            x: 0,
            y: 0,
            width: 1440,
            height: 900
        )
        let petFrame = NSRect(
            x: 120,
            y: 120,
            width: 360,
            height: 420
        )
        let characterOffset = NSPoint(x: 180, y: 195)
        let rightPlan = FeedingPathPlanner.plan(
            petFrame: petFrame,
            characterCenterOffset: characterOffset,
            foodFrame: NSRect(
                x: 980,
                y: 280,
                width: 112,
                height: 58
            ),
            visibleFrame: visibleFrame
        )
        let leftEdgePlan = FeedingPathPlanner.plan(
            petFrame: petFrame,
            characterCenterOffset: characterOffset,
            foodFrame: NSRect(
                x: -20,
                y: 80,
                width: 112,
                height: 58
            ),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(rightPlan.direction, 1)
        XCTAssertGreaterThan(rightPlan.distance, 0)
        XCTAssertGreaterThan(rightPlan.duration, 0)
        XCTAssertLessThanOrEqual(
            rightPlan.destinationOrigin.x + petFrame.width,
            visibleFrame.maxX
        )
        XCTAssertEqual(leftEdgePlan.direction, -1)
        XCTAssertGreaterThanOrEqual(
            leftEdgePlan.destinationOrigin.x,
            visibleFrame.minX
        )
        XCTAssertGreaterThanOrEqual(
            leftEdgePlan.destinationOrigin.y,
            visibleFrame.minY
        )
    }

    func testPickupTimelineBendsChewsAndReturnsUpright() {
        XCTAssertEqual(
            FeedingActionTimeline.frameIndex(at: 0),
            0
        )
        XCTAssertEqual(
            FeedingActionTimeline.frameIndex(at: 0.55),
            3
        )
        XCTAssertEqual(
            FeedingActionTimeline.frameIndex(
                at: FeedingActionTimeline.duration - 0.01
            ),
            0
        )
        XCTAssertLessThan(
            FeedingActionTimeline.collectionTime,
            FeedingActionTimeline.duration
        )
    }

    func testFeedingFramesNeverEnlargeKiwi() {
        guard let idleImage = AssetLoader.frame(
            named: "idle-open.png"
        ),
              let idleSize = renderedVisibleSize(of: idleImage) else {
            return XCTFail("Missing measurable idle image")
        }

        for index in 1...4 {
            let name = String(
                format: "feed-action-%02d.png",
                index
            )
            guard let image = AssetLoader.frame(named: name),
                  let visibleSize = renderedVisibleSize(of: image) else {
                return XCTFail("Missing measurable \(name)")
            }
            XCTAssertLessThanOrEqual(
                visibleSize.width,
                idleSize.width * 1.03,
                "\(name) must not make Kiwi wider than the idle model."
            )
            XCTAssertLessThanOrEqual(
                visibleSize.height,
                idleSize.height * 1.04,
                "\(name) must not make Kiwi taller than the idle model."
            )
        }
    }

    private func renderedVisibleSize(
        of image: NSImage
    ) -> NSSize? {
        var imageRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &imageRect,
            context: nil,
            hints: nil
        ) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](
            repeating: 0,
            count: width * height * 4
        )
        let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard drewImage else { return nil }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width
            where pixels[(y * width + x) * 4 + 3] > 5 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let scale = min(
            PetView.characterSize.width / CGFloat(width),
            PetView.characterSize.height / CGFloat(height)
        )
        return NSSize(
            width: CGFloat(maxX - minX + 1) * scale,
            height: CGFloat(maxY - minY + 1) * scale
        )
    }
}

final class TaskVideoSourceTests: XCTestCase {
    func testBilibiliFieldHandlesPasteWithoutAnApplicationMainMenu() {
        XCTAssertEqual(
            TextEditingShortcut.action(
                forCharacters: "v",
                modifierFlags: .command
            ),
            #selector(NSText.paste(_:))
        )
        XCTAssertEqual(
            TextEditingShortcut.action(
                forCharacters: "A",
                modifierFlags: [.command, .capsLock]
            ),
            #selector(NSText.selectAll(_:))
        )
        XCTAssertNil(
            TextEditingShortcut.action(
                forCharacters: "v",
                modifierFlags: [.command, .shift]
            )
        )
    }

    func testBilibiliFieldContextMenuIncludesPaste() {
        let menu = TextEditingShortcut.makeContextMenu()
        let pasteItem = menu.items.first { $0.title == "粘贴" }

        XCTAssertEqual(pasteItem?.action, #selector(NSText.paste(_:)))
        XCTAssertNil(pasteItem?.target)
    }

    func testBilibiliUsesTheOfficialExternalPlayer() {
        let url = BilibiliVideoChoice.defaultChoice.playerURL
        let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )

        XCTAssertEqual(url.host, "player.bilibili.com")
        XCTAssertEqual(url.path, "/player.html")
        XCTAssertEqual(query["bvid"], "BV1hR4y1X7zF")
        XCTAssertEqual(query["autoplay"], "0")
        XCTAssertEqual(query["danmaku"], "0")
    }

    func testBilibiliBrowserFallbackUsesThePublicVideoPage() {
        let url = BilibiliVideoChoice.defaultChoice.publicURL

        XCTAssertEqual(url.host, "www.bilibili.com")
        XCTAssertEqual(url.path, "/video/BV1hR4y1X7zF")
    }

    func testParsesBVIDAndPageFromFullVideoURL() {
        let choice = BilibiliVideoChoice(
            input:
                "https://www.bilibili.com/video/BV1xx411c7mD/?p=3"
        )

        XCTAssertEqual(choice?.bvid, "BV1xx411c7mD")
        XCTAssertEqual(choice?.page, 3)
        XCTAssertEqual(
            choice?.publicURL.absoluteString,
            "https://www.bilibili.com/video/BV1xx411c7mD/?p=3"
        )
    }

    func testParsesBareBVIDAndRejectsInvalidInput() {
        XCTAssertEqual(
            BilibiliVideoChoice(input: "BV1xx411c7mD")?.page,
            1
        )
        XCTAssertNil(BilibiliVideoChoice(input: "随便放一个视频"))
        XCTAssertNil(
            BilibiliVideoChoice(input: "https://b23.tv/example")
        )
    }

    func testCustomChoicePersistsWithoutSavingAnArbitraryURL() {
        let suiteName = "KiwiPetTests.BilibiliVideoPreference"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let choice = BilibiliVideoChoice(
            input:
                "https://www.bilibili.com/video/BV1xx411c7mD/?p=2"
        )!

        BilibiliVideoPreference.save(choice, to: defaults)

        XCTAssertEqual(
            defaults.string(
                forKey: BilibiliVideoPreference.defaultsKey
            ),
            "BV1xx411c7mD|2"
        )
        XCTAssertEqual(
            BilibiliVideoPreference.load(from: defaults),
            choice
        )
    }
}

final class TaskBreakActivityTests: XCTestCase {
    func testShortTaskPopupUsesTheRandomlySelectedActivity() {
        let activity = TaskBreakActivitySelection.initialActivity(
            for: .shortVideos,
            randomActivity: { .feedKiwi }
        )

        XCTAssertEqual(activity, .feedKiwi)
    }

    func testLongTaskPopupStillUsesKnowledgeVideo() {
        let activity = TaskBreakActivitySelection.initialActivity(
            for: .knowledgeVideo,
            randomActivity: { .feedKiwi }
        )

        XCTAssertEqual(activity, .watchVideo)
    }

    func testRandomActivitiesIncludeEveryFirstVersionChoice() {
        XCTAssertEqual(
            Set(TaskBreakActivity.allCases),
            Set([
                .watchVideo,
                .nap,
                .feedKiwi,
                .woodenFish
            ])
        )
        for activity in TaskBreakActivity.allCases {
            let alternatives = TaskBreakActivity.choices(
                excluding: activity
            )
            XCTAssertEqual(alternatives.count, 3)
            XCTAssertFalse(alternatives.contains(activity))
        }
    }

    func testTimerClosesAcrossFiveFramesEveryThirtySeconds() {
        XCTAssertEqual(TaskBreakTimerProgress.frameDuration, 6)
        XCTAssertEqual(TaskBreakTimerProgress.frameIndex(for: 0), 0)
        XCTAssertEqual(TaskBreakTimerProgress.frameIndex(for: 5), 0)
        XCTAssertEqual(TaskBreakTimerProgress.frameIndex(for: 6), 1)
        XCTAssertEqual(TaskBreakTimerProgress.frameIndex(for: 12), 2)
        XCTAssertEqual(TaskBreakTimerProgress.frameIndex(for: 18), 3)
        XCTAssertEqual(TaskBreakTimerProgress.frameIndex(for: 24), 4)
        XCTAssertEqual(TaskBreakTimerProgress.frameIndex(for: 29), 4)
        XCTAssertEqual(TaskBreakTimerProgress.frameIndex(for: 30), 0)
        var frame = 0
        var sequence = [frame]
        for _ in 0..<5 {
            frame = TaskBreakTimerProgress.nextFrameIndex(after: frame)
            sequence.append(frame)
        }
        XCTAssertEqual(sequence, [0, 1, 2, 3, 4, 0])
        XCTAssertEqual(TaskBreakTimerProgress.cycleIndex(for: 119), 0)
        XCTAssertEqual(TaskBreakTimerProgress.cycleIndex(for: 120), 1)
        XCTAssertEqual(
            TaskBreakTimerProgress.remainingDescription(for: 0),
            "本轮还剩 02:00"
        )
    }

    func testAllSuppliedTimerFramesAreAvailableAtOneSize() {
        let frames = (1...5).compactMap {
            AssetLoader.frame(
                named: String(format: "task-timer-%02d.png", $0)
            )
        }

        XCTAssertEqual(frames.count, 5)
        XCTAssertTrue(frames.allSatisfy { $0.size == frames[0].size })
        XCTAssertEqual(frames[0].size.width, 563)
        XCTAssertEqual(frames[0].size.height, 720)
    }
}

final class TaskBreakWindowLayoutTests: XCTestCase {
    func testShowMakesTheTaskBreakPopupVisible() {
        let controller = TaskBreakWindowController()
        defer { controller.close() }

        controller.show(
            recommendation: .shortVideos,
            duration: 6 * 60
        )

        XCTAssertEqual(controller.window?.isVisible, true)
    }

    func testCardLayoutContainsInteractiveVideoAndPlatformSwitch() {
        let controller = TaskBreakWindowController()
        controller.window?.setContentSize(
            NSSize(width: 720, height: 700)
        )
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Task break window has no content view")
        }
        contentView.layoutSubtreeIfNeeded()

        let webViews: [WKWebView] = descendants(
            of: WKWebView.self,
            in: contentView
        )
        let sourceControls: [NSSegmentedControl] = descendants(
            of: NSSegmentedControl.self,
            in: contentView
        )
        let imageViews: [NSImageView] = descendants(
            of: NSImageView.self,
            in: contentView
        )

        XCTAssertEqual(webViews.count, 1)
        XCTAssertGreaterThan(webViews[0].frame.width, 300)
        XCTAssertGreaterThan(webViews[0].frame.height, 250)
        guard let webContainer = webViews[0].superview else {
            return XCTFail("The video page has no viewport container")
        }
        XCTAssertEqual(
            webViews[0].frame,
            webContainer.bounds,
            "The video page must cover the whole rounded viewport"
        )
        XCTAssertEqual(sourceControls.count, 1)
        XCTAssertEqual(
            sourceControls[0].label(forSegment: 0),
            "抖音"
        )
        XCTAssertEqual(
            sourceControls[0].label(forSegment: 1),
            "B站"
        )
        XCTAssertNotNil(
            AssetLoader.frame(named: "task-break-peek.png")
        )
        guard let fullSizeKiwi = imageViews.first(
            where: { !$0.isHidden && $0.image != nil }
        ) else {
            return XCTFail("The peeking Kiwi is missing")
        }
        XCTAssertEqual(fullSizeKiwi.frame.width, 210, accuracy: 0.5)
        XCTAssertEqual(fullSizeKiwi.frame.height, 108, accuracy: 0.5)
        XCTAssertTrue(
            controller.window?.styleMask.contains(.resizable) == true
        )
        XCTAssertEqual(controller.window?.isMovable, true)
        XCTAssertEqual(
            controller.window?.isMovableByWindowBackground,
            true
        )
        XCTAssertTrue(controller.window is TaskBreakPanel)

        if let snapshotPath = ProcessInfo.processInfo.environment[
            "KIWI_TASK_BREAK_SNAPSHOT"
        ],
           let representation =
               contentView.bitmapImageRepForCachingDisplay(
                   in: contentView.bounds
               ) {
            contentView.cacheDisplay(
                in: contentView.bounds,
                to: representation
            )
            let data = representation.representation(
                using: .png,
                properties: [:]
            )
            try? data?.write(
                to: URL(fileURLWithPath: snapshotPath)
            )
        }
    }

    func testCompactWindowKeepsTheWebPageUsable() {
        let controller = TaskBreakWindowController()
        guard let window = controller.window,
              let contentView = window.contentView else {
            return XCTFail("Task break window has no content view")
        }

        XCTAssertLessThanOrEqual(window.contentMinSize.width, 300)
        XCTAssertEqual(window.contentMinSize.height, 360)

        window.setContentSize(NSSize(width: 300, height: 360))
        controller.windowDidResize(
            Notification(
                name: NSWindow.didResizeNotification,
                object: window
            )
        )
        contentView.layoutSubtreeIfNeeded()

        let webViews: [WKWebView] = descendants(
            of: WKWebView.self,
            in: contentView
        )
        let sourceControls: [NSSegmentedControl] = descendants(
            of: NSSegmentedControl.self,
            in: contentView
        )
        let imageViews: [NSImageView] = descendants(
            of: NSImageView.self,
            in: contentView
        )

        XCTAssertEqual(webViews.count, 1)
        XCTAssertGreaterThan(webViews[0].frame.width, 180)
        XCTAssertGreaterThan(webViews[0].frame.height, 80)
        XCTAssertEqual(sourceControls.count, 1)
        XCTAssertFalse(sourceControls[0].isHidden)
        guard let visibleKiwi = imageViews.first(
            where: { !$0.isHidden && $0.image != nil }
        ) else {
            return XCTFail("The peeking Kiwi disappeared in compact mode")
        }
        XCTAssertLessThan(visibleKiwi.frame.width, 210)
        XCTAssertGreaterThan(visibleKiwi.frame.width, 130)
        XCTAssertEqual(
            visibleKiwi.frame.width / visibleKiwi.frame.height,
            210 / 108,
            accuracy: 0.02
        )

        if let snapshotPath = ProcessInfo.processInfo.environment[
            "KIWI_TASK_BREAK_COMPACT_SNAPSHOT"
        ],
           let representation =
               contentView.bitmapImageRepForCachingDisplay(
                   in: contentView.bounds
               ) {
            contentView.cacheDisplay(
                in: contentView.bounds,
                to: representation
            )
            let data = representation.representation(
                using: .png,
                properties: [:]
            )
            try? data?.write(
                to: URL(fileURLWithPath: snapshotPath)
            )
        }
    }

    func testFeedingActivityHidesNapAnimationAndStartsDesktopFeeding() {
        let controller = TaskBreakWindowController()
        var requestedFeeding = false
        controller.onRequestFeeding = {
            requestedFeeding = true
        }
        controller.configureActivityPreview(
            .feedKiwi,
            duration: 48
        )
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Task break window has no content view")
        }
        contentView.layoutSubtreeIfNeeded()

        let webViews: [WKWebView] = descendants(
            of: WKWebView.self,
            in: contentView
        )
        let labels: [NSTextField] = descendants(
            of: NSTextField.self,
            in: contentView
        )
        let buttons: [NSButton] = descendants(
            of: NSButton.self,
            in: contentView
        )
        let imageViews: [NSImageView] = descendants(
            of: NSImageView.self,
            in: contentView
        )
        let timerImage = imageViews.first {
            $0.image?.size == NSSize(width: 563, height: 720)
        }
        let actionButton = buttons.first {
            $0.title == "拿食物喂 Kiwi"
        }

        XCTAssertEqual(webViews.count, 1)
        XCTAssertTrue(webViews[0].isHidden)
        XCTAssertTrue(
            labels.contains {
                $0.stringValue == "给 Kiwi 喂点东西"
            }
        )
        XCTAssertTrue(
            labels.contains {
                $0.stringValue == "本轮还剩 01:12"
            }
        )
        XCTAssertNotNil(actionButton)
        XCTAssertNotNil(timerImage)
        XCTAssertTrue(isEffectivelyHidden(timerImage))
        actionButton?.performClick(nil)
        XCTAssertTrue(requestedFeeding)

        if let snapshotPath = ProcessInfo.processInfo.environment[
            "KIWI_TASK_ACTIVITY_SNAPSHOT"
        ],
           let representation =
               contentView.bitmapImageRepForCachingDisplay(
                   in: contentView.bounds
               ) {
            contentView.cacheDisplay(
                in: contentView.bounds,
                to: representation
            )
            let data = representation.representation(
                using: .png,
                properties: [:]
            )
            try? data?.write(
                to: URL(fileURLWithPath: snapshotPath)
            )
        }
    }

    func testNapActivityShowsThirtySecondAnimation() {
        let controller = TaskBreakWindowController()
        controller.configureActivityPreview(
            .nap,
            duration: 12
        )
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Task break window has no content view")
        }
        contentView.layoutSubtreeIfNeeded()

        let imageViews: [NSImageView] = descendants(
            of: NSImageView.self,
            in: contentView
        )
        let labels: [NSTextField] = descendants(
            of: NSTextField.self,
            in: contentView
        )
        let buttons: [NSButton] = descendants(
            of: NSButton.self,
            in: contentView
        )
        let timerImage = imageViews.first {
            $0.image?.size == NSSize(width: 563, height: 720)
        }
        let visibleButtons = buttons.filter {
            !isEffectivelyHidden($0)
        }

        XCTAssertNotNil(timerImage)
        XCTAssertFalse(isEffectivelyHidden(timerImage))
        XCTAssertTrue(
            labels.contains { $0.stringValue == "小眯一会儿" }
        )
        XCTAssertEqual(
            Set(visibleButtons.map(\.title)),
            Set(["开始小眯", "休息好了"])
        )
        XCTAssertTrue(
            visibleButtons.allSatisfy {
                !$0.isBordered
                    && $0.layer?.backgroundColor != nil
            }
        )

        if let snapshotPath = ProcessInfo.processInfo.environment[
            "KIWI_TASK_NAP_SNAPSHOT"
        ],
           let representation =
               contentView.bitmapImageRepForCachingDisplay(
                   in: contentView.bounds
               ) {
            contentView.cacheDisplay(
                in: contentView.bounds,
                to: representation
            )
            let data = representation.representation(
                using: .png,
                properties: [:]
            )
            try? data?.write(
                to: URL(fileURLWithPath: snapshotPath)
            )
        }
    }

    func testCompletedActivityRemovesDisabledButtonSlots() {
        let controller = TaskBreakWindowController()
        controller.configureActivityPreview(
            .nap,
            duration: 12
        )
        controller.completeActiveTask(duration: 18)
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Task break window has no content view")
        }
        contentView.layoutSubtreeIfNeeded()

        let buttons: [NSButton] = descendants(
            of: NSButton.self,
            in: contentView
        )
        let visibleButtons = buttons.filter {
            !isEffectivelyHidden($0)
        }

        XCTAssertEqual(visibleButtons.map(\.title), ["休息好了"])
        XCTAssertTrue(visibleButtons[0].isEnabled)
        XCTAssertNotNil(visibleButtons[0].layer?.backgroundColor)
    }

    func testCompactWoodenFishKeepsActionVisibleWithoutNapAnimation() {
        let controller = TaskBreakWindowController()
        controller.configureActivityPreview(
            .woodenFish,
            duration: 96
        )
        guard let window = controller.window,
              let contentView = window.contentView else {
            return XCTFail("Task break window has no content view")
        }

        window.setContentSize(NSSize(width: 300, height: 360))
        controller.windowDidResize(
            Notification(
                name: NSWindow.didResizeNotification,
                object: window
            )
        )
        contentView.layoutSubtreeIfNeeded()

        let imageViews: [NSImageView] = descendants(
            of: NSImageView.self,
            in: contentView
        )
        let buttons: [NSButton] = descendants(
            of: NSButton.self,
            in: contentView
        )
        let timerImages = imageViews.filter {
            $0.image?.size == NSSize(width: 563, height: 720)
        }
        let actionButton = buttons.first {
            $0.title == "敲一下木鱼"
        }

        XCTAssertEqual(timerImages.count, 1)
        XCTAssertTrue(isEffectivelyHidden(timerImages.first))
        XCTAssertNotNil(actionButton)
        XCTAssertFalse(isEffectivelyHidden(actionButton))
    }

    func testWoodenFishUsesTwoAnimationFramesAndSeparateMallet() {
        let firstFrame = AssetLoader.frame(
            named: "wooden-fish-01.png"
        )
        let impactFrame = AssetLoader.frame(
            named: "wooden-fish-02.png"
        )
        let mallet = AssetLoader.frame(
            named: "wooden-fish-mallet.png"
        )

        XCTAssertEqual(
            firstFrame?.representations.first?.pixelsWide,
            1352
        )
        XCTAssertEqual(
            firstFrame?.representations.first?.pixelsHigh,
            898
        )
        XCTAssertEqual(impactFrame?.size, firstFrame?.size)
        XCTAssertEqual(
            mallet?.representations.first?.pixelsWide,
            685
        )
        XCTAssertEqual(
            mallet?.representations.first?.pixelsHigh,
            850
        )

        let controller = TaskBreakWindowController()
        controller.configureActivityPreview(
            .woodenFish,
            duration: 96
        )
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Task break window has no content view")
        }
        contentView.layoutSubtreeIfNeeded()

        let imageViews: [NSImageView] = descendants(
            of: NSImageView.self,
            in: contentView
        )
        let woodenFishViews = imageViews.filter {
            guard let identifier = $0.identifier?.rawValue else {
                return false
            }
            return ["woodenFishFrame", "woodenFishMallet"].contains(
                identifier
            )
        }

        XCTAssertEqual(woodenFishViews.count, 2)
        XCTAssertTrue(
            woodenFishViews.allSatisfy {
                !isEffectivelyHidden($0) && $0.image != nil
            }
        )

        let buttons: [NSButton] = descendants(
            of: NSButton.self,
            in: contentView
        )
        let actionButton = buttons.first {
            $0.title == "敲一下木鱼"
        }
        let frameView = woodenFishViews.first {
            $0.identifier?.rawValue == "woodenFishFrame"
        }
        actionButton?.performClick(nil)
        RunLoop.main.run(
            until: Date().addingTimeInterval(0.14)
        )
        XCTAssertEqual(
            frameView?.image?.tiffRepresentation,
            impactFrame?.tiffRepresentation
        )
        if !NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion,
           let malletView = woodenFishViews.first(where: {
               $0.identifier?.rawValue == "woodenFishMallet"
           }),
           let group = malletView.layer?.animation(
               forKey: "woodenFishMalletTap"
           ) as? CAAnimationGroup,
           let horizontal = group.animations?
               .compactMap({ $0 as? CAKeyframeAnimation })
               .first(where: {
                   $0.keyPath == "transform.translation.x"
               }),
           let impactX = horizontal.values?[1] as? NSNumber {
            XCTAssertLessThanOrEqual(
                impactX.doubleValue,
                -60,
                "棒头必须从右上方跨到 Kiwi 的头顶，而不是敲果篮"
            )
        }

        if let snapshotPath = ProcessInfo.processInfo.environment[
            "KIWI_TASK_WOODEN_FISH_SNAPSHOT"
        ],
           let representation =
               contentView.bitmapImageRepForCachingDisplay(
                   in: contentView.bounds
               ) {
            contentView.cacheDisplay(
                in: contentView.bounds,
                to: representation
            )
            let data = representation.representation(
                using: .png,
                properties: [:]
            )
            try? data?.write(
                to: URL(fileURLWithPath: snapshotPath)
            )
        }
    }

    func testVisibleBorderResizesTheWholePopup() {
        let controller = TaskBreakWindowController()
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Task break window has no content view")
        }
        contentView.updateTrackingAreas()
        XCTAssertTrue(
            contentView.trackingAreas.contains {
                $0.options.contains(.mouseEnteredAndExited)
                    && $0.options.contains(.activeAlways)
            },
            "Leaving the popup must restore the arrow cursor"
        )

        XCTAssertEqual(
            TaskBreakPanel.resizeEdges(
                at: NSPoint(x: 14, y: 200),
                in: NSRect(x: 0, y: 0, width: 520, height: 680)
            ),
            [.left]
        )
        XCTAssertEqual(
            TaskBreakPanel.resizeEdges(
                at: NSPoint(x: 510, y: 670),
                in: NSRect(x: 0, y: 0, width: 520, height: 680)
            ),
            [.right, .top]
        )
        XCTAssertEqual(
            TaskBreakPanel.resizeEdges(
                at: NSPoint(x: 260, y: 572),
                in: NSRect(x: 0, y: 0, width: 520, height: 680),
                visibleTopBorderInset: 108
            ),
            [.top],
            "The visible green top border must resize height"
        )
        XCTAssertEqual(
            TaskBreakPanel.resizeEdges(
                at: NSPoint(x: 260, y: 14),
                in: NSRect(x: 0, y: 0, width: 520, height: 680)
            ),
            [.bottom],
            "The visible green bottom border must resize height"
        )

        var tracker = TaskBreakWindowResizeTracker()
        tracker.begin(
            mouseLocation: NSPoint(x: 100, y: 200),
            windowFrame: NSRect(
                x: 500,
                y: 300,
                width: 520,
                height: 680
            ),
            edges: [.left, .top]
        )

        XCTAssertEqual(
            tracker.windowFrame(
                for: NSPoint(x: 80, y: 250),
                minimumSize: NSSize(width: 300, height: 360)
            ),
            NSRect(x: 480, y: 300, width: 540, height: 730)
        )

        tracker.reset()
        XCTAssertNil(
            tracker.windowFrame(
                for: NSPoint(x: 180, y: 180),
                minimumSize: NSSize(width: 300, height: 360)
            )
        )
    }

    private func descendants<T: NSView>(
        of type: T.Type,
        in view: NSView
    ) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: type, in: subview)
        }
    }

    private func isEffectivelyHidden(_ view: NSView?) -> Bool {
        var currentView = view
        while let current = currentView {
            if current.isHidden {
                return true
            }
            currentView = current.superview
        }
        return false
    }
}
