import Foundation

enum StandingPoseObservation: Equatable {
    case standing
    case notStanding
    case unavailable
}

struct StandingObservationSmoother {
    var windowSize = 5
    var standingVoteThreshold = 3
    var notStandingVoteThreshold = 4

    private var observations: [StandingPoseObservation] = []

    mutating func ingest(
        _ observation: StandingPoseObservation
    ) -> StandingPoseObservation {
        observations.append(observation)
        if observations.count > windowSize {
            observations.removeFirst(observations.count - windowSize)
        }

        let standingVotes = observations.filter {
            $0 == .standing
        }.count
        let notStandingVotes = observations.filter {
            $0 == .notStanding
        }.count

        if standingVotes >= min(
            standingVoteThreshold,
            observations.count
        ),
           standingVotes > notStandingVotes {
            return .standing
        }
        if notStandingVotes >= min(
            notStandingVoteThreshold,
            observations.count
        ),
           notStandingVotes > standingVotes {
            return .notStanding
        }
        return .unavailable
    }

    mutating func reset() {
        observations.removeAll(keepingCapacity: true)
    }
}

struct StandingLegPose {
    let hip: CGPoint
    let knee: CGPoint
    let ankle: CGPoint
}

struct StandingBodyPoseSample {
    let shoulderY: CGFloat
    let hips: [CGPoint]
    let knees: [CGPoint]
    let ankles: [CGPoint]
    let legs: [StandingLegPose]

    init(
        shoulderY: CGFloat,
        hips: [CGPoint] = [],
        knees: [CGPoint] = [],
        ankles: [CGPoint] = [],
        legs: [StandingLegPose] = []
    ) {
        self.shoulderY = shoulderY
        self.hips = hips
        self.knees = knees
        self.ankles = ankles
        self.legs = legs
    }

    var visibleLowerBodyJointCount: Int {
        hips.count + knees.count + ankles.count
    }
}

struct StandingBodyPose3DSample {
    let leftKneeAngle: CGFloat?
    let rightKneeAngle: CGFloat?
    let hasVisibleLowerBody: Bool

    init(
        leftKneeAngle: CGFloat?,
        rightKneeAngle: CGFloat?,
        hasVisibleLowerBody: Bool = false
    ) {
        self.leftKneeAngle = leftKneeAngle
        self.rightKneeAngle = rightKneeAngle
        self.hasVisibleLowerBody = hasVisibleLowerBody
    }

    var kneeAngles: [CGFloat] {
        [leftKneeAngle, rightKneeAngle].compactMap { $0 }
    }
}

struct StandingBodyPose3DStabilizer {
    var windowSize = 5

    private var samples: [StandingBodyPose3DSample] = []

    mutating func ingest(
        _ sample: StandingBodyPose3DSample?
    ) -> StandingBodyPose3DSample? {
        guard let sample else { return nil }
        samples.append(sample)
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }

        return StandingBodyPose3DSample(
            leftKneeAngle: median(
                samples.compactMap(\.leftKneeAngle)
            ),
            rightKneeAngle: median(
                samples.compactMap(\.rightKneeAngle)
            ),
            hasVisibleLowerBody:
                samples.filter(\.hasVisibleLowerBody).count
                > samples.count / 2
        )
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    private func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

struct StandingRegionSample {
    let centerY: CGFloat
    let height: CGFloat
}

struct StandingFrameSample {
    let face: StandingRegionSample?
    let upperBody: StandingRegionSample?
    let body: StandingBodyPoseSample?
    let body3D: StandingBodyPose3DSample?

