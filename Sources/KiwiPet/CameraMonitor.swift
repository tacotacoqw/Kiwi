@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Vision

final class CameraMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Status: Equatable {
        case stopped
        case permissionRequired
        case requestingPermission
        case starting
        case running
        case denied
        case unavailable(String)
    }

    var onPresenceChanged: ((Bool) -> Void)?
    var onStatusChanged: ((Status) -> Void)?
    var onDrinkDetected: (() -> Void)?
    var onStandingConfirmed: (() -> Void)?
    var onStandingProgress: ((StandingDetectionProgress) -> Void)?

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.kiwipet.camera.session")
    private let videoQueue = DispatchQueue(label: "com.kiwipet.camera.video")
    private var configured = false
    private var requestedRunning = false
    private var lastAnalysisTime: TimeInterval = 0
    private var presenceSmoother = PresenceSmoother()
    private var drinkDetectionEnabled = false
    private var drinkingGestureDetector = DrinkingGestureDetector()
    private var standingDetectionEnabled = false
    private var standingPoseClassifier = StandingPoseClassifier()
    private var standingBody3DStabilizer =
        StandingBodyPose3DStabilizer()
    private var standingObservationSmoother = StandingObservationSmoother()
    private var standingGestureDetector = StandingGestureDetector()
    private var standingDiagnosticsFile: FileHandle?
    private let standingDiagnosticsURL = URL(
        fileURLWithPath: "/private/tmp/kiwi-standing-diagnostics.log"
    )

    func start(requestPermissionIfNeeded: Bool = false) {
        sessionQueue.async { [weak self] in
            self?.requestedRunning = true
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            guard requestPermissionIfNeeded else {
                publishStatus(.permissionRequired)
                return
            }
            publishStatus(.requestingPermission)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
                    self.publishStatus(.denied)
                }
            }
        case .denied, .restricted:
            publishStatus(.denied)
        @unknown default:
            publishStatus(.unavailable("未知的摄像头权限状态"))
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedRunning = false
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.videoQueue.async { [weak self] in
                guard let self else { return }
                self.lastAnalysisTime = 0
                self.drinkDetectionEnabled = false
                self.drinkingGestureDetector.reset()
                self.standingDetectionEnabled = false
                self.standingPoseClassifier.reset()
                self.standingBody3DStabilizer.reset()
                self.standingObservationSmoother.reset()
                self.standingGestureDetector.reset()
                self.stopStandingDiagnostics()
                if let presence = self.presenceSmoother.reset() {
                    self.publishPresence(presence)
                }
                self.publishStatus(.stopped)
            }
        }
    }

    func setStandingDetectionEnabled(_ enabled: Bool) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.standingDetectionEnabled = enabled
            self.standingBody3DStabilizer.reset()
            self.standingObservationSmoother.reset()
            self.standingGestureDetector.reset()
            if !enabled {
                self.standingPoseClassifier.reset()
                self.stopStandingDiagnostics()
            }
            if enabled {
                self.standingPoseClassifier.resetDetectionEvidence()
                self.startStandingDiagnostics()
                self.lastAnalysisTime = 0
            }
        }
    }

    func setDrinkDetectionEnabled(_ enabled: Bool) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.drinkDetectionEnabled = enabled
            self.drinkingGestureDetector.reset()
            if enabled {
                self.lastAnalysisTime = 0
            }
        }
    }

    private func configureAndStart() {
        publishStatus(.starting)
        sessionQueue.async { [weak self] in
            guard let self, self.requestedRunning else { return }

            do {
                if !self.configured {
                    try self.configureSession()
                }
                guard self.requestedRunning else { return }
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                self.publishStatus(.running)
            } catch {
                self.publishStatus(.unavailable(error.localizedDescription))
            }
        }
    }

    private func configureSession() throws {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)

        captureSession.beginConfiguration()
        captureSession.sessionPreset = captureSession.canSetSessionPreset(.high)
            ? .high
            : .medium
        defer { captureSession.commitConfiguration() }

        guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
            throw CameraError.cannotConfigure
        }

        captureSession.addInput(input)
        captureSession.addOutput(output)
        configured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let analysisInterval: TimeInterval =
            drinkDetectionEnabled || standingDetectionEnabled ? 0.5 : 1.0
        guard now - lastAnalysisTime >= analysisInterval else { return }
        lastAnalysisTime = now

        let faceRequest = VNDetectFaceLandmarksRequest()
        let upperBodyRequest = VNDetectHumanRectanglesRequest()
        upperBodyRequest.upperBodyOnly = true
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2
        let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
        let bodyPose3DRequest: VNRequest?
        if standingDetectionEnabled {
            if #available(macOS 14.0, *) {
                bodyPose3DRequest = VNDetectHumanBodyPose3DRequest()
            } else {
                bodyPose3DRequest = nil
            }
        } else {
            bodyPose3DRequest = nil
        }
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            var requests: [VNRequest] = [
                faceRequest,
                upperBodyRequest
            ]
            if drinkDetectionEnabled {
                requests.append(handRequest)
            }
            requests.append(bodyPoseRequest)
            if let bodyPose3DRequest {
                requests.append(bodyPose3DRequest)
            }
            try handler.perform(requests)
            let foundFace = !(faceRequest.results?.isEmpty ?? true)
            let foundUpperBody = !(upperBodyRequest.results?.isEmpty ?? true)
            let bestFace = faceRequest.results?
                .max {
                    $0.boundingBox.width * $0.boundingBox.height
                        < $1.boundingBox.width * $1.boundingBox.height
                }
            let bestUpperBody = upperBodyRequest.results?
                .max {
                    $0.boundingBox.width * $0.boundingBox.height
                        < $1.boundingBox.width * $1.boundingBox.height
                }
            let bodySample = Self.standingBodyPoseSample(
                observations: bodyPoseRequest.results ?? []
            )
            let rawBody3DSample: StandingBodyPose3DSample?
            if #available(macOS 14.0, *),
               let request =
                   bodyPose3DRequest
                   as? VNDetectHumanBodyPose3DRequest {
                rawBody3DSample = Self.standingBodyPose3DSample(
                    observations: request.results ?? [],
                    hasVisibleLowerBody:
                        bodySample.map {
                            $0.knees.count >= 2
                                && $0.ankles.count >= 1
                                && $0.visibleLowerBodyJointCount >= 5
                        } ?? false
                )
            } else {
                rawBody3DSample = nil
            }
            let body3DSample = standingBody3DStabilizer.ingest(
                rawBody3DSample
            )
            let standingSample = StandingFrameSample(
                face: bestFace.map {
                    StandingRegionSample(
                        centerY: $0.boundingBox.midY,
                        height: $0.boundingBox.height
                    )
                },
                upperBody: bestUpperBody.map {
                    StandingRegionSample(
                        centerY: $0.boundingBox.midY,
                        height: $0.boundingBox.height
                    )
                },
                body: bodySample,
                body3D: body3DSample
            )
            if !standingDetectionEnabled {
                standingPoseClassifier.observeSeatedReference(
                    standingSample
                )
            }
            updateSmoothedPresence(
                PersonPresenceEvidence.isVisible(
                    faceDetected: foundFace,
                    upperBodyDetected: foundUpperBody,
                    bodyPoseDetected: bodySample != nil
                )
            )
            if drinkDetectionEnabled {
                let handPosition = Self.detectDrinkHandPosition(
                    faces: faceRequest.results ?? [],
                    hands: handRequest.results ?? []
                )
                if drinkingGestureDetector.ingest(
                    handPosition,
                    at: now
                ) {
                    publishDrinkDetected()
                }
            }
            if standingDetectionEnabled {
                let rawObservation = standingPoseClassifier.classify(
                    standingSample
                )
                let observation = standingObservationSmoother.ingest(
                    rawObservation
                )
                let confirmed = standingGestureDetector.ingest(
                    observation,
                    at: now
                )
                logStandingDiagnostics(
                    sample: standingSample,
                    rawObservation: rawObservation,
                    smoothedObservation: observation,
                    at: now
                )
                publishStandingProgress(
                    StandingDetectionProgress(
                        preset: standingPoseClassifier.detectionPreset(
                            for: standingSample
                        ),
                        observation: observation,
                        confirmedDuration:
                            standingGestureDetector.confirmedDuration(
                                at: now
                            ),
                        requiredDuration:
                            standingGestureDetector.requiredDuration
                    )
                )
                if confirmed {
                    standingDetectionEnabled = false
                    stopStandingDiagnostics()
                    publishStandingConfirmed()
                }
            }
        } catch {
            updateSmoothedPresence(false)
            if drinkDetectionEnabled {
                _ = drinkingGestureDetector.ingest(
                    .unavailable,
                    at: now
                )
            }
            if standingDetectionEnabled {
                let observation = standingObservationSmoother.ingest(
                    .unavailable
                )
                _ = standingGestureDetector.ingest(
                    observation,
                    at: now
                )
                publishStandingProgress(
                    StandingDetectionProgress(
                        preset:
                            standingPoseClassifier.activePreset
                            ?? .farSkeleton,
                        observation: observation,
                        confirmedDuration:
                            standingGestureDetector.confirmedDuration(
                                at: now
                            ),
                        requiredDuration:
                            standingGestureDetector.requiredDuration
                    )
                )
            }
        }
    }

    private static func standingBodyPoseSample(
        observations: [VNHumanBodyPoseObservation]
    ) -> StandingBodyPoseSample? {
        guard let observation = observations.max(
            by: { $0.confidence < $1.confidence }
        ),
        let points = try? observation.recognizedPoints(.all) else {
            return nil
        }

        func point(
            _ name: VNHumanBodyPoseObservation.JointName
        ) -> CGPoint? {
            guard let point = points[name],
                  point.confidence >= 0.35 else {
                return nil
            }
            return point.location
        }

        let shoulders = [
            point(.leftShoulder),
            point(.rightShoulder)
        ].compactMap { $0 }
        guard !shoulders.isEmpty else { return nil }
        let shoulderY =
            shoulders.map(\.y).reduce(0, +)
                / CGFloat(shoulders.count)

        let hips = [
            point(.leftHip),
            point(.rightHip)
        ].compactMap { $0 }
        let knees = [
            point(.leftKnee),
            point(.rightKnee)
        ].compactMap { $0 }
        let ankles = [
            point(.leftAnkle),
            point(.rightAnkle)
        ].compactMap { $0 }

        var legs: [StandingLegPose] = []
        if let hip = point(.leftHip),
           let knee = point(.leftKnee),
           let ankle = point(.leftAnkle) {
            legs.append(
                StandingLegPose(hip: hip, knee: knee, ankle: ankle)
            )
        }
        if let hip = point(.rightHip),
           let knee = point(.rightKnee),
           let ankle = point(.rightAnkle) {
            legs.append(
                StandingLegPose(hip: hip, knee: knee, ankle: ankle)
            )
        }

        return StandingBodyPoseSample(
            shoulderY: shoulderY,
            hips: hips,
            knees: knees,
            ankles: ankles,
            legs: legs
        )
    }

    @available(macOS 14.0, *)
    private static func standingBodyPose3DSample(
        observations: [VNHumanBodyPose3DObservation],
        hasVisibleLowerBody: Bool
    ) -> StandingBodyPose3DSample? {
        guard let observation = observations.first else { return nil }

        func position(
            _ name: VNHumanBodyPose3DObservation.JointName
        ) -> SIMD3<Float>? {
            guard let point = try? observation.recognizedPoint(name) else {
                return nil
            }
            let translation = point.position.columns.3
            return SIMD3(
                translation.x,
                translation.y,
                translation.z
            )
        }

        func kneeAngle(
            hip: VNHumanBodyPose3DObservation.JointName,
            knee: VNHumanBodyPose3DObservation.JointName,
            ankle: VNHumanBodyPose3DObservation.JointName
        ) -> CGFloat? {
            guard let hipPosition = position(hip),
                  let kneePosition = position(knee),
                  let anklePosition = position(ankle) else {
                return nil
            }
            let upper = hipPosition - kneePosition
            let lower = anklePosition - kneePosition
            let upperLength = sqrt(
                upper.x * upper.x
                + upper.y * upper.y
                + upper.z * upper.z
            )
            let lowerLength = sqrt(
                lower.x * lower.x
                + lower.y * lower.y
                + lower.z * lower.z
            )
            guard upperLength > 0, lowerLength > 0 else { return nil }
            let cosine = max(
                -1,
                min(
                    1,
                    (upper.x * lower.x
                        + upper.y * lower.y
                        + upper.z * lower.z)
                        / (upperLength * lowerLength)
                )
            )
            return CGFloat(acos(cosine) * 180 / .pi)
        }

        return StandingBodyPose3DSample(
            leftKneeAngle: kneeAngle(
                hip: .leftHip,
                knee: .leftKnee,
                ankle: .leftAnkle
            ),
            rightKneeAngle: kneeAngle(
                hip: .rightHip,
                knee: .rightKnee,
                ankle: .rightAnkle
            ),
            hasVisibleLowerBody: hasVisibleLowerBody
        )
    }

    private func startStandingDiagnostics() {
        stopStandingDiagnostics()
        FileManager.default.createFile(
            atPath: standingDiagnosticsURL.path,
            contents: nil
        )
        standingDiagnosticsFile = try? FileHandle(
            forWritingTo: standingDiagnosticsURL
        )
    }

    private func stopStandingDiagnostics() {
        try? standingDiagnosticsFile?.close()
        standingDiagnosticsFile = nil
    }

    private func logStandingDiagnostics(
        sample: StandingFrameSample,
        rawObservation: StandingPoseObservation,
        smoothedObservation: StandingPoseObservation,
        at time: TimeInterval
    ) {
        guard let standingDiagnosticsFile else { return }

        let face = sample.face.map {
            String(
                format: "face=%.3f/%.3f",
                Double($0.centerY),
                Double($0.height)
            )
        } ?? "face=-"
        let upperBody = sample.upperBody.map {
            String(
                format: "upper=%.3f/%.3f",
                Double($0.centerY),
                Double($0.height)
            )
        } ?? "upper=-"
        let body = sample.body.map {
            String(
                format: "shoulder=%.3f joints=%d/%d/%d legs=%d",
                Double($0.shoulderY),
                $0.hips.count,
                $0.knees.count,
                $0.ankles.count,
                $0.legs.count
            )
        } ?? "shoulder=- joints=0/0/0 legs=0"
        let body3D: String
        if let sample3D = sample.body3D {
            let leftAngle = formattedCoordinate(sample3D.leftKneeAngle)
            let rightAngle = formattedCoordinate(sample3D.rightKneeAngle)
            let lowerBody = sample3D.hasVisibleLowerBody ? "1" : "0"
            body3D =
                "knees3D=\(leftAngle)/\(rightAngle) lower3D=\(lowerBody)"
        } else {
            body3D = "knees3D=-/- lower3D=0"
        }
        let baselines = String(
            format: "baseFace=%@/%@ baseUpper=%@/%@ baseShoulder=%@",
            formattedCoordinate(standingPoseClassifier.baselineFaceY),
            formattedCoordinate(standingPoseClassifier.baselineFaceHeight),
            formattedCoordinate(standingPoseClassifier.baselineUpperBodyY),
            formattedCoordinate(standingPoseClassifier.baselineUpperBodyHeight),
            formattedCoordinate(standingPoseClassifier.baselineShoulderY)
        )
        let progress = standingGestureDetector.confirmedDuration(at: time)
        let line = String(
            format: "%.3f %@ %@ %@ %@ %@ raw=%@ smooth=%@ progress=%.1f\n",
            time,
            face,
            upperBody,
            body,
            body3D,
            baselines,
            String(describing: rawObservation),
            String(describing: smoothedObservation),
            progress
        )
        if let data = line.data(using: .utf8) {
            try? standingDiagnosticsFile.write(contentsOf: data)
        }
    }

    private func formattedCoordinate(_ value: CGFloat?) -> String {
        value.map {
            String(format: "%.3f", Double($0))
        } ?? "-"
    }

    private static func detectDrinkHandPosition(
        faces: [VNFaceObservation],
        hands: [VNHumanHandPoseObservation]
    ) -> DrinkingGestureObservation {
        guard !faces.isEmpty else {
            return .unavailable
        }
        guard !hands.isEmpty else { return .noHand }

        let reliablePalmCenters = hands.compactMap(palmCenter)
        guard !reliablePalmCenters.isEmpty else { return .noHand }

        for face in faces {
            let mouth = mouthCenter(for: face)
            for palm in reliablePalmCenters
            where DrinkingGestureGeometry.isNearMouth(
                palm: palm,
                mouth: mouth,
                faceSize: face.boundingBox.size
            ) {
                return .nearMouth
            }
        }
        return .away
    }

    private static func palmCenter(
        for hand: VNHumanHandPoseObservation
    ) -> CGPoint? {
        let jointNames: [VNHumanHandPoseObservation.JointName] = [
            .wrist,
            .indexMCP,
            .middleMCP,
            .ringMCP,
            .littleMCP
        ]
        let points = jointNames.compactMap { jointName -> CGPoint? in
            guard let point = try? hand.recognizedPoint(jointName),
                  point.confidence >= 0.35 else {
                return nil
            }
            return point.location
        }
        guard points.count >= 2 else { return nil }

        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(
                x: partial.x + point.x,
                y: partial.y + point.y
            )
        }
        return CGPoint(
            x: sum.x / CGFloat(points.count),
            y: sum.y / CGFloat(points.count)
        )
    }

    private static func mouthCenter(for face: VNFaceObservation) -> CGPoint {
        if let lipPoints = face.landmarks?.outerLips?.normalizedPoints,
           !lipPoints.isEmpty {
            let sum = lipPoints.reduce(CGPoint.zero) { partial, point in
                CGPoint(
                    x: partial.x + point.x,
                    y: partial.y + point.y
                )
            }
            let localCenter = CGPoint(
                x: sum.x / CGFloat(lipPoints.count),
                y: sum.y / CGFloat(lipPoints.count)
            )
            return CGPoint(
                x: face.boundingBox.minX
                    + localCenter.x * face.boundingBox.width,
                y: face.boundingBox.minY
                    + localCenter.y * face.boundingBox.height
            )
        }

        return CGPoint(
            x: face.boundingBox.midX,
            y: face.boundingBox.minY + face.boundingBox.height * 0.28
        )
    }

    private func updateSmoothedPresence(_ found: Bool) {
        if let presence = presenceSmoother.ingest(found) {
            publishPresence(presence)
        }
    }

    private func publishPresence(_ present: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onPresenceChanged?(present)
        }
    }

    private func publishStatus(_ status: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(status)
        }
    }

    private func publishDrinkDetected() {
        DispatchQueue.main.async { [weak self] in
            self?.onDrinkDetected?()
        }
    }

    private func publishStandingConfirmed() {
        DispatchQueue.main.async { [weak self] in
            self?.onStandingConfirmed?()
        }
    }

    private func publishStandingProgress(
        _ progress: StandingDetectionProgress
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onStandingProgress?(progress)
        }
    }
}

