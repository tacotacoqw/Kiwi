import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import Vision

/// Watches only the Codex app window. At most one captured frame is kept in
/// memory. Each frame is recognized synchronously and released before the next
/// frame is processed; screenshots are never written to disk.
final class CodexTaskMonitor: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Status: Equatable {
        case stopped
        case permissionRequired
        case lookingForCodex
        case watching
        case timing(startedAt: Date)
        case unavailable(String)
    }

    struct Completion {
        let startedAt: Date
        let finishedAt: Date

        var duration: TimeInterval {
            max(0, finishedAt.timeIntervalSince(startedAt))
        }
    }

    var onStatusChanged: ((Status) -> Void)?
    var onTaskCompleted: ((Completion) -> Void)?

    private let captureQueue = DispatchQueue(
        label: "com.leo.kiwipet.codex-capture",
        qos: .utility
    )
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let sampleInterval: TimeInterval = 5

    private(set) var status: Status = .stopped
    private var requestedRunning = false
    private var refreshInProgress = false
    private var refreshTimer: Timer?
    private var stream: SCStream?
    private var capturedWindowID: CGWindowID?
    private var lastAnalysisAt: TimeInterval = 0
    private var frameAnalysisInProgress = false
    private var activityTracker = CodexTaskActivityTracker()

    func start() {
        guard !requestedRunning else { return }
        requestedRunning = true
        publishStatus(.lookingForCodex)

        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 15,
            repeats: true
        ) { [weak self] _ in
            self?.refreshCaptureTarget()
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }

        guard CGPreflightScreenCaptureAccess() else {
            publishStatus(.permissionRequired)
            // Never trigger a system prompt at launch. Exact local task
            // events work without screen access; OCR quietly joins as a
            // fallback only when permission already exists.
            return
        }
        refreshCaptureTarget()
    }

    func stop() {
        requestedRunning = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopCurrentStream()
        captureQueue.async { [weak self] in
            self?.activityTracker.reset()
        }
        publishStatus(.stopped)
    }

    private func refreshCaptureTarget() {
        guard requestedRunning, !refreshInProgress else { return }
        guard CGPreflightScreenCaptureAccess() else {
            publishStatus(.permissionRequired)
            return
        }

        refreshInProgress = true
        SCShareableContent.getExcludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        ) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInProgress = false
                guard self.requestedRunning else { return }

                if let error {
                    self.publishStatus(.unavailable(error.localizedDescription))
                    return
                }
                guard let window = content.flatMap(self.bestCodexWindow(in:)) else {
                    self.stopCurrentStream()
                    self.publishStatus(.lookingForCodex)
                    return
                }
                guard self.capturedWindowID != window.windowID || self.stream == nil else {
                    return
                }
                self.installStream(for: window)
            }
        }
    }

    private func bestCodexWindow(in content: SCShareableContent) -> SCWindow? {
        let candidates = content.windows
            .filter { window in
                guard window.windowLayer == 0,
                      window.frame.width >= 420,
                      window.frame.height >= 280,
                      let application = window.owningApplication else {
                    return false
                }
                let name = application.applicationName.lowercased()
                let bundleID = application.bundleIdentifier.lowercased()
                return name == "codex"
                    || name.hasPrefix("codex ")
                    || bundleID == "com.openai.codex"
                    || bundleID.hasSuffix(".codex")
            }
        let frontToBackIDs = (
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
        ).compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        let rank = Dictionary(
            uniqueKeysWithValues: frontToBackIDs.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        return candidates.min { lhs, rhs in
            let lhsRank = rank[lhs.windowID] ?? Int.max
            let rhsRank = rank[rhs.windowID] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            return lhsArea > rhsArea
        }
    }

    private func installStream(for window: SCWindow) {
        stopCurrentStream()

        let maximumWidth: CGFloat = 1_800
        let scale = min(2, maximumWidth / max(window.frame.width, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(840, Int(window.frame.width * scale))
        configuration.height = max(560, Int(window.frame.height * scale))
        configuration.minimumFrameInterval = CMTime(
            seconds: sampleInterval,
            preferredTimescale: 600
        )
        // Do not retain a backlog of screenshots. ScreenCaptureKit may drop a
        // frame while OCR is busy; the next interval will provide a fresh one.
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )

        do {
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: captureQueue
            )
        } catch {
            publishStatus(.unavailable(error.localizedDescription))
            return
        }

        self.stream = stream
        capturedWindowID = window.windowID
        lastAnalysisAt = 0
        captureQueue.async { [weak self] in
            self?.activityTracker.reset()
        }

        stream.startCapture { [weak self, weak stream] error in
            DispatchQueue.main.async {
                guard let self, self.requestedRunning, stream === self.stream else {
                    return
                }
                if let error {
                    self.publishStatus(.unavailable(error.localizedDescription))
                    self.stopCurrentStream()
                } else {
                    self.publishStatus(.watching)
                }
            }
        }
    }

    private func stopCurrentStream() {
        let oldStream = stream
        stream = nil
        capturedWindowID = nil
        oldStream?.stopCapture(completionHandler: nil)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              requestedRunning,
              stream === self.stream,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastAnalysisAt >= sampleInterval - 0.25 else { return }
        guard !frameAnalysisInProgress else { return }
        lastAnalysisAt = uptime
        frameAnalysisInProgress = true
        defer {
            frameAnalysisInProgress = false
        }

        // Vision performs synchronously. The autorelease pool makes the
        // captured image, request, and recognition observations eligible for
        // release as soon as this single-frame pass finishes.
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = imageContext.createCGImage(
                image,
                from: image.extent
            ) else {
                return
            }
            analyze(cgImage, capturedAt: Date())
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self, weak stream] in
            guard let self, self.requestedRunning, stream === self.stream else {
                return
            }
            self.stopCurrentStream()
            self.publishStatus(.unavailable(error.localizedDescription))
        }
    }

    private func analyze(_ image: CGImage, capturedAt: Date) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false

        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            let observations: [VNRecognizedTextObservation] =
                request.results ?? []
            let samples: [CodexRecognizedText] = observations.compactMap {
                observation in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                return CodexRecognizedText(
                    value: candidate.string,
                    verticalCenter: observation.boundingBox.midY
                )
            }
            let signal = CodexTaskTextClassifier.classify(samples)
            guard let event = activityTracker.consume(
                signal,
                capturedAt: capturedAt
            ) else {
                return
            }
            handle(event)
        } catch {
            // A single failed OCR frame is inconclusive. It must not finish a
            // task or reset the multi-frame activity tracker.
        }
    }

    private func handle(_ event: CodexTaskActivityTracker.Event) {
        switch event {
        case .started(let date):
            publishStatus(.timing(startedAt: date))
        case .completed(let completion):
            publishStatus(.watching)
            DispatchQueue.main.async { [weak self] in
                self?.onTaskCompleted?(
                    Completion(
                        startedAt: completion.startedAt,
                        finishedAt: completion.finishedAt
                    )
                )
            }
        }
    }

    private func publishStatus(_ newStatus: Status) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status != newStatus else { return }
            self.status = newStatus
            self.onStatusChanged?(newStatus)
        }
    }
}