    init(
        face: StandingRegionSample?,
        upperBody: StandingRegionSample?,
        body: StandingBodyPoseSample?,
        body3D: StandingBodyPose3DSample? = nil
    ) {
        self.face = face
        self.upperBody = upperBody
        self.body = body
        self.body3D = body3D
    }
}

enum StandingDetectionPreset: Equatable {
    case nearHead
    case farSkeleton
}

struct StandingDetectionProgress: Equatable {
    let preset: StandingDetectionPreset
    let observation: StandingPoseObservation
    let confirmedDuration: TimeInterval
    let requiredDuration: TimeInterval
}

struct StandingPoseClassifier {
    var moderateRise: CGFloat = 0.025
    var strongRise: CGFloat = 0.045
    var distantFaceScale: CGFloat = 0.84
    var strongDistanceScale: CGFloat = 0.72
    var retreatedFaceScale: CGFloat = 0.96
    var expandedUpperBodyScale: CGFloat = 1.015
    var minimumTorsoReveal: CGFloat = 0.012
    var minimumShoulderShift: CGFloat = 0.008
    var nearFaceHeightThreshold: CGFloat = 0.15
    var referenceSmoothing: CGFloat = 0.18
    var minimumLegSpan: CGFloat = 0.18
    var minimumStraightKneeAngle: CGFloat = 150
    var minimum3DKneeAngle: CGFloat = 125
    var minimum3DAverageKneeAngle: CGFloat = 132
    var maximum3DSeatedAverageKneeAngle: CGFloat = 112
    var maximum3DKneeDifference: CGFloat = 32
    var minimumNearTorsoExpansion: CGFloat = 1.12
    var minimumCompactFaceDisplacement: CGFloat = 0.05
    var minimumCompactIndependentDisplacement: CGFloat = 0.10
    var minimumCompactTorsoScale: CGFloat = 1.10
    var maximumCompactTorsoScale: CGFloat = 0.78
    var minimumCompactShoulderDisplacement: CGFloat = 0.06
    var minimumFaceAboveShoulder: CGFloat = 0.01
    var torsoBoundsTolerance: CGFloat = 0.05
    var minimumStableFaceScale: CGFloat = 0.78
    var maximumStableFaceScale: CGFloat = 1.28
    var maximumStableFaceDisplacement: CGFloat = 0.08
    var minimumStrongCroppedTorsoScale: CGFloat = 1.32
    var maximumStrongCroppedTorsoScale: CGFloat = 0.65
    var minimumStrongCroppedFaceScale: CGFloat = 1.45
    var maximumStrongCroppedFaceScale: CGFloat = 0.70
    var minimumTemporalFaceRise: CGFloat = 0.10
    var minimumTemporalShoulderRise: CGFloat = 0.12
    var maximumAllowedFaceDrop: CGFloat = 0.04
    var frameEdgeThreshold: CGFloat = 0.94
    var minimumEdgeCroppedTorsoScale: CGFloat = 1.16
    var minimumEdgeCroppedTorsoRise: CGFloat = 0.08
    var minimumEdgeCroppedShoulderRise: CGFloat = 0.08
    var minimumStrongEdgeCroppedTorsoScale: CGFloat = 1.25
    var minimumStrongEdgeCroppedTorsoRise: CGFloat = 0.12
    var croppedTorsoWindowSize = 5
    var croppedTorsoVoteThreshold = 3
    var minimumCompactTorsoDisplacement: CGFloat = 0.025
    var minimumCompactLowerEdgeReveal: CGFloat = 0.06

    private var croppedTorsoCandidates: [Bool] = []
    private(set) var activePreset: StandingDetectionPreset?
    private(set) var baselineFaceY: CGFloat?
    private(set) var baselineFaceHeight: CGFloat?
    private(set) var baselineShoulderY: CGFloat?
    private(set) var baselineUpperBodyY: CGFloat?
    private(set) var baselineUpperBodyHeight: CGFloat?

    mutating func observeSeatedReference(
        _ sample: StandingFrameSample
    ) {
        if let face = sample.face {
            baselineFaceY = smoothedReference(
                baselineFaceY,
                newValue: face.centerY
            )
            baselineFaceHeight = smoothedReference(
                baselineFaceHeight,
                newValue: face.height
            )
        }
        if let upperBody = sample.upperBody {
            baselineUpperBodyY = smoothedReference(
                baselineUpperBodyY,
                newValue: upperBody.centerY
            )
            baselineUpperBodyHeight = smoothedReference(
                baselineUpperBodyHeight,
                newValue: upperBody.height
            )
        }
        if let shoulderY = sample.body?.shoulderY {
            baselineShoulderY = smoothedReference(
                baselineShoulderY,
                newValue: shoulderY
            )
        }

        if let baselineFaceHeight {
            activePreset = baselineFaceHeight
                >= nearFaceHeightThreshold
                ? .nearHead
                : .farSkeleton
        } else if sample.body != nil {
            activePreset = .farSkeleton
        }
    }

