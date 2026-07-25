import AppKit
import QuartzCore

enum ReminderRequirement: Hashable {
    case standing
    case drinking
}

enum ReminderEscalationTimeline {
    static let initialDelay: TimeInterval = 30
    static let expressionFrameCount = 9
    static let expressionFrameDuration: TimeInterval = 3.6
    static let exitFrameCount = 3
    static let exitFrameDuration: TimeInterval = 0.5
    static let repeatDelay: TimeInterval = 30

    static let expressionDuration =
        TimeInterval(expressionFrameCount) * expressionFrameDuration
    static let visibleDuration =
        expressionDuration
            + TimeInterval(exitFrameCount) * exitFrameDuration
    static let firstExitFrameIndex = expressionFrameCount
    static let lastExitFrameIndex =
        expressionFrameCount + exitFrameCount - 1

    static func frameIndex(
        at elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> Int? {
        guard elapsed >= 0, elapsed < visibleDuration else { return nil }
        if reduceMotion {
            return 0
        }
        if elapsed < expressionDuration {
            return min(
                Int(elapsed / expressionFrameDuration),
                expressionFrameCount - 1
            )
        }
        return expressionFrameCount
            + min(
                Int(
                    (elapsed - expressionDuration)
                        / exitFrameDuration
                ),
                exitFrameCount - 1
            )
    }

    static func nextExitFrame(after currentIndex: Int) -> Int? {
        let nextIndex = currentIndex + 1
        guard nextIndex <= lastExitFrameIndex else { return nil }
        return nextIndex
    }
}

enum ReminderEscalationBubbleLayout {
    static let message = "Kiwi 正在盯着你，快行动"

    static func frame(in bounds: NSRect) -> NSRect {
        let width = min(max(bounds.width * 0.30, 280), 390)
        let height: CGFloat = 112
        let rightInset = min(max(bounds.width * 0.12, 72), 220)
        let x = max(24, bounds.maxX - rightInset - width)
        let y = min(
            max(bounds.height * 0.49, 24),
            max(24, bounds.maxY - height - 52)
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

private final class ReminderEscalationBubbleView: NSView {
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            ReminderEscalationBubbleLayout.message
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bodyRect = NSRect(
            x: 5,
            y: 22,
            width: bounds.width - 10,
            height: bounds.height - 27
        )
        let fillColor = NSColor(
            calibratedRed: 0.96,
            green: 0.98,
            blue: 0.78,
            alpha: 0.98
        )
        let borderColor = NSColor(
            calibratedRed: 0.54,
            green: 0.70,
            blue: 0.36,
            alpha: 0.96
        )

        let tail = NSBezierPath()
        tail.move(
            to: NSPoint(
                x: bodyRect.maxX - 88,
                y: bodyRect.minY + 3
            )
        )
        tail.line(
            to: NSPoint(
                x: bodyRect.maxX - 36,
                y: 3
            )
        )
        tail.line(
            to: NSPoint(
                x: bodyRect.maxX - 53,
                y: bodyRect.minY + 31
            )
        )
        tail.close()
        fillColor.setFill()
        borderColor.setStroke()
        tail.lineWidth = 3
        tail.fill()
        tail.stroke()

        let body = NSBezierPath(
            roundedRect: bodyRect,
            xRadius: 27,
            yRadius: 27
        )
        body.lineWidth = 3
        fillColor.setFill()
        borderColor.setStroke()
        body.fill()
        body.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: 22,
                weight: .semibold
            ),
            .foregroundColor: NSColor(
                calibratedRed: 0.19,
                green: 0.24,
                blue: 0.16,
                alpha: 1
            ),
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(
            string: ReminderEscalationBubbleLayout.message,
            attributes: attributes
        )
        let textSize = text.boundingRect(
            with: NSSize(
                width: bodyRect.width - 36,
                height: bodyRect.height - 20
            ),
            options: [
                .usesLineFragmentOrigin,
                .usesFontLeading
            ]
        ).size
        text.draw(
            with: NSRect(
                x: bodyRect.minX + 18,
                y: bodyRect.midY - textSize.height / 2,
                width: bodyRect.width - 36,
                height: textSize.height
            ),
            options: [
                .usesLineFragmentOrigin,
                .usesFontLeading
            ]
        )
    }
}

private final class ReminderEscalationOverlayView: NSView {
    let imageView = NSImageView(frame: .zero)
    private let bubbleView = ReminderEscalationBubbleView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleAxesIndependently
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        addSubview(bubbleView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        bubbleView.frame = ReminderEscalationBubbleLayout.frame(
            in: bounds
        )
    }
}

final class ReminderEscalationWindowController {
    private enum ExitCompletion {
        case close
        case repeatIfWaiting
    }

    private enum Presentation {
        case attention(startedAt: TimeInterval)
        case exit(
            frameIndex: Int,
            displayedAt: TimeInterval,
            completion: ExitCompletion
        )
    }

    private let screenProvider: () -> NSScreen?
    private let frames: [NSImage]
    private var waitingRequirements: Set<ReminderRequirement> = []
    private var escalatedRequirements: Set<ReminderRequirement> = []
    private var delayTimers: [ReminderRequirement: Timer] = [:]
    private var animationTimer: Timer?
    private var presentation: Presentation?
    private var panel: NSPanel?
    private var overlayView: ReminderEscalationOverlayView?
    private var imageView: NSImageView?