enum DrinkingGestureGeometry {
    static func isNearMouth(
        palm: CGPoint,
        mouth: CGPoint,
        faceSize: CGSize
    ) -> Bool {
        guard faceSize.width > 0, faceSize.height > 0 else {
            return false
        }
        let normalizedX =
            (palm.x - mouth.x) / (faceSize.width * 1.05)
        let normalizedY =
            (palm.y - mouth.y) / (faceSize.height * 0.85)
        return normalizedX * normalizedX + normalizedY * normalizedY <= 1
    }
}

enum PersonPresenceEvidence {
    static func isVisible(
        faceDetected: Bool,
        upperBodyDetected: Bool,
        bodyPoseDetected: Bool
    ) -> Bool {
        faceDetected || upperBodyDetected || bodyPoseDetected
    }
}

struct PresenceSmoother {
    private(set) var isPresent = false
    private var positiveFrames = 0
    private var negativeFrames = 0

    mutating func ingest(_ found: Bool) -> Bool? {
        if found {
            positiveFrames += 1
            negativeFrames = 0
        } else {
            negativeFrames += 1
            positiveFrames = 0
        }

        if positiveFrames >= 2, !isPresent {
            isPresent = true
            return true
        }
        if negativeFrames >= 4, isPresent {
            isPresent = false
            return false
        }
        return nil
    }

    mutating func reset() -> Bool? {
        positiveFrames = 0
        negativeFrames = 0
        guard isPresent else { return nil }
        isPresent = false
        return false
    }
}

private enum CameraError: LocalizedError {
    case noCamera
    case cannotConfigure

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "没有找到可用的摄像头"
        case .cannotConfigure:
            return "无法配置摄像头输入"
        }
    }
}