    mutating func classify(
        _ sample: StandingFrameSample
    ) -> StandingPoseObservation {
        let skeleton3DObservation = classifySkeleton3D(sample.body3D)
        let stableCroppedTorsoConfirmed =
            ingestStableCroppedTorsoCandidate(
                hasStableCroppedTorsoStandingPattern(sample)
            )
        if skeleton3DObservation == .standing {
            return .standing
        }
        if skeleton3DObservation == .notStanding {
            return .notStanding
        }
        if stableCroppedTorsoConfirmed {
            return .standing
        }
        if hasCompactSpaceStandingPattern(
            face: sample.face,
            upperBody: sample.upperBody,
            body: sample.body
        ) {
            return .standing
        }
        let preset =
            activePreset
            ?? inferredPreset(from: sample)
        let verifiedUpperBody: StandingRegionSample?
        if let upperBody = sample.upperBody {
            if let face = sample.face,
               upperBody.height < face.height * 1.45 {
                verifiedUpperBody = nil
            } else {
                verifiedUpperBody = upperBody
            }
        } else {
            verifiedUpperBody = nil
        }
        let torsoSupportsStanding = hasCorroboratingTorsoChange(
            upperBody: verifiedUpperBody,
            body: sample.body
        )
        let hasReliableTorsoEvidence =
            hasReliableTorsoStandingEvidence(
                sample.body,
                face: sample.face,
                upperBody: verifiedUpperBody
            )
        if hasRetreatedStandingPattern(
            face: sample.face,
            upperBody: verifiedUpperBody,
            body: sample.body
        ) {
            return .standing
        }
        switch preset {
        case .nearHead:
            let headObservation = classifyHead(sample.face)
            let upperBodyObservation = classifyUpperBody(
                verifiedUpperBody,
                faceIsVisible: sample.face != nil
            )
            if upperBodyObservation == .standing,
               hasReliableTorsoEvidence,
               sample.face == nil
                || headObservation == .standing {
                return .standing
            }
            if headObservation == .standing,
               hasReliableTorsoEvidence,
               verifiedUpperBody != nil,
                hasStrongDistanceEvidence(sample.face)
                || hasNearTorsoExpansion(
                    upperBody: verifiedUpperBody,
                    body: sample.body,
                    face: sample.face
                ) {
                return .standing
            }
            let skeletonObservation = classifySkeleton(sample.body)
            if skeletonObservation == .standing {
                return .standing
            }
            if headObservation == .standing,
               hasReliableTorsoEvidence,
               torsoSupportsStanding {
                return .standing
            }
            if sample.body3D != nil,
               skeleton3DObservation == .unavailable {
                return .unavailable
            }
            return combinedNonStandingResult(
                headObservation,
                upperBodyObservation,
                skeletonObservation,
                skeleton3DObservation
            )
        case .farSkeleton:
            let skeletonObservation = classifySkeleton(sample.body)
            if skeletonObservation == .standing {
                return .standing
            }
            let headObservation = classifyHead(sample.face)
            let upperBodyObservation = classifyUpperBody(
                verifiedUpperBody,
                faceIsVisible: sample.face != nil
            )
            if upperBodyObservation == .standing,
               hasReliableTorsoEvidence,
               sample.face == nil
                || headObservation == .standing {
                return .standing
            }
            if headObservation == .standing,
               hasReliableTorsoEvidence,
               torsoSupportsStanding {
                return .standing
            }
            if sample.body3D != nil,
               skeleton3DObservation == .unavailable {
                return .unavailable
            }
            return combinedNonStandingResult(
                skeletonObservation,
                headObservation,
                upperBodyObservation,
                skeleton3DObservation
            )
        }
    }

    private func hasCorroboratingTorsoChange(
        upperBody: StandingRegionSample?,
        body: StandingBodyPoseSample?
    ) -> Bool {
        if let upperBody,
           let baselineUpperBodyY,
           upperBody.centerY - baselineUpperBodyY >= moderateRise {
            return true
        }
        if let upperBody,
           let baselineUpperBodyHeight,
           baselineUpperBodyHeight > 0,
           upperBody.height / baselineUpperBodyHeight
                <= distantFaceScale {
            return true
        }
        if let body,
           let baselineShoulderY,
           body.shoulderY - baselineShoulderY >= moderateRise {
            return true
        }
        return false
    }