private struct CodexRecognizedText {
    let value: String
    /// Vision uses a normalized bottom-left origin.
    let verticalCenter: CGFloat
}

private enum CodexTaskSignal {
    case processing
    case idle
    case inconclusive
}

private enum CodexTaskTextClassifier {
    private static let strongProcessingPhrases = [
        "esc to interrupt",
        "press esc to interrupt",
        "stop generating",
        "stop task",
        "cancel task",
        "按 esc 中断",
        "按esc中断",
        "停止生成",
        "停止任务",
        "取消任务"
    ]

    private static let statusProcessingPhrases = [
        "working",
        "thinking",
        "planning",
        "implementing",
        "analyzing",
        "reviewing",
        "inspecting",
        "checking",
        "testing",
        "searching",
        "reading",
        "processing",
        "analyzing",
        "executing",
        "running",
        "generating",
        "正在处理",
        "正在工作",
        "思考中",
        "正在思考",
        "分析中",
        "正在分析",
        "执行中",
        "正在执行",
        "运行中",
        "正在运行",
        "生成中",
        "正在生成"
    ]

    static func classify(_ samples: [CodexRecognizedText]) -> CodexTaskSignal {
        guard !samples.isEmpty else { return .inconclusive }

        for sample in samples {
            let normalized = sample.value
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if strongProcessingPhrases.contains(where: normalized.contains) {
                return .processing
            }

            // Codex's live status is located near the composer at the bottom
            // of the window. Restricting generic words such as "working" to
            // this area prevents old conversation text from starting a timer.
            let isStandaloneStatus = statusProcessingPhrases.contains {
                normalized == $0
                    || normalized.hasPrefix("\($0) (")
                    || normalized.hasPrefix("\($0) ·")
            }
            if isStandaloneStatus
                || (
                    sample.verticalCenter < 0.46
                        && statusProcessingPhrases.contains(
                            where: normalized.contains
                        )
                ) {
                return .processing
            }
        }
        return .idle
    }
}

private struct CodexTaskActivityTracker {
    struct CompletedActivity {
        let startedAt: Date
        let finishedAt: Date
    }

    enum Event {
        case started(Date)
        case completed(CompletedActivity)
    }

    private enum Phase {
        case idle
        case confirmingStart(firstSeenAt: Date, count: Int)
        case active(
            startedAt: Date,
            firstIdleAt: Date?,
            consecutiveIdleFrames: Int
        )
    }

    private var phase: Phase = .idle

    mutating func reset() {
        phase = .idle
    }

    mutating func consume(
        _ signal: CodexTaskSignal,
        capturedAt: Date
    ) -> Event? {
        switch (phase, signal) {
        case (.idle, .processing):
            phase = .confirmingStart(firstSeenAt: capturedAt, count: 1)

        case (.confirmingStart(let firstSeenAt, let count), .processing):
            let nextCount = count + 1
            if nextCount >= 2 {
                phase = .active(
                    startedAt: firstSeenAt,
                    firstIdleAt: nil,
                    consecutiveIdleFrames: 0
                )
                return .started(firstSeenAt)
            }
            phase = .confirmingStart(
                firstSeenAt: firstSeenAt,
                count: nextCount
            )

        case (.confirmingStart, .idle):
            phase = .idle

        case (
            .active(let startedAt, _, _),
            .processing
        ):
            phase = .active(
                startedAt: startedAt,
                firstIdleAt: nil,
                consecutiveIdleFrames: 0
            )

        case (
            .active(let startedAt, let firstIdleAt, let idleCount),
            .idle
        ):
            let candidateFinish = firstIdleAt ?? capturedAt
            let nextIdleCount = idleCount + 1
            if nextIdleCount >= 2 {
                phase = .idle
                return .completed(
                    CompletedActivity(
                        startedAt: startedAt,
                        finishedAt: candidateFinish
                    )
                )
            }
            phase = .active(
                startedAt: startedAt,
                firstIdleAt: candidateFinish,
                consecutiveIdleFrames: nextIdleCount
            )

        case (_, .inconclusive):
            break

        case (.idle, .idle):
            break
        }
        return nil
    }
}