    init(screenProvider: @escaping () -> NSScreen?) {
        self.screenProvider = screenProvider
        let loadedFrames = (1...12).compactMap {
            AssetLoader.frame(
                named: String(
                    format: "persistent-reminder-%02d.png",
                    $0
                )
            )
        }
        frames = loadedFrames.count == 12 ? loadedFrames : []
    }

    deinit {
        cancelAll()
    }

    func beginWaiting(for requirement: ReminderRequirement) {
        guard waitingRequirements.insert(requirement).inserted else {
            return
        }
        scheduleEscalation(
            for: requirement,
            after: ReminderEscalationTimeline.initialDelay
        )
    }

    func previewNow() {
        cancelAll()
        escalatedRequirements.insert(.standing)
        beginAttentionIfNeeded()
    }

    func resolve(_ requirement: ReminderRequirement) {
        waitingRequirements.remove(requirement)
        escalatedRequirements.remove(requirement)
        delayTimers.removeValue(forKey: requirement)?.invalidate()

        if escalatedRequirements.isEmpty, presentation != nil {
            beginExit(completion: .close)
        }
    }

    func cancelAll() {
        waitingRequirements.removeAll()
        escalatedRequirements.removeAll()
        delayTimers.values.forEach { $0.invalidate() }
        delayTimers.removeAll()
        closePresentation()
    }

    func screenConfigurationChanged() {
        guard panel?.isVisible == true else { return }
        positionPanel()
    }

    private func scheduleEscalation(
        for requirement: ReminderRequirement,
        after delay: TimeInterval
    ) {
        guard waitingRequirements.contains(requirement),
              delayTimers[requirement] == nil else {
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.delayTimers.removeValue(forKey: requirement)
            guard self.waitingRequirements.contains(requirement) else {
                return
            }
            self.escalatedRequirements.insert(requirement)
            self.beginAttentionIfNeeded()
        }
        delayTimers[requirement] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func beginAttentionIfNeeded() {
        guard presentation == nil, !frames.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        presentation = .attention(startedAt: now)
        showPanel()
        updatePresentation(at: now)
        startAnimationTimer()
    }

    private func beginExit(completion: ExitCompletion) {
        guard presentation != nil else {
            closePresentation()
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            completeExit(completion)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let frameIndex =
            ReminderEscalationTimeline.firstExitFrameIndex
        presentation = .exit(
            frameIndex: frameIndex,
            displayedAt: now,
            completion: completion
        )
        showFrame(frameIndex)
    }

    private func startAnimationTimer() {
        animationTimer?.invalidate()
        let timer = Timer(
            timeInterval: 1.0 / 15.0,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            self.updatePresentation(
                at: ProcessInfo.processInfo.systemUptime
            )
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updatePresentation(at now: TimeInterval) {
        guard let presentation else { return }
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        switch presentation {
        case .attention(let startedAt):
            let elapsed = max(0, now - startedAt)
            guard elapsed
                    < ReminderEscalationTimeline.expressionDuration else {
                beginExit(completion: .repeatIfWaiting)
                return
            }
            guard let index = ReminderEscalationTimeline.frameIndex(
                at: elapsed,
                reduceMotion: reduceMotion
            ) else {
                finishAttention()
                return
            }
            showFrame(index)
        case .exit(
            let frameIndex,
            let displayedAt,
            let completion
        ):
            guard !reduceMotion else {
                completeExit(completion)
                return
            }
            guard now - displayedAt
                    >= ReminderEscalationTimeline.exitFrameDuration else {
                return
            }
            guard let nextFrameIndex =
                    ReminderEscalationTimeline.nextExitFrame(
                        after: frameIndex
                    ) else {
                completeExit(completion)
                return
            }
            self.presentation = .exit(
                frameIndex: nextFrameIndex,
                displayedAt: now,
                completion: completion
            )
            showFrame(nextFrameIndex)
        }
    }

    private func completeExit(_ completion: ExitCompletion) {
        switch completion {
        case .close:
            closePresentation()
        case .repeatIfWaiting:
            finishAttention()
        }
    }

    private func finishAttention() {
        let requirementsToRepeat = waitingRequirements
        escalatedRequirements.removeAll()
        closePresentation()
        for requirement in requirementsToRepeat {
            scheduleEscalation(
                for: requirement,
                after: ReminderEscalationTimeline.repeatDelay
            )
        }
    }

    private func showFrame(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        imageView?.image = frames[index]
    }

    private func showPanel() {
        if panel == nil {
            let overlayView = ReminderEscalationOverlayView(
                frame: .zero
            )

            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .ignoresCycle
            ]
            panel.contentView = overlayView
            self.overlayView = overlayView
            imageView = overlayView.imageView
            self.panel = panel
        }

        positionPanel()
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel?.alphaValue = reduceMotion ? 1 : 0
        panel?.orderFrontRegardless()
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                1,
                0.36,
                1
            )
            panel?.animator().alphaValue = 1
        }
    }

    private func positionPanel() {
        guard let panel,
              let screen = screenProvider() ?? NSScreen.main else {
            return
        }
        panel.setFrame(screen.frame, display: true)
        overlayView?.frame = NSRect(
            origin: .zero,
            size: screen.frame.size
        )
        overlayView?.needsLayout = true
        overlayView?.layoutSubtreeIfNeeded()
    }

    private func closePresentation() {
        animationTimer?.invalidate()
        animationTimer = nil
        presentation = nil
        panel?.orderOut(nil)
        imageView?.image = nil
        if !escalatedRequirements.isEmpty {
            beginAttentionIfNeeded()
        }
    }
}