    private func hasStrongDistanceEvidence(
        _ face: StandingRegionSample?
    ) -> Bool {
        guard let face,
              let baselineFaceHeight,
              baselineFaceHeight > 0 else {
            return false
        }
        return face.height / baselineFaceHeight
            <= strongDistanceScale
    }

    private func hasNearTorsoExpansion(
        upperBody: StandingRegionSample?,
        body: StandingBodyPoseSample?,
        face: StandingRegionSample?
    ) -> Bool {
        guard let upperBody,
              let baselineUpperBodyHeight,
              baselineUpperBodyHeight > 0,
              upperBody.height / baselineUpperBodyHeight
                >= minimumNearTorsoExpansion else {
            return false
        }
        return hasReliableTorsoStandingEvidence(
            body,
            face: face,
            upperBody: upperBody
        )
    }

    private func hasCompactSpaceStandingPattern(
        face: StandingRegionSample?,
        upperBody: StandingRegionSample?,
        body: StandingBodyPoseSample?
    ) -> Bool {
        guard let upperBody,
              let baselineUpperBodyY,
              let baselineUpperBodyHeight,
              baselineUpperBodyHeight > 0 else {
            return false
        }

        let upperBodyScale =
            upperBody.height / baselineUpperBodyHeight
        let torsoDisplacement =
            abs(upperBody.centerY - baselineUpperBodyY)
        let baselineLowerEdge =
            baselineUpperBodyY - baselineUpperBodyHeight / 2
        let currentLowerEdge =
            upperBody.centerY - upperBody.height / 2
        let lowerEdgeReveal =
            baselineLowerEdge - currentLowerEdge

        let torsoScaleChanged =
            upperBodyScale >= minimumCompactTorsoScale
            || upperBodyScale <= maximumCompactTorsoScale
        let hasConfirmedTorsoSkeleton =
            hasReliableTorsoStandingEvidence(
                body,
                face: face,
                upperBody: upperBody
            )
        if torsoScaleChanged,
           hasConfirmedTorsoSkeleton {
            return true
        }

        guard let face,
              let baselineFaceY else {
            return false
        }
        let faceDisplacement = abs(face.centerY - baselineFaceY)

        if faceDisplacement
            >= minimumCompactIndependentDisplacement,
           hasConfirmedTorsoSkeleton {
            return true
        }

        return hasConfirmedTorsoSkeleton
            && faceDisplacement >= minimumCompactFaceDisplacement
            && upperBodyScale >= minimumCompactTorsoScale
            && (
                torsoDisplacement >= minimumCompactTorsoDisplacement
                || lowerEdgeReveal >= minimumCompactLowerEdgeReveal
            )
    }

    private func hasRetreatedStandingPattern(
        face: StandingRegionSample?,
        upperBody: StandingRegionSample?,
        body: StandingBodyPoseSample?
    ) -> Bool {
        guard let face,
              let upperBody,
              let body,
              body.hips.count >= 2,
              let baselineFaceY,
              let baselineFaceHeight,
              baselineFaceHeight > 0,
              let baselineUpperBodyY,
              let baselineUpperBodyHeight,
              baselineUpperBodyHeight > 0,
              hasReliableTorsoStandingEvidence(
                body,
                face: face,
                upperBody: upperBody
              ) else {
            return false
        }

        let faceScale = face.height / baselineFaceHeight
        let faceDisplacement = abs(face.centerY - baselineFaceY)
        let upperBodyScale =
            upperBody.height / baselineUpperBodyHeight
        let baselineLowerEdge =
            baselineUpperBodyY - baselineUpperBodyHeight / 2
        let currentLowerEdge =
            upperBody.centerY - upperBody.height / 2
        let revealsMoreTorso =
            upperBodyScale >= expandedUpperBodyScale
            || baselineLowerEdge - currentLowerEdge
                >= minimumTorsoReveal
        return faceScale <= retreatedFaceScale
            && faceDisplacement >= moderateRise
            && revealsMoreTorso
    }

    private func hasReliableTorsoStandingEvidence(
        _ body: StandingBodyPoseSample?,
        face: StandingRegionSample?,
        upperBody: StandingRegionSample?
    ) -> Bool {
        guard let body,
              body.hips.count >= 2,
              let baselineShoulderY,
              let face,
              face.centerY - body.shoulderY
                >= minimumFaceAboveShoulder else {
            return false
        }
        if let upperBody {
            let minimumY =
                upperBody.centerY - upperBody.height / 2
                    - torsoBoundsTolerance
            let maximumY =
                upperBody.centerY + upperBody.height / 2
                    + torsoBoundsTolerance
            guard (minimumY...maximumY).contains(body.shoulderY) else {
                return false
            }
        }
        return abs(body.shoulderY - baselineShoulderY)
            >= minimumCompactShoulderDisplacement
    }

    private func hasStableCroppedTorsoStandingPattern(
        _ sample: StandingFrameSample
    ) -> Bool {
        guard let upperBody = sample.upperBody,
              let baselineUpperBodyHeight,
              baselineUpperBodyHeight > 0 else {
            return false
        }

        let torsoScale =
            upperBody.height / baselineUpperBodyHeight
        let torsoChanged =
            torsoScale >= minimumStrongCroppedTorsoScale
            || torsoScale <= maximumStrongCroppedTorsoScale
        let currentTopEdge =
            upperBody.centerY + upperBody.height / 2
        let baselineTopEdge =
            baselineUpperBodyY.map {
                $0 + baselineUpperBodyHeight / 2
            }
        let topEdgeRise = baselineTopEdge.map {
            currentTopEdge - $0
        } ?? 0
        let foregroundHeadIsCropped: Bool
        if let face = sample.face {
            let faceTouchesTopEdge =
                face.centerY + face.height / 2
                >= frameEdgeThreshold
            let faceIsTooSmallForTheForegroundPerson =
                baselineFaceHeight.map {
                    $0 > 0
                    && face.height / $0
                        <= maximumStrongCroppedFaceScale
                } ?? false
            foregroundHeadIsCropped =
                faceTouchesTopEdge
                || faceIsTooSmallForTheForegroundPerson
        } else {
            foregroundHeadIsCropped = true
        }
        let isHeadCropped =
            currentTopEdge >= frameEdgeThreshold
            && foregroundHeadIsCropped
        let faceEvidence: Bool
        if let face = sample.face,
           let baselineFaceY,
           let baselineFaceHeight,
           baselineFaceHeight > 0 {
            let faceScale = face.height / baselineFaceHeight
            let faceRise = face.centerY - baselineFaceY
            guard faceRise >= -maximumAllowedFaceDrop else {
                return false
            }
            let faceIsStable =
                faceScale >= minimumStableFaceScale
                && faceScale <= maximumStableFaceScale
                && abs(faceRise) <= maximumStableFaceDisplacement
            let faceChangedStrongly =
                faceScale >= minimumStrongCroppedFaceScale
                || faceScale <= maximumStrongCroppedFaceScale
                || faceRise >= minimumTemporalFaceRise
            faceEvidence = faceIsStable || faceChangedStrongly
        } else {
            faceEvidence = false
        }
        let shoulderRose: Bool
        if let body = sample.body,
           let baselineShoulderY {
            shoulderRose =
                body.shoulderY - baselineShoulderY
                    >= minimumTemporalShoulderRise
        } else {
            shoulderRose = false
        }
        let hipsAppeared = sample.body?.hips.count ?? 0 >= 2
        let edgeCroppedTorsoChanged =
            torsoScale >= minimumEdgeCroppedTorsoScale
            && topEdgeRise >= minimumEdgeCroppedTorsoRise
        let strongEdgeCroppedTorsoChanged =
            torsoScale >= minimumStrongEdgeCroppedTorsoScale
            && topEdgeRise >= minimumStrongEdgeCroppedTorsoRise
        let edgeCroppedShoulderEvidence =
            shoulderRose
            || (
                sample.body.map {
                    guard let baselineShoulderY else { return false }
                    return $0.shoulderY - baselineShoulderY
                        >= minimumEdgeCroppedShoulderRise
                } ?? false
            )

        // Vision's face boxes, human rectangles, and pose joints each have
        // independent jitter. Compare every signal with its own seated
        // reference rather than requiring their absolute Y values to line up.
        // When the person stands close to a low or narrow camera, the head can
        // leave the frame before Vision can return a face or a complete pose.
        // In that case, a torso that consistently reaches the top edge and has
        // moved substantially from its seated reference is still valid
        // standing evidence. Shoulder movement corroborates weaker torso
        // changes, but a strong torso change can work on side/back views where
        // body-pose joints disappear.
        // Temporal voting below prevents a single bad detector frame from
        // starting the standing timer.
        return (torsoChanged && (faceEvidence || shoulderRose))
            || (shoulderRose && hipsAppeared)
            || (
                isHeadCropped
                && edgeCroppedTorsoChanged
                && (
                    edgeCroppedShoulderEvidence
                    || strongEdgeCroppedTorsoChanged
                )
            )
    }

    private mutating func ingestStableCroppedTorsoCandidate(
        _ candidate: Bool
    ) -> Bool {
        croppedTorsoCandidates.append(candidate)
        if croppedTorsoCandidates.count > croppedTorsoWindowSize {
            croppedTorsoCandidates.removeFirst(
                croppedTorsoCandidates.count - croppedTorsoWindowSize
            )
        }
        return croppedTorsoCandidates.count
                >= croppedTorsoVoteThreshold
            && croppedTorsoCandidates.filter { $0 }.count
                >= croppedTorsoVoteThreshold
    }

    func detectionPreset(
        for sample: StandingFrameSample
    ) -> StandingDetectionPreset {
        activePreset ?? inferredPreset(from: sample)
    }

    mutating func reset() {
        resetDetectionEvidence()
        activePreset = nil
        baselineFaceY = nil
        baselineFaceHeight = nil
        baselineShoulderY = nil
        baselineUpperBodyY = nil
        baselineUpperBodyHeight = nil
    }

    mutating func resetDetectionEvidence() {
        croppedTorsoCandidates.removeAll(keepingCapacity: true)
    }

    private func inferredPreset(
        from sample: StandingFrameSample
    ) -> StandingDetectionPreset {
        if let face = sample.face,
           face.height >= nearFaceHeightThreshold {
            return .nearHead
        }
        return .farSkeleton
    }

    private func classifyHead(
        _ face: StandingRegionSample?
    ) -> StandingPoseObservation {
        guard let face else { return .unavailable }

        var evidence = 0
        var hasReference = false
        var rise: CGFloat = 0
        if let baselineFaceY {
            rise = face.centerY - baselineFaceY
            evidence += riseEvidence(rise)
            hasReference = true
        }
        if let baselineFaceHeight,
           baselineFaceHeight > 0 {
            let scale = face.height / baselineFaceHeight
            if scale <= strongDistanceScale {
                evidence += 2
            } else if scale <= distantFaceScale,
                      rise >= moderateRise * 0.40 {
                evidence += 1
            }
            hasReference = true
        }
        guard hasReference else { return .unavailable }
        return evidence >= 2 ? .standing : .notStanding
    }

    private func classifyUpperBody(
        _ upperBody: StandingRegionSample?,
        faceIsVisible: Bool
    ) -> StandingPoseObservation {
        guard let upperBody else { return .unavailable }

        if let baselineUpperBodyY,
           upperBody.centerY - baselineUpperBodyY >= strongRise {
            return .standing
        }

        if !faceIsVisible,
           let baselineFaceHeight,
           baselineFaceHeight >= nearFaceHeightThreshold,
           let baselineUpperBodyY,
           let baselineUpperBodyHeight,
           upperBody.centerY + upperBody.height / 2 >= 0.94,
           upperBody.centerY + upperBody.height / 2
                - (baselineUpperBodyY + baselineUpperBodyHeight / 2)
                >= moderateRise * 0.40 {
            return .standing
        }

        guard baselineUpperBodyY != nil
                || baselineUpperBodyHeight != nil else {
            return .unavailable
        }
        return .notStanding
    }

    private func classifySkeleton(
        _ body: StandingBodyPoseSample?
    ) -> StandingPoseObservation {
        guard let body else { return .unavailable }

        let hasStraightLeg = body.legs.contains {
            isClearlyStraight($0)
        }
        let hasPartialExtension =
            body.legs.isEmpty
            && hasClearlyExtendedPartialSkeleton(body)
        let shoulderRise = baselineShoulderY.map {
            body.shoulderY - $0
        }

        if hasStraightLeg {
            guard let shoulderRise else {
                return .standing
            }
            return shoulderRise >= moderateRise
                ? .standing
                : .notStanding
        }
        if hasPartialExtension,
           let shoulderRise,
           shoulderRise >= strongRise {
            return .standing
        }
        return !body.legs.isEmpty
                || body.visibleLowerBodyJointCount >= 4
            ? .notStanding
            : .unavailable
    }

    private func classifySkeleton3D(
        _ body: StandingBodyPose3DSample?
    ) -> StandingPoseObservation {
        guard let body else { return .unavailable }
        guard body.hasVisibleLowerBody else {
            return .unavailable
        }
        let kneeAngles = body.kneeAngles
        guard kneeAngles.count == 2 else { return .unavailable }
        let average =
            kneeAngles.reduce(0, +) / CGFloat(kneeAngles.count)
        let difference = abs(kneeAngles[0] - kneeAngles[1])
        if kneeAngles.allSatisfy({
            $0 >= minimum3DKneeAngle
        }),
           average >= minimum3DAverageKneeAngle,
           difference <= maximum3DKneeDifference {
            return .standing
        }
        if average <= maximum3DSeatedAverageKneeAngle {
            return .notStanding
        }
        return .unavailable
    }

    private func combinedNonStandingResult(
        _ observations: StandingPoseObservation...
    ) -> StandingPoseObservation {
        observations.contains(.notStanding)
            ? .notStanding
            : .unavailable
    }

    private func riseEvidence(_ rise: CGFloat) -> Int {
        if rise >= strongRise {
            return 2
        }
        if rise >= moderateRise {
            return 1
        }
        return 0
    }

    private func smoothedReference(
        _ current: CGFloat?,
        newValue: CGFloat
    ) -> CGFloat {
        guard let current else { return newValue }
        return current
            + (newValue - current) * referenceSmoothing
    }

    private func isClearlyStraight(_ leg: StandingLegPose) -> Bool {
        guard leg.hip.y > leg.knee.y,
              leg.knee.y > leg.ankle.y,
              leg.hip.y - leg.ankle.y >= minimumLegSpan else {
            return false
        }
        return kneeAngle(for: leg) >= minimumStraightKneeAngle
    }

    private func hasClearlyExtendedPartialSkeleton(
        _ body: StandingBodyPoseSample
    ) -> Bool {
        guard let hipY = averageY(body.hips),
              let kneeY = averageY(body.knees),
              hipY - kneeY >= minimumLegSpan * 0.48 else {
            return false
        }

        if let ankleY = averageY(body.ankles) {
            return kneeY > ankleY
                && hipY - ankleY >= minimumLegSpan
                && body.shoulderY - ankleY >= minimumLegSpan * 1.65
        }

        return body.hips.count + body.knees.count >= 4
            && body.shoulderY - kneeY >= minimumLegSpan * 1.35
    }

    private func averageY(_ points: [CGPoint]) -> CGFloat? {
        guard !points.isEmpty else { return nil }
        return points.map(\.y).reduce(0, +) / CGFloat(points.count)
    }

    private func kneeAngle(for leg: StandingLegPose) -> CGFloat {
        let upper = CGPoint(
            x: leg.hip.x - leg.knee.x,
            y: leg.hip.y - leg.knee.y
        )
        let lower = CGPoint(
            x: leg.ankle.x - leg.knee.x,
            y: leg.ankle.y - leg.knee.y
        )
        let upperLength = hypot(upper.x, upper.y)
        let lowerLength = hypot(lower.x, lower.y)
        guard upperLength > 0, lowerLength > 0 else { return 0 }
        let cosine = max(
            -1,
            min(
                1,
                (upper.x * lower.x + upper.y * lower.y)
                    / (upperLength * lowerLength)
            )
        )
        return acos(cosine) * 180 / .pi
    }
}

struct StandingGestureDetector {
    var requiredDuration: TimeInterval = 10
    var requiredStandingFrames = 3
    var maximumFrameGap: TimeInterval = 2.25
    var maximumPreservedGap: TimeInterval = 12
    var resetAfterNotStandingDuration: TimeInterval = 3
    var resetAfterUnavailableDuration: TimeInterval = 8

    private var accumulatedStandingDuration: TimeInterval = 0
    private var lastSampleAt: TimeInterval?
    private var previousObservation: StandingPoseObservation?
    private var notStandingStartedAt: TimeInterval?
    private var unavailableStartedAt: TimeInterval?
    private var standingFrames = 0
    private(set) var isConfirmed = false

    mutating func ingest(
        _ observation: StandingPoseObservation,
        at time: TimeInterval
    ) -> Bool {
        guard !isConfirmed else { return false }

        if let lastSampleAt,
           time - lastSampleAt > maximumPreservedGap {
            resetProgress()
        }

        switch observation {
        case .standing:
            if let lastSampleAt,
               previousObservation == .standing {
                let interval = time - lastSampleAt
                if interval > 0,
                   interval <= maximumFrameGap {
                    accumulatedStandingDuration += interval
                }
            }
            lastSampleAt = time
            previousObservation = .standing
            notStandingStartedAt = nil
            unavailableStartedAt = nil
            standingFrames += 1
            guard standingFrames >= requiredStandingFrames,
                  accumulatedStandingDuration >= requiredDuration else {
                return false
            }
            isConfirmed = true
            return true
        case .notStanding:
            if notStandingStartedAt == nil {
                notStandingStartedAt = time
            }
            lastSampleAt = time
            previousObservation = .notStanding
            unavailableStartedAt = nil
            if let notStandingStartedAt,
               time - notStandingStartedAt
                    >= resetAfterNotStandingDuration {
                resetProgress()
            }
            return false
        case .unavailable:
            if unavailableStartedAt == nil {
                unavailableStartedAt = time
            }
            lastSampleAt = time
            previousObservation = .unavailable
            notStandingStartedAt = nil
            if let unavailableStartedAt,
               time - unavailableStartedAt
                    >= resetAfterUnavailableDuration {
                resetProgress()
            }
            return false
        }
    }

    mutating func reset() {
        resetProgress()
        isConfirmed = false
    }

    func confirmedDuration(at _: TimeInterval) -> TimeInterval {
        min(requiredDuration, accumulatedStandingDuration)
    }

    private mutating func resetProgress() {
        accumulatedStandingDuration = 0
        lastSampleAt = nil
        previousObservation = nil
        notStandingStartedAt = nil
        unavailableStartedAt = nil
        standingFrames = 0
    }
}

final class SittingTracker {
    enum Event {
        case reminder
    }

    var reminderInterval: TimeInterval {
        didSet {
            if isPresent {
                nextReminderAt = Date().addingTimeInterval(reminderInterval)
            }
        }
    }

    var absenceGracePeriod: TimeInterval = 20

    private(set) var isPresent = false
    private var sessionStartedAt: Date?
    private var absenceStartedAt: Date?
    private var nextReminderAt: Date?

    init(reminderInterval: TimeInterval) {
        self.reminderInterval = reminderInterval
    }

    func updatePresence(_ present: Bool, now: Date = Date()) {
        isPresent = present

        if present {
            absenceStartedAt = nil
            if sessionStartedAt == nil {
                sessionStartedAt = now
                nextReminderAt = now.addingTimeInterval(reminderInterval)
            }
        } else if sessionStartedAt != nil, absenceStartedAt == nil {
            absenceStartedAt = now
        }
    }

    func tick(now: Date = Date()) -> Event? {
        if !isPresent,
           let absenceStartedAt,
           now.timeIntervalSince(absenceStartedAt) >= absenceGracePeriod {
            reset()
            return nil
        }

        guard isPresent, let nextReminderAt, now >= nextReminderAt else {
            return nil
        }

        self.nextReminderAt = now.addingTimeInterval(reminderInterval)
        return .reminder
    }

    func reset() {
        isPresent = false
        sessionStartedAt = nil
        absenceStartedAt = nil
        nextReminderAt = nil
    }

    func restartSession(now: Date = Date()) {
        let wasPresent = isPresent
        reset()
        if wasPresent {
            updatePresence(true, now: now)
        }
    }

    func elapsed(now: Date = Date()) -> TimeInterval {
        guard let sessionStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(sessionStartedAt))
    }

    func timeUntilNextReminder(now: Date = Date()) -> TimeInterval? {
        guard isPresent, let nextReminderAt else { return nil }
        return max(0, nextReminderAt.timeIntervalSince(now))
    }
}
