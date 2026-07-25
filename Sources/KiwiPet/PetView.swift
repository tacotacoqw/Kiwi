import AppKit
import QuartzCore

enum WalkAnimationVariant: CaseIterable, Hashable {
    case natural
    case alternate

    var framesPerSecond: TimeInterval {
        switch self {
        case .natural: return 10
        case .alternate: return 3
        }
    }

    var prepareFrames: [Int] {
        switch self {
        case .natural:
            return Array(0..<8)
        case .alternate:
            // The APNG starts seated, plants both feet, then rises before
            // its authored right-to-left walking cycle begins.
            return Array(0..<6)
        }
    }

    var strideFrames: [Int] {
        switch self {
        case .natural:
            // The first supplied sequence was exported opposite to its
            // numeric order. Keep the corrected ordering so its feet push
            // in the actual travel direction.
            return [8, 13, 12, 11, 10, 9]
        case .alternate:
            // The APNG timeline is already correct and its processed frames
            // are normalized to the right-facing baseline. Never reverse the
            // stride; the renderer mirrors that baseline for leftward travel.
            return Array(6..<14)
        }
    }

    var settleFrames: [Int] {
        Array(prepareFrames.reversed())
    }

    var prepareDuration: TimeInterval {
        TimeInterval(prepareFrames.count) / framesPerSecond
    }

    var settleDuration: TimeInterval {
        TimeInterval(settleFrames.count) / framesPerSecond
    }
}

struct FeedingPathPlan: Equatable {
    let destinationOrigin: NSPoint
    let direction: CGFloat
    let distance: CGFloat
    let duration: TimeInterval
}

enum FeedingPathPlanner {
    static func plan(
        petFrame: NSRect,
        characterCenterOffset: NSPoint,
        foodFrame: NSRect,
        visibleFrame: NSRect
    ) -> FeedingPathPlan {
        let characterCenter = NSPoint(
            x: petFrame.minX + characterCenterOffset.x,
            y: petFrame.minY + characterCenterOffset.y
        )
        let foodCenter = NSPoint(
            x: foodFrame.midX,
            y: foodFrame.midY
        )
        let direction: CGFloat =
            foodCenter.x >= characterCenter.x ? 1 : -1
        let desiredCharacterCenter = NSPoint(
            x: foodCenter.x - direction * 54,
            y: foodCenter.y + 64
        )
        let unclampedOrigin = NSPoint(
            x: desiredCharacterCenter.x - characterCenterOffset.x,
            y: desiredCharacterCenter.y - characterCenterOffset.y
        )
        let maximumOriginX = max(
            visibleFrame.minX,
            visibleFrame.maxX - petFrame.width
        )
        let maximumOriginY = max(
            visibleFrame.minY,
            visibleFrame.maxY - petFrame.height
        )
        let destination = NSPoint(
            x: min(
                max(unclampedOrigin.x, visibleFrame.minX),
                maximumOriginX
            ),
            y: min(
                max(unclampedOrigin.y, visibleFrame.minY),
                maximumOriginY
            )
        )
        let distance = hypot(
            destination.x - petFrame.minX,
            destination.y - petFrame.minY
        )
        return FeedingPathPlan(
            destinationOrigin: destination,
            direction: direction,
            distance: distance,
            duration: TimeInterval(
                min(max(distance / 115, 0.65), 6.5)
            )
        )
    }
}

enum FeedingActionTimeline {
    static let frameSequence = [
        0, 1, 2, 3,
        3, 2, 3, 2,
        3, 2, 1, 0
    ]
    static let framesPerSecond: TimeInterval = 6
    static let collectionTime: TimeInterval = 0.64
    static let duration =
        TimeInterval(frameSequence.count) / framesPerSecond

    static func frameIndex(at elapsed: TimeInterval) -> Int {
        let sequenceIndex = min(
            max(Int(elapsed * framesPerSecond), 0),
            frameSequence.count - 1
        )
        return frameSequence[sequenceIndex]
    }
}

final class PetView: NSView {
    static let preferredWindowSize = NSSize(width: 360, height: 420)

    static let characterSize = NSSize(width: 172, height: 198)
    private static let workAlertBadgeWindowSize =
        NSSize(width: 200, height: 150)
    private static let workAlertBadgeTopInset: CGFloat = -4

    enum MonitorState: Equatable {
        case off
        case waiting
        case present
    }

    enum QuickAction: Int, CaseIterable {
        case sound
        case status
        case walk
        case calendar
        case feed

        var title: String {
            switch self {
            case .sound: return "声音"
            case .status: return "后台"
            case .walk: return "散步"
            case .calendar: return "日历"
            case .feed: return "喂食"
            }
        }

        var symbolName: String {
            switch self {
            case .sound: return "speaker.wave.2.fill"
            case .status: return "slider.horizontal.3"
            case .walk: return "figure.walk"
            case .calendar: return "calendar"
            case .feed: return "takeoutbag.and.cup.and.straw.fill"
            }
        }

        var iconName: String {
            switch self {
            case .sound: return "sound-on.svg"
            case .status: return "settings.svg"
            case .walk: return "walk.svg"
            case .calendar: return "calendar.svg"
            case .feed: return "feed.svg"
            }
        }

        var fillColor: NSColor {
            switch self {
            case .sound:
                return NSColor(
                    calibratedRed: 0.99,
                    green: 0.94,
                    blue: 0.70,
                    alpha: 0.98
                )
            case .status:
                return NSColor(
                    calibratedRed: 0.98,
                    green: 0.96,
                    blue: 0.75,
                    alpha: 0.98
                )
            case .walk:
                return NSColor(
                    calibratedRed: 0.92,
                    green: 0.96,
                    blue: 0.75,
                    alpha: 0.98
                )
            case .calendar:
                return NSColor(
                    calibratedRed: 0.83,
                    green: 0.94,
                    blue: 0.70,
                    alpha: 0.98
                )
            case .feed:
                return NSColor(
                    calibratedRed: 0.75,
                    green: 0.91,
                    blue: 0.69,
                    alpha: 0.98
                )
            }
        }
    }

    private enum IdleAction: CaseIterable {
        case hop
        case wiggle
        case peek

        var duration: TimeInterval {
            switch self {
            case .hop: return 1.05
            case .wiggle: return 0.9
            case .peek: return 1.25
            }
        }
    }

    private enum FeedingStage: Equatable {
        case bag
        case foodPlacement
        case approaching
        case acting
    }

    private struct FeedingApproachState {
        let startedAt: TimeInterval
        let startOrigin: NSPoint
        let plan: FeedingPathPlan
        let walkVariant: WalkAnimationVariant
    }

    private struct WalkState {
        let variant: WalkAnimationVariant
        let startedAt: TimeInterval
        let prepareDuration: TimeInterval
        let moveDuration: TimeInterval
        let settleDuration: TimeInterval
        let startOrigin: NSPoint
        let distance: CGFloat
        let direction: CGFloat

        var duration: TimeInterval {
            prepareDuration + moveDuration + settleDuration
        }
    }

    private struct PerformanceState {
        let kind: PerformanceKind
        let startedAt: TimeInterval
        let startOrigin: NSPoint
        let destinationOrigin: NSPoint?
        let distance: CGFloat
        let direction: CGFloat
    }

    private enum PerformanceKind {
        case full
        case calendarAlert
    }

    private enum PerformanceTiming {
        static let framesPerSecond: TimeInterval = 4
        static let frameCount = 61
        static let duration = TimeInterval(frameCount) / framesPerSecond
        static let movementStart: TimeInterval = 10
        static let movementEnd: TimeInterval = 13
        static let walkStartFrame = 40
        static let walkEndFrame = 52
        static let settleStartFrame = 53
        static let idleFrames = [57, 58, 59, 60]
        static let calendarRunDuration: TimeInterval = 1.8
        static let calendarCallLeadFrameCount = 18
        static let calendarCallLeadFramesPerSecond: TimeInterval = 15
        static let calendarCallLeadDuration =
            TimeInterval(calendarCallLeadFrameCount)
                / calendarCallLeadFramesPerSecond
        static let calendarCallStartFrame = 18
        static let calendarCallFrameCount = 17
        static let calendarCallFramesPerSecond: TimeInterval = 5.5
        static let calendarCallDuration =
            TimeInterval(calendarCallFrameCount)
                / calendarCallFramesPerSecond
        static let calendarSettleFrameCount = frameCount - settleStartFrame
        static let calendarSettleFramesPerSecond: TimeInterval = 4
        static let calendarSettleDuration =
            TimeInterval(calendarSettleFrameCount)
                / calendarSettleFramesPerSecond
        static let calendarDuration =
            calendarRunDuration
                + calendarCallLeadDuration
                + calendarCallDuration
                + calendarSettleDuration
    }

    var onTap: (() -> Void)?
    var onQuickAction: ((QuickAction) -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?
    var onSoundEnabledChanged: ((Bool) -> Void)?
    var onPositionChanged: ((NSPoint) -> Void)?

    private var characterView: CharacterView?
    private var quickActionButtons: [NSButton] = []
    private var quickActionsVisible = false
    private var quickActionsProgress: CGFloat = 0
    private var quickActionsAnimationStartedAt: TimeInterval?
    private var quickActionsAnimationStartProgress: CGFloat = 0
    private var quickActionsAnimationTarget: CGFloat = 0
    private var feedingStage: FeedingStage?
    private var feedingBagWindow: FeedingDesktopWindow?
    private var feedingFoodWindow: FeedingDesktopWindow?
    private var feedingApproachState: FeedingApproachState?
    private var feedingActionStartedAt: TimeInterval?
    private var feedingFoodCollected = false
    private var feedingSessionID = UUID()
    private var taskTimerFrameIndex: Int?
    private var taskTimerAnimationTimer: Timer?
    private var workAlertImageView: PassThroughImageView?
    private var workAlertWindow: NSPanel?
    private lazy var workAlertSound: NSSound? = {
        let sound = AssetLoader.sound(named: "cartoon-duck-call.mp3")
        sound?.volume = 0.85
        return sound
    }()
    private var workAlertSoundPlayed = false
    private var soundEnabled = true
    private var animationTimer: Timer?
    private var messageTimer: Timer?
    private var workAlertBadgeTimer: Timer?
    private var message: String?
    private var messageImage: NSImage?
    private var pendingWorkAlertTaskMessage: String?
    private var mouseDownLocation: NSPoint?
    private var windowOriginOnMouseDown: NSPoint?
    private var didDrag = false
    private let animationStartedAt = ProcessInfo.processInfo.systemUptime
    private var nextBlinkAt = ProcessInfo.processInfo.systemUptime + Double.random(in: 2.4...4.8)
    private var blinkStartedAt: TimeInterval?
    private var attentionStartedAt: TimeInterval?
    private var attentionStrength: CGFloat = 1
    private var workAlertStartedAt: TimeInterval?
    private var workAlertEyeUntil: TimeInterval = 0
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var idleAction: IdleAction?
    private var idleActionStartedAt: TimeInterval?
    private var nextIdleActionAt = ProcessInfo.processInfo.systemUptime + Double.random(in: 2.8...5.2)
    private var nextEyeLookAt = ProcessInfo.processInfo.systemUptime + Double.random(in: 1.2...3.0)
    private var eyeLookStartedAt: TimeInterval?
    private var spontaneousEyePose: EyePose = .open
    private var nextWalkAt = ProcessInfo.processInfo.systemUptime + Double.random(in: 8.0...13.0)
    private var walkState: WalkState?
    private var performanceState: PerformanceState?
    private var seatedIdleStartedAt = ProcessInfo.processInfo.systemUptime
    private var facingDirection: CGFloat = 1
    private var cursorLean: CGFloat = 0
    private var lastAnimationTick = ProcessInfo.processInfo.systemUptime

    var monitorState: MonitorState = .waiting {
        didSet {
            if monitorState == .present, oldValue != .present {
                playAttentionAnimation(strength: 0.9)
            }
        }
    }

    override init(frame: NSRect) {
        let idleImage = AssetLoader.frame(named: "idle-open.png")
            ?? AssetLoader.frame(named: "idle-07.png")
        let blinkImage = AssetLoader.frame(named: "idle-blink.png")
            ?? AssetLoader.frame(named: "idle-08.png")
        super.init(frame: frame)

        wantsLayer = true
        if let idleImage {
            let characterView = CharacterView(
                frame: characterRect,
                idleImage: idleImage,
                blinkImage: blinkImage
            )
            addSubview(characterView)
            self.characterView = characterView
            characterView.performanceFrameIndex = PerformanceTiming.idleFrames[0]
        }
        setupQuickActionButtons()
        if let workAlertImage = AssetLoader.frame(
            named: "calendar-work-alert.png"
        ) {
            let imageView = PassThroughImageView(
                frame: NSRect(
                    origin: .zero,
                    size: Self.workAlertBadgeWindowSize
                )
            )
            imageView.image = workAlertImage
            imageView.imageAlignment = .alignCenter
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageFrameStyle = .none
            imageView.wantsLayer = true
            imageView.layer?.masksToBounds = false
            imageView.isHidden = true
            workAlertImageView = imageView
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Kiwi 桌宠")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        startAnimating()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        animationTimer?.invalidate()
        messageTimer?.invalidate()
        workAlertBadgeTimer?.invalidate()
        taskTimerAnimationTimer?.invalidate()
        feedingBagWindow?.close()
        feedingFoodWindow?.close()
        if let workAlertWindow {
            window?.removeChildWindow(workAlertWindow)
        }
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        characterView?.frame = characterRect
        layoutQuickActionButtons()
        applyQuickActionVisuals(progress: quickActionsProgress)
        positionWorkAlertWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupWorkAlertWindowIfNeeded()
        positionWorkAlertWindow()
    }

    private var characterRect: NSRect {
        let size = NSSize(
            width: min(Self.characterSize.width, bounds.width - 8),
            height: min(Self.characterSize.height, bounds.height - 50)
        )
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY + 15 - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func setupQuickActionButtons() {
        for action in QuickAction.allCases {
            let button = NSButton(
                title: action.title,
                target: self,
                action: #selector(quickActionPressed(_:))
            )
            if let icon = AssetLoader.icon(named: action.iconName) {
                icon.size = NSSize(width: 15, height: 15)
                button.image = icon
            } else {
                let symbol = NSImage(
                    systemSymbolName: action.symbolName,
                    accessibilityDescription: action.title
                )
                let symbolConfiguration = NSImage.SymbolConfiguration(
                    pointSize: 15,
                    weight: .semibold
                )
                button.image = symbol?.withSymbolConfiguration(
                    symbolConfiguration
                )
            }
            button.imagePosition =
                action == .sound ? .imageOnly : .imageLeading
            button.imageHugsTitle = true
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = NSColor(
                calibratedRed: 0.22,
                green: 0.25,
                blue: 0.20,
                alpha: 1
            )
            let titleFont = NSFont.systemFont(
                ofSize: 9,
                weight: .semibold
            )
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.alignment = .center
            button.font = titleFont
            button.attributedTitle = NSAttributedString(
                string: action.title,
                attributes: [
                    .font: titleFont,
                    .foregroundColor: NSColor(
                        calibratedRed: 0.22,
                        green: 0.25,
                        blue: 0.20,
                        alpha: 1
                    ),
                    .paragraphStyle: titleStyle,
                    .baselineOffset: -1
                ]
            )
            button.alignment = .center
            button.isBordered = false
            button.focusRingType = .none
            button.tag = action.rawValue
            button.toolTip = action.title
            button.setAccessibilityLabel(action.title)
            button.wantsLayer = true
            button.layer?.cornerRadius = action == .sound ? 21 : 16
            button.layer?.cornerCurve = .continuous
            button.layer?.backgroundColor = action.fillColor.cgColor
            button.layer?.borderWidth = 1.5
            button.layer?.borderColor = NSColor(
                calibratedRed: 0.67,
                green: 0.75,
                blue: 0.43,
                alpha: 0.72
            ).cgColor
            button.layer?.shadowColor = NSColor.black.cgColor
            button.layer?.shadowOpacity = 0.14
            button.layer?.shadowRadius = 4
            button.layer?.shadowOffset = CGSize(width: 0, height: -1)
            button.isEnabled = false
            button.isHidden = true
            addSubview(
                button,
                positioned: .above,
                relativeTo: characterView
            )
            quickActionButtons.append(button)
        }
        updateSoundActionButton()
        layoutQuickActionButtons()
        applyQuickActionVisuals(progress: 0)
    }

    private func updateSoundActionButton() {
        guard let index = QuickAction.allCases.firstIndex(of: .sound),
              quickActionButtons.indices.contains(index) else { return }
        let button = quickActionButtons[index]
        let iconName = soundEnabled ? "sound-on.svg" : "sound-off.svg"
        if let icon = AssetLoader.icon(named: iconName) {
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
        }
        button.imagePosition = .imageOnly
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        let accessibilityTitle = soundEnabled ? "关闭声音" : "开启声音"
        button.toolTip = accessibilityTitle
        button.setAccessibilityLabel(accessibilityTitle)
    }

    func setSoundEnabled(_ enabled: Bool) {
        soundEnabled = enabled
        if !enabled, workAlertSoundPlayed {
            workAlertSound?.stop()
        }
        updateSoundActionButton()
    }

    private func layoutQuickActionButtons() {
        guard quickActionButtons.count == QuickAction.allCases.count else {
            return
        }
        let visualCenter = NSPoint(
            x: characterRect.midX,
            y: characterRect.midY + 42
        )
        let arcOffsets = [
            NSPoint(x: 72, y: -84),
            NSPoint(x: 96, y: -28),
            NSPoint(x: 96, y: 28),
            NSPoint(x: 72, y: 84)
        ]
        let arcActions: [QuickAction] = [
            .status,
            .walk,
            .calendar,
            .feed
        ]
        let buttonSize = NSSize(width: 64, height: 46)
        for (action, offset) in zip(arcActions, arcOffsets) {
            guard let index = QuickAction.allCases.firstIndex(of: action) else {
                continue
            }
            let center = NSPoint(
                x: visualCenter.x + offset.x,
                y: visualCenter.y + offset.y
            )
            quickActionButtons[index].frame = NSRect(
                x: center.x - buttonSize.width / 2,
                y: center.y - buttonSize.height / 2,
                width: buttonSize.width,
                height: buttonSize.height
            )
        }

        if let soundIndex = QuickAction.allCases.firstIndex(of: .sound) {
            let soundSize = NSSize(width: 42, height: 42)
            let soundCenter = NSPoint(
                x: characterRect.midX,
                y: characterRect.minY + 65
            )
            quickActionButtons[soundIndex].frame = NSRect(
                x: soundCenter.x - soundSize.width / 2,
                y: soundCenter.y - soundSize.height / 2,
                width: soundSize.width,
                height: soundSize.height
            )
        }
    }

    func toggleQuickActions() {
        setQuickActionsVisible(!quickActionsVisible)
    }

    private func setQuickActionsVisible(_ visible: Bool) {
        guard quickActionsVisible != visible
                || quickActionsAnimationStartedAt != nil else { return }
        quickActionsVisible = visible
        quickActionsAnimationTarget = visible ? 1 : 0
        quickActionsAnimationStartProgress = quickActionsProgress

        if reduceMotion {
            quickActionsAnimationStartedAt = nil
            quickActionsProgress = quickActionsAnimationTarget
            applyQuickActionVisuals(progress: quickActionsProgress)
            return
        }

        if visible {
            quickActionButtons.forEach { $0.isHidden = false }
        }
        quickActionsAnimationStartedAt =
            ProcessInfo.processInfo.systemUptime
    }

    private func updateQuickActions(at now: TimeInterval) {
        guard let startedAt = quickActionsAnimationStartedAt else { return }
        let distance = max(
            abs(
                quickActionsAnimationTarget
                    - quickActionsAnimationStartProgress
            ),
            0.01
        )
        let duration = TimeInterval(0.28 * distance)
        let rawProgress = CGFloat(
            min(max((now - startedAt) / duration, 0), 1)
        )
        let eased = 1 - pow(1 - rawProgress, 3)
        quickActionsProgress =
            quickActionsAnimationStartProgress
                + (
                    quickActionsAnimationTarget
                        - quickActionsAnimationStartProgress
                ) * eased
        applyQuickActionVisuals(progress: quickActionsProgress)

        if rawProgress >= 1 {
            quickActionsAnimationStartedAt = nil
            quickActionsProgress = quickActionsAnimationTarget
            applyQuickActionVisuals(progress: quickActionsProgress)
        }
    }

    private func applyQuickActionVisuals(progress: CGFloat) {
        let progress = min(max(progress, 0), 1)
        let trigger = NSPoint(
            x: characterRect.maxX - 28,
            y: characterRect.midY
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, button) in quickActionButtons.enumerated() {
            let delay = CGFloat(index) * 0.14
            let buttonProgress = min(
                max((progress - delay) / (1 - delay), 0),
                1
            )
            if buttonProgress > 0.001 {
                button.isHidden = false
            }
            let offsetX =
                (trigger.x - button.frame.midX) * (1 - buttonProgress)
            let offsetY =
                (trigger.y - button.frame.midY) * (1 - buttonProgress)
            let scale = 0.88 + buttonProgress * 0.12
            var transform = CGAffineTransform(
                translationX: offsetX,
                y: offsetY
            )
            transform = transform.scaledBy(x: scale, y: scale)
            button.layer?.setAffineTransform(transform)
            button.layer?.opacity = Float(buttonProgress)
            button.isEnabled = buttonProgress > 0.82
        }
        CATransaction.commit()

        if progress <= 0.001, quickActionsAnimationTarget == 0 {
            quickActionButtons.forEach { $0.isHidden = true }
        }
    }

    @objc private func quickActionPressed(_ sender: NSButton) {
        guard let action = QuickAction(rawValue: sender.tag) else { return }
        if action == .sound {
            setSoundEnabled(!soundEnabled)
            onSoundEnabledChanged?(soundEnabled)
            return
        }
        setQuickActionsVisible(false)
        onQuickAction?(action)
    }

    private func setupWorkAlertWindowIfNeeded() {
        guard workAlertWindow == nil,
              let parentWindow = window,
              let workAlertImageView else { return }

        let badgeWindow = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: Self.workAlertBadgeWindowSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        badgeWindow.isOpaque = false
        badgeWindow.backgroundColor = .clear
        badgeWindow.hasShadow = false
        badgeWindow.hidesOnDeactivate = false
        badgeWindow.ignoresMouseEvents = true
        badgeWindow.isReleasedWhenClosed = false
        badgeWindow.level = parentWindow.level
        badgeWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        badgeWindow.contentView = workAlertImageView
        parentWindow.addChildWindow(badgeWindow, ordered: .above)
        workAlertWindow = badgeWindow
    }

    private func positionWorkAlertWindow() {
        guard let parentWindow = window, let workAlertWindow else { return }
        let size = Self.workAlertBadgeWindowSize
        workAlertWindow.setFrameOrigin(
            NSPoint(
                x: parentWindow.frame.midX - size.width / 2 + 90,
                y: parentWindow.frame.maxY
                    - Self.workAlertBadgeTopInset
                    - size.height
            )
        )
    }

    func showMessage(_ text: String, duration: TimeInterval = 8) {
        setQuickActionsVisible(false)
        hideWorkAlertBadge()
        pendingWorkAlertTaskMessage = nil
        messageImage = nil
        message = text
        setAccessibilityValue(text)
        needsDisplay = true

        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.message = nil
            self?.messageImage = nil
            self?.needsDisplay = true
        }
        if let messageTimer {
            RunLoop.main.add(messageTimer, forMode: .common)
        }
    }

    func showMessageImage(
        named imageName: String,
        accessibilityText: String,
        duration: TimeInterval = 8,
        untilDismissed: Bool = false
    ) {
        guard let image = AssetLoader.frame(named: imageName) else {
            showMessage(accessibilityText, duration: duration)
            return
        }

        setQuickActionsVisible(false)
        hideWorkAlertBadge()
        pendingWorkAlertTaskMessage = nil
        message = nil
        messageImage = image
        setAccessibilityValue(accessibilityText)
        needsDisplay = true

        messageTimer?.invalidate()
        messageTimer = nil
        guard !untilDismissed else { return }
        messageTimer = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: false
        ) { [weak self] _ in
            self?.message = nil
            self?.messageImage = nil
            self?.needsDisplay = true
        }
        if let messageTimer {
            RunLoop.main.add(messageTimer, forMode: .common)
        }
    }

    func dismissMessage() {
        messageTimer?.invalidate()
        messageTimer = nil
        message = nil
        messageImage = nil
        setAccessibilityValue(nil)
        needsDisplay = true
    }

    private func prepareWorkAlertBadge(details: String) {
        setQuickActionsVisible(false)
        pendingWorkAlertTaskMessage = "今天的任务：\(details)"
        message = nil
        messageImage = nil
        setAccessibilityValue("来活啦！")
        messageTimer?.invalidate()
        hideWorkAlertBadge()
        needsDisplay = true
    }

    private func showPendingWorkAlertTaskMessage() {
        guard let taskMessage = pendingWorkAlertTaskMessage else { return }
        pendingWorkAlertTaskMessage = nil
        messageImage = nil
        message = taskMessage
        setAccessibilityValue(taskMessage)
        needsDisplay = true

        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(
            withTimeInterval: 16,
            repeats: false
        ) { [weak self] _ in
            self?.message = nil
            self?.messageImage = nil
            self?.needsDisplay = true
        }
        if let messageTimer {
            RunLoop.main.add(messageTimer, forMode: .common)
        }
    }

    private func showReducedMotionWorkAlertBadge() {
        guard let workAlertImageView else { return }
        workAlertImageView.isHidden = false
        applyWorkAlertBadgeTransform(
            scale: 1,
            offsetY: 0,
            rotation: 0,
            opacity: 1
        )
        workAlertBadgeTimer?.invalidate()
        workAlertBadgeTimer = Timer.scheduledTimer(
            withTimeInterval: PerformanceTiming.calendarCallDuration,
            repeats: false
        ) { [weak self] _ in
            self?.hideWorkAlertBadge()
            self?.showPendingWorkAlertTaskMessage()
        }
        if let workAlertBadgeTimer {
            RunLoop.main.add(workAlertBadgeTimer, forMode: .common)
        }
    }

    func playAttentionAnimation(strength: CGFloat = 1) {
        guard !reduceMotion else { return }
        attentionStrength = max(0.5, min(strength, 1.6))
        attentionStartedAt = ProcessInfo.processInfo.systemUptime
    }

    func showWorkAlert(details: String) {
        let now = ProcessInfo.processInfo.systemUptime
        cancelFeeding()
        cancelPerformance()
        cancelWalk()
        idleAction = nil
        idleActionStartedAt = nil
        attentionStartedAt = nil
        workAlertStartedAt = nil
        workAlertEyeUntil = 0
        workAlertSoundPlayed = false
        prepareWorkAlertBadge(details: details)
        restoreVisibility()

        guard !reduceMotion else {
            seatedIdleStartedAt = now
            updateSeatedIdle(at: now)
            showReducedMotionWorkAlertBadge()
            return
        }

        eyeLookStartedAt = nil
        let placement = calendarAlertPlacement()
        facingDirection = placement.direction
        nextIdleActionAt = now
            + PerformanceTiming.calendarDuration
            + Double.random(in: 4.0...7.5)
        performanceState = PerformanceState(
            kind: .calendarAlert,
            startedAt: now,
            startOrigin: placement.start,
            destinationOrigin: placement.destination,
            distance: 0,
            direction: placement.direction
        )
        clearWalkingFrameImages()
        characterView?.walkFrameIndex = nil
        characterView?.performanceFrameIndex = 0
    }

    func restoreVisibility() {
        isHidden = false
        alphaValue = 1
        characterView?.restoreContents()
        updateCharacter(at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }

    func startWalkNow() {
        guard !reduceMotion else { return }
        setQuickActionsVisible(false)
        cancelFeeding()
        cancelPerformance()
        cancelWalk()
        beginWalk(at: ProcessInfo.processInfo.systemUptime)
    }

    func playPerformanceNow() {
        setQuickActionsVisible(false)
        cancelFeeding()
        guard !reduceMotion else {
            seatedIdleStartedAt = ProcessInfo.processInfo.systemUptime
            updateSeatedIdle(at: seatedIdleStartedAt)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        cancelWalk()
        idleAction = nil
        idleActionStartedAt = nil
        attentionStartedAt = nil
        workAlertStartedAt = nil
        eyeLookStartedAt = nil

        let placement = movementPlacement(maximumDistance: 180)
        facingDirection = placement.direction
        nextIdleActionAt = now
            + PerformanceTiming.duration
            + Double.random(in: 4.0...7.5)
        performanceState = PerformanceState(
            kind: .full,
            startedAt: now,
            startOrigin: placement.origin,
            destinationOrigin: nil,
            distance: placement.distance,
            direction: placement.direction
        )
        clearWalkingFrameImages()
        characterView?.walkFrameIndex = nil
        characterView?.performanceFrameIndex = 0
    }

    func startFeeding() {
        setQuickActionsVisible(false)
        cancelPerformance()
        cancelWalk()
        cancelFeeding()

        let now = ProcessInfo.processInfo.systemUptime
        idleAction = nil
        idleActionStartedAt = nil
        attentionStartedAt = nil
        eyeLookStartedAt = nil
        nextWalkAt = now + 12
        presentFeedingBag()
        showMessage("点一下食物袋，把食物拿出来。", duration: 6)
    }

    func setTaskTimerFrame(_ index: Int?) {
        guard let index else {
            guard taskTimerFrameIndex != nil else { return }
            stopTaskTimerAnimation()
            taskTimerFrameIndex = nil
            characterView?.setTaskTimerFrame(
                nil,
                animated: false
            )
            let now = ProcessInfo.processInfo.systemUptime
            seatedIdleStartedAt = now
            nextIdleActionAt = now + Double.random(in: 3.0...5.0)
            nextWalkAt = now + Double.random(in: 7.0...12.0)
            updateCharacter(at: now)
            return
        }

        // The popup reports that task timing is active. Once active, the
        // desktop pet owns playback so the five supplied frames visibly move
        // even when task-status polling is slower than the animation.
        guard taskTimerFrameIndex == nil else { return }
        let safeIndex = min(
            max(0, index),
            TaskBreakTimerProgress.frameCount - 1
        )
        let now = ProcessInfo.processInfo.systemUptime
        cancelPerformance()
        cancelWalk()
        clearWalkingFrameImages()
        characterView?.walkFrameIndex = nil
        characterView?.performanceFrameIndex = nil
        idleAction = nil
        idleActionStartedAt = nil
        attentionStartedAt = nil
        eyeLookStartedAt = nil
        cursorLean = 0
        facingDirection = 1
        applyTaskTimerFrame(safeIndex, animated: false)
        startTaskTimerAnimation()
        updateCharacter(at: now)
    }

    private func startTaskTimerAnimation() {
        stopTaskTimerAnimation()
        guard taskTimerFrameIndex != nil, !reduceMotion else { return }

        let timer = Timer(
            timeInterval: 0.8,
            repeats: true
        ) { [weak self] _ in
            guard let self,
                  let currentFrame = self.taskTimerFrameIndex else {
                return
            }
            let nextFrame =
                (currentFrame + 1)
                    % TaskBreakTimerProgress.frameCount
            self.applyTaskTimerFrame(
                nextFrame,
                animated: true
            )
        }
        taskTimerAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTaskTimerAnimation() {
        taskTimerAnimationTimer?.invalidate()
        taskTimerAnimationTimer = nil
    }

    private func applyTaskTimerFrame(
        _ index: Int,
        animated: Bool
    ) {
        taskTimerFrameIndex = index
        characterView?.setTaskTimerFrame(
            index,
            animated:
                animated
                    && feedingStage == nil
                    && performanceState == nil
                    && !reduceMotion
        )
    }

    var activeTaskTimerFrameIndex: Int? {
        taskTimerFrameIndex
    }

    private func presentFeedingBag() {
        guard let petWindow = window,
              let image = AssetLoader.frame(named: "feed-bag.png") else {
            feedingStage = nil
            showMessage("食物素材没有加载成功。", duration: 5)
            return
        }
        let size = NSSize(width: 124, height: 108)
        let visibleFrame =
            petWindow.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? petWindow.frame
        let proposedOrigin = NSPoint(
            x: petWindow.frame.maxX - size.width - 12,
            y: petWindow.frame.minY + 34
        )
        let frame = clampedDesktopItemFrame(
            NSRect(origin: proposedOrigin, size: size),
            to: visibleFrame
        )

        let bagWindow = FeedingDesktopWindow(
            frame: frame,
            image: image,
            draggable: false,
            accessibilityLabel: "装满食物的食物袋"
        )
        bagWindow.onClick = { [weak self, weak bagWindow] in
            guard let self, let bagWindow else { return }
            self.openFoodBag(bagWindow)
        }
        feedingStage = .bag
        feedingBagWindow = bagWindow
        bagWindow.orderFrontRegardless()
        bagWindow.animateIn(reduceMotion: reduceMotion)
    }

    private func openFoodBag(_ bagWindow: FeedingDesktopWindow) {
        guard feedingStage == .bag,
              feedingBagWindow === bagWindow,
              let emptyBag = AssetLoader.frame(
                  named: "feed-bag-empty.png"
              ),
              let food = AssetLoader.frame(named: "feed-food.png") else {
            return
        }
        bagWindow.onClick = nil
        bagWindow.update(
            image: emptyBag,
            draggable: false,
            accessibilityLabel: "已经倒空的食物袋"
        )

        let foodSize = NSSize(width: 112, height: 58)
        let screen = bagWindow.screen ?? window?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? bagWindow.frame
        let proposedFoodFrame = NSRect(
            x: bagWindow.frame.midX - foodSize.width / 2,
            y: bagWindow.frame.maxY - 16,
            width: foodSize.width,
            height: foodSize.height
        )
        let foodWindow = FeedingDesktopWindow(
            frame: clampedDesktopItemFrame(
                proposedFoodFrame,
                to: visibleFrame
            ),
            image: food,
            draggable: true,
            accessibilityLabel: "可以拖动的食物"
        )
        foodWindow.onClick = { [weak self] in
            self?.showMessage(
                "把食物拖到桌面任意位置，松手后我会走过去。",
                duration: 5
            )
        }
        foodWindow.onDrop = { [weak self, weak foodWindow] frame in
            guard let self, let foodWindow,
                  self.feedingFoodWindow === foodWindow else { return }
            self.beginFeedingApproach(to: frame)
        }
        feedingFoodWindow = foodWindow
        feedingStage = .foodPlacement
        foodWindow.orderFrontRegardless()
        foodWindow.animateIn(reduceMotion: reduceMotion)
        showMessage(
            "食物拿出来了，拖到桌面任意位置再松手。",
            duration: 7
        )

        let sessionID = feedingSessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            [weak self, weak bagWindow] in
            guard let self, let bagWindow,
                  self.feedingSessionID == sessionID,
                  self.feedingBagWindow === bagWindow else { return }
            bagWindow.fadeOut(
                duration: 0.28,
                reduceMotion: self.reduceMotion
            ) { [weak self, weak bagWindow] in
                guard let self, let bagWindow,
                      self.feedingBagWindow === bagWindow else { return }
                self.feedingBagWindow = nil
            }
        }
    }

    private func beginFeedingApproach(to foodFrame: NSRect) {
        guard feedingStage == .foodPlacement,
              let petWindow = window,
              let foodWindow = feedingFoodWindow else { return }
        foodWindow.setInteractionEnabled(false)
        cancelPerformance()
        cancelWalk()
        idleAction = nil
        idleActionStartedAt = nil
        attentionStartedAt = nil
        eyeLookStartedAt = nil

        let foodCenter = NSPoint(
            x: foodFrame.midX,
            y: foodFrame.midY
        )
        let screen = NSScreen.screens.first {
            $0.frame.contains(foodCenter)
        } ?? petWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? petWindow.frame
        let plan = FeedingPathPlanner.plan(
            petFrame: petWindow.frame,
            characterCenterOffset: characterScreenCenterOffset,
            foodFrame: foodFrame,
            visibleFrame: visibleFrame
        )
        facingDirection = plan.direction
        feedingStage = .approaching
        showMessage("我看到啦，这就过去！", duration: 4)

        let now = ProcessInfo.processInfo.systemUptime
        guard !reduceMotion else {
            petWindow.setFrameOrigin(plan.destinationOrigin)
            startFeedingAction(at: now)
            return
        }
        feedingApproachState = FeedingApproachState(
            startedAt: now,
            startOrigin: petWindow.frame.origin,
            plan: plan,
            walkVariant:
                WalkAnimationVariant.allCases.randomElement()
                    ?? .natural
        )
    }

    private var characterScreenCenterOffset: NSPoint {
        NSPoint(
            x: characterRect.midX,
            y: bounds.height - characterRect.midY
        )
    }

    private func clampedDesktopItemFrame(
        _ frame: NSRect,
        to visibleFrame: NSRect
    ) -> NSRect {
        NSRect(
            x: min(
                max(frame.minX, visibleFrame.minX),
                max(visibleFrame.minX, visibleFrame.maxX - frame.width)
            ),
            y: min(
                max(frame.minY, visibleFrame.minY),
                max(visibleFrame.minY, visibleFrame.maxY - frame.height)
            ),
            width: frame.width,
            height: frame.height
        )
    }

    private func startFeedingAction(at now: TimeInterval) {
        feedingApproachState = nil
        clearWalkingFrameImages()
        characterView?.walkFrameIndex = nil
        characterView?.performanceFrameIndex = nil
        characterView?.feedingFrameIndex = 0
        feedingStage = .acting
        feedingActionStartedAt = now
        feedingFoodCollected = false
    }

    func cancelFeeding() {
        feedingSessionID = UUID()
        feedingBagWindow?.close()
        feedingFoodWindow?.close()
        feedingBagWindow = nil
        feedingFoodWindow = nil
        feedingApproachState = nil
        feedingActionStartedAt = nil
        feedingFoodCollected = false
        characterView?.feedingFrameIndex = nil
        clearWalkingFrameImages()
        feedingStage = nil
    }

    private func updateFeedingJourney(at now: TimeInterval) {
        if let approach = feedingApproachState, let petWindow = window {
            let elapsed = max(0, now - approach.startedAt)
            let progress = CGFloat(
                min(elapsed / approach.plan.duration, 1)
            )
            let eased = progress * progress * (3 - 2 * progress)
            petWindow.setFrameOrigin(
                NSPoint(
                    x: approach.startOrigin.x
                        + (
                            approach.plan.destinationOrigin.x
                                - approach.startOrigin.x
                        ) * eased,
                    y: approach.startOrigin.y
                        + (
                            approach.plan.destinationOrigin.y
                                - approach.startOrigin.y
                        ) * eased
                )
            )
            characterView?.performanceFrameIndex = nil
            characterView?.walkFrameIndex = nil
            let strideFrames = approach.walkVariant.strideFrames
            let strideIndex =
                Int(
                    elapsed * approach.walkVariant.framesPerSecond
                ) % strideFrames.count
            showWalkingFrame(
                strideFrames[strideIndex],
                variant: approach.walkVariant
            )

            if progress >= 1 {
                petWindow.setFrameOrigin(
                    approach.plan.destinationOrigin
                )
                startFeedingAction(at: now)
            }
            return
        }

        guard let feedingActionStartedAt else { return }
        if reduceMotion {
            collectFoodForFeeding()
            finishFeedingAction(at: now)
            return
        }

        let elapsed = max(0, now - feedingActionStartedAt)
        characterView?.feedingFrameIndex =
            FeedingActionTimeline.frameIndex(at: elapsed)

        if elapsed >= FeedingActionTimeline.collectionTime {
            collectFoodForFeeding()
        }
        if elapsed >= FeedingActionTimeline.duration {
            finishFeedingAction(at: now)
        }
    }

    private func collectFoodForFeeding() {
        guard !feedingFoodCollected,
              let petWindow = window,
              let foodWindow = feedingFoodWindow else { return }
        feedingFoodCollected = true
        let characterCenter = NSPoint(
            x: petWindow.frame.minX + characterScreenCenterOffset.x,
            y: petWindow.frame.minY + characterScreenCenterOffset.y
        )
        let mouth = NSPoint(
            x: characterCenter.x + facingDirection * 47,
            y: characterCenter.y - 16
        )
        let sessionID = feedingSessionID
        foodWindow.animateToward(
            screenPoint: mouth,
            duration: 0.26,
            reduceMotion: reduceMotion
        ) { [weak self, weak foodWindow] in
            guard let self, let foodWindow,
                  self.feedingSessionID == sessionID,
                  self.feedingFoodWindow === foodWindow else { return }
            self.feedingFoodWindow = nil
        }
    }

    private func finishFeedingAction(at now: TimeInterval) {
        feedingApproachState = nil
        feedingActionStartedAt = nil
        feedingStage = nil
        characterView?.feedingFrameIndex = nil
        clearWalkingFrameImages()
        characterView?.performanceFrameIndex =
            taskTimerFrameIndex == nil
                ? PerformanceTiming.idleFrames[0]
                : nil
        seatedIdleStartedAt = now
        nextIdleActionAt = now + 4
        nextWalkAt = now + 8
        if let origin = window?.frame.origin {
            onPositionChanged?(origin)
        }
        showMessage("吃饱啦！", duration: 3)
    }

    private func startAnimating() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let delta = min(max(now - self.lastAnimationTick, 0), 0.1)
            self.lastAnimationTick = now
            self.updateBlink(at: now)
            self.updateEyeLook(at: now)
            self.updateFeedingJourney(at: now)
            self.updatePerformance(at: now)
            self.updateWalk(at: now)
            self.updateSeatedIdle(at: now)
            self.updateIdleAction(at: now)
            self.updateCursorLean(delta: delta)
            self.updateCharacter(at: now)
            self.updateQuickActions(at: now)
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateBlink(at now: TimeInterval) {
        if blinkStartedAt == nil, now >= nextBlinkAt {
            blinkStartedAt = now
        }

        if let blinkStartedAt, now - blinkStartedAt >= 0.25 {
            self.blinkStartedAt = nil
            let isDoubleBlink = Double.random(in: 0...1) < 0.18
            nextBlinkAt = now + (isDoubleBlink ? 0.16 : Double.random(in: 2.6...5.4))
        }
    }

    private func blinkAmount(at now: TimeInterval) -> CGFloat {
        guard let blinkStartedAt else { return 0 }
        let elapsed = now - blinkStartedAt
        switch elapsed {
        case ..<0.075:
            return CGFloat(elapsed / 0.075)
        case ..<0.13:
            return 1
        case ..<0.25:
            return CGFloat(1 - (elapsed - 0.13) / 0.12)
        default:
            return 0
        }
    }

    private func updateIdleAction(at now: TimeInterval) {
        guard !reduceMotion else {
            idleAction = nil
            idleActionStartedAt = nil
            return
        }

        if let idleAction, let idleActionStartedAt {
            if now - idleActionStartedAt >= idleAction.duration {
                self.idleAction = nil
                self.idleActionStartedAt = nil
                nextIdleActionAt = now + Double.random(in: 4.0...7.5)
            }
            return
        }

        guard taskTimerFrameIndex == nil,
              walkState == nil,
              performanceState == nil,
              feedingStage == nil,
              attentionStartedAt == nil,
              workAlertStartedAt == nil,
              now >= nextIdleActionAt else { return }
        idleAction = IdleAction.allCases.randomElement() ?? .hop
        idleActionStartedAt = now
    }

    private func updateEyeLook(at now: TimeInterval) {
        guard !reduceMotion else {
            eyeLookStartedAt = nil
            spontaneousEyePose = .open
            return
        }

        if let eyeLookStartedAt {
            if now - eyeLookStartedAt >= 0.9 {
                self.eyeLookStartedAt = nil
                spontaneousEyePose = .open
                nextEyeLookAt = now + Double.random(in: 1.4...3.4)
            }
            return
        }

        guard taskTimerFrameIndex == nil,
              walkState == nil,
              performanceState == nil,
              feedingStage == nil,
              workAlertStartedAt == nil,
              now >= nextEyeLookAt else { return }
        spontaneousEyePose = [.left, .right, .up, .half].randomElement() ?? .up
        eyeLookStartedAt = now
    }

    private func updatePerformance(at now: TimeInterval) {
        guard !reduceMotion else {
            cancelPerformance()
            return
        }
        guard let performanceState else { return }

        let elapsed = max(0, now - performanceState.startedAt)
        clearWalkingFrameImages()
        let duration: TimeInterval
        switch performanceState.kind {
        case .full:
            hideWorkAlertBadge()
            duration = PerformanceTiming.duration
            characterView?.walkFrameIndex = nil
            characterView?.performanceFrameIndex = min(
                Int(elapsed * PerformanceTiming.framesPerSecond),
                PerformanceTiming.frameCount - 1
            )
        case .calendarAlert:
            let callStart =
                PerformanceTiming.calendarRunDuration
                    + PerformanceTiming.calendarCallLeadDuration
            if elapsed >= callStart, !workAlertSoundPlayed {
                workAlertSoundPlayed = true
                if soundEnabled {
                    workAlertSound?.stop()
                    workAlertSound?.play()
                }
            }
            updateWorkAlertBadge(forCalendarElapsed: elapsed)
            duration = PerformanceTiming.calendarDuration
            if elapsed < PerformanceTiming.calendarRunDuration {
                characterView?.performanceFrameIndex = nil
                characterView?.walkFrameIndex =
                    Int(elapsed * 12) % 3
            } else {
                characterView?.walkFrameIndex = nil
                let performanceElapsed =
                    elapsed - PerformanceTiming.calendarRunDuration
                if performanceElapsed
                    < PerformanceTiming.calendarCallLeadDuration
                {
                    characterView?.performanceFrameIndex = min(
                        Int(
                            performanceElapsed
                                * PerformanceTiming
                                    .calendarCallLeadFramesPerSecond
                        ),
                        PerformanceTiming.calendarCallLeadFrameCount - 1
                    )
                } else if performanceElapsed
                    < PerformanceTiming.calendarCallLeadDuration
                        + PerformanceTiming.calendarCallDuration
                {
                    let callElapsed =
                        performanceElapsed
                            - PerformanceTiming.calendarCallLeadDuration
                    characterView?.performanceFrameIndex =
                        PerformanceTiming.calendarCallStartFrame + min(
                            Int(
                                callElapsed
                                    * PerformanceTiming
                                        .calendarCallFramesPerSecond
                            ),
                            PerformanceTiming.calendarCallFrameCount - 1
                        )
                } else {
                    let settleElapsed =
                        performanceElapsed
                            - PerformanceTiming.calendarCallLeadDuration
                            - PerformanceTiming.calendarCallDuration
                    characterView?.performanceFrameIndex =
                        PerformanceTiming.settleStartFrame + min(
                            Int(
                                settleElapsed
                                    * PerformanceTiming
                                        .calendarSettleFramesPerSecond
                            ),
                            PerformanceTiming.calendarSettleFrameCount - 1
                        )
                }
            }
        }

        switch performanceState.kind {
        case .full:
            if elapsed >= PerformanceTiming.movementStart {
                let movementDuration = PerformanceTiming.movementEnd
                    - PerformanceTiming.movementStart
                let progress = min(
                    max(
                        (elapsed - PerformanceTiming.movementStart)
                            / movementDuration,
                        0
                    ),
                    1
                )
                let eased = progress * progress * (3 - 2 * progress)
                let x = performanceState.startOrigin.x
                    + performanceState.direction
                    * performanceState.distance
                    * eased
                window?.setFrameOrigin(
                    NSPoint(x: x, y: performanceState.startOrigin.y)
                )
            }
        case .calendarAlert:
            if let destination = performanceState.destinationOrigin {
                let progress = min(
                    max(
                        elapsed / PerformanceTiming.calendarRunDuration,
                        0
                    ),
                    1
                )
                let eased = 1 - pow(1 - progress, 3)
                window?.setFrameOrigin(
                    NSPoint(
                        x: performanceState.startOrigin.x
                            + (destination.x - performanceState.startOrigin.x)
                            * eased,
                        y: performanceState.startOrigin.y
                            + (destination.y - performanceState.startOrigin.y)
                            * eased
                    )
                )
            }
        }

        if elapsed >= duration {
            hideWorkAlertBadge()
            self.performanceState = nil
            seatedIdleStartedAt = now
            nextIdleActionAt = now + Double.random(in: 4.0...7.5)
            nextWalkAt = now + Double.random(in: 9.0...16.0)
            if let origin = window?.frame.origin {
                onPositionChanged?(origin)
            }
        }
    }

    private func updateSeatedIdle(at now: TimeInterval) {
        guard taskTimerFrameIndex == nil,
              performanceState == nil,
              walkState == nil,
              feedingApproachState == nil,
              feedingActionStartedAt == nil else { return }
        let elapsed = max(0, now - seatedIdleStartedAt)
        let step = Int(elapsed * PerformanceTiming.framesPerSecond)
            % PerformanceTiming.idleFrames.count
        clearWalkingFrameImages()
        characterView?.walkFrameIndex = nil
        characterView?.performanceFrameIndex =
            PerformanceTiming.idleFrames[step]
    }

    private func showWalkingFrame(
        _ frameIndex: Int,
        variant: WalkAnimationVariant
    ) {
        switch variant {
        case .natural:
            characterView?.naturalWalkFrameIndex = frameIndex
            characterView?.alternateWalkFrameIndex = nil
        case .alternate:
            characterView?.naturalWalkFrameIndex = nil
            characterView?.alternateWalkFrameIndex = frameIndex
        }
    }

    private func clearWalkingFrameImages() {
        characterView?.naturalWalkFrameIndex = nil
        characterView?.alternateWalkFrameIndex = nil
    }

    private func updateWalk(at now: TimeInterval) {
        guard !reduceMotion else {
            cancelWalk()
            return
        }
        guard taskTimerFrameIndex == nil,
              performanceState == nil else { return }

        if let walkState {
            let elapsed = max(0, now - walkState.startedAt)
            characterView?.performanceFrameIndex = nil
            characterView?.walkFrameIndex = nil

            if elapsed < walkState.prepareDuration {
                let step = min(
                    Int(
                        elapsed
                            * walkState.variant.framesPerSecond
                    ),
                    walkState.variant.prepareFrames.count - 1
                )
                showWalkingFrame(
                    walkState.variant.prepareFrames[step],
                    variant: walkState.variant
                )
                window?.setFrameOrigin(walkState.startOrigin)
            } else if elapsed
                < walkState.prepareDuration + walkState.moveDuration
            {
                let moveElapsed = elapsed - walkState.prepareDuration
                let progress = min(
                    max(moveElapsed / walkState.moveDuration, 0),
                    1
                )
                let x = walkState.startOrigin.x
                    + walkState.direction
                    * walkState.distance
                    * progress
                window?.setFrameOrigin(
                    NSPoint(x: x, y: walkState.startOrigin.y)
                )

                let strideStep =
                    Int(
                        moveElapsed
                            * walkState.variant.framesPerSecond
                    ) % walkState.variant.strideFrames.count
                showWalkingFrame(
                    walkState.variant.strideFrames[strideStep],
                    variant: walkState.variant
                )
            } else {
                window?.setFrameOrigin(
                    NSPoint(
                        x: walkState.startOrigin.x
                            + walkState.direction * walkState.distance,
                        y: walkState.startOrigin.y
                    )
                )
                let settleElapsed =
                    elapsed
                        - walkState.prepareDuration
                        - walkState.moveDuration
                let settleStep = min(
                    Int(
                        settleElapsed
                            * walkState.variant.framesPerSecond
                    ),
                    walkState.variant.settleFrames.count - 1
                )
                showWalkingFrame(
                    walkState.variant.settleFrames[settleStep],
                    variant: walkState.variant
                )
            }

            if elapsed >= walkState.duration {
                self.walkState = nil
                clearWalkingFrameImages()
                characterView?.walkFrameIndex = nil
                characterView?.performanceFrameIndex =
                    PerformanceTiming.idleFrames[0]
                seatedIdleStartedAt = now
                nextIdleActionAt = now + Double.random(in: 4.0...7.5)
                nextWalkAt = now + Double.random(in: 9.0...16.0)
                if let origin = window?.frame.origin {
                    onPositionChanged?(origin)
                }
            }
            return
        }

        guard now >= nextWalkAt,
              feedingStage == nil,
              idleAction == nil,
              attentionStartedAt == nil,
              workAlertStartedAt == nil else { return }
        beginWalk(at: now)
    }

    private func beginWalk(at now: TimeInterval) {
        guard taskTimerFrameIndex == nil,
              let window,
              let screen = window.screen ?? NSScreen.main else {
            nextWalkAt = now + 5
            return
        }

        let visible = screen.visibleFrame.insetBy(dx: 10, dy: 0)
        let start = window.frame.origin
        let availableLeft = max(0, start.x - visible.minX)
        let availableRight = max(0, visible.maxX - window.frame.width - start.x)

        let preferredDirection: CGFloat
        if availableRight < 70 {
            preferredDirection = -1
        } else if availableLeft < 70 {
            preferredDirection = 1
        } else {
            preferredDirection = Bool.random() ? 1 : -1
        }

        let available = preferredDirection > 0 ? availableRight : availableLeft
        let distance = min(CGFloat.random(in: 105...175), available)
        guard distance >= 45 else {
            nextWalkAt = now + 5
            return
        }

        facingDirection = preferredDirection
        idleAction = nil
        idleActionStartedAt = nil
        let variant =
            WalkAnimationVariant.allCases.randomElement() ?? .natural
        walkState = WalkState(
            variant: variant,
            startedAt: now,
            prepareDuration: variant.prepareDuration,
            moveDuration: TimeInterval(
                max(2.4, min(3.6, distance / 48))
            ),
            settleDuration: variant.settleDuration,
            startOrigin: start,
            distance: distance,
            direction: preferredDirection
        )
        if let walkState {
            nextIdleActionAt = now
                + walkState.duration
                + Double.random(in: 4.0...7.5)
        }
        showWalkingFrame(
            variant.prepareFrames[0],
            variant: variant
        )
        characterView?.walkFrameIndex = nil
        characterView?.performanceFrameIndex = nil
    }

    private func cancelWalk() {
        guard walkState != nil else { return }
        walkState = nil
        clearWalkingFrameImages()
        characterView?.walkFrameIndex = nil
        characterView?.performanceFrameIndex =
            PerformanceTiming.idleFrames[0]
        seatedIdleStartedAt = ProcessInfo.processInfo.systemUptime
        nextIdleActionAt = seatedIdleStartedAt + Double.random(in: 4.0...7.5)
        nextWalkAt = ProcessInfo.processInfo.systemUptime + Double.random(in: 7.0...12.0)
        if let origin = window?.frame.origin {
            onPositionChanged?(origin)
        }
    }

    private func updateWorkAlertBadge(
        forCalendarElapsed elapsed: TimeInterval
    ) {
        let callStart =
            PerformanceTiming.calendarRunDuration
                + PerformanceTiming.calendarCallLeadDuration
        let callEnd =
            callStart + PerformanceTiming.calendarCallDuration
        guard elapsed >= callStart else {
            hideWorkAlertBadge()
            return
        }
        guard elapsed < callEnd else {
            hideWorkAlertBadge()
            showPendingWorkAlertTaskMessage()
            return
        }
        guard let workAlertImageView else { return }
        workAlertImageView.isHidden = false

        let localElapsed = elapsed - callStart
        let remaining = callEnd - elapsed
        let enterDuration: TimeInterval = 0.28
        let exitDuration: TimeInterval = 0.22

        let scale: CGFloat
        let offsetY: CGFloat
        let rotation: CGFloat
        let opacity: CGFloat
        if localElapsed < enterDuration {
            let progress = CGFloat(
                min(max(localElapsed / enterDuration, 0), 1)
            )
            let eased = easedOut(progress)
            scale = 0.88
                + 0.12 * eased
                + sin(progress * .pi) * 0.035
            offsetY = (1 - eased) * 8
            rotation = (1 - eased) * -0.025
            opacity = min(progress / 0.43, 1)
        } else if remaining < exitDuration {
            let progress = CGFloat(
                min(max(1 - remaining / exitDuration, 0), 1)
            )
            let eased = progress * progress
            scale = 1 - eased * 0.04
            offsetY = -eased * 6
            rotation = eased * 0.018
            opacity = 1 - eased
        } else {
            let holdElapsed = CGFloat(localElapsed - enterDuration)
            let floatWave = sin(
                holdElapsed * 2 * .pi / 1.15
            )
            let tiltWave = sin(
                holdElapsed * 2 * .pi / 1.55
            )
            scale = 1 + floatWave * 0.008
            offsetY = -1.5 + floatWave * 1.5
            rotation = tiltWave * 0.008
            opacity = 1
        }

        applyWorkAlertBadgeTransform(
            scale: scale,
            offsetY: offsetY,
            rotation: rotation,
            opacity: opacity
        )
    }

    private func applyWorkAlertBadgeTransform(
        scale: CGFloat,
        offsetY: CGFloat,
        rotation: CGFloat,
        opacity: CGFloat
    ) {
        guard let layer = workAlertImageView?.layer else { return }
        var transform = CGAffineTransform(
            translationX: 0,
            y: offsetY
        )
        transform = transform
            .rotated(by: rotation)
            .scaledBy(x: scale, y: scale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        layer.opacity = Float(min(max(opacity, 0), 1))
        CATransaction.commit()
    }

    private func hideWorkAlertBadge() {
        workAlertBadgeTimer?.invalidate()
        workAlertBadgeTimer = nil
        guard let workAlertImageView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        workAlertImageView.layer?.setAffineTransform(.identity)
        workAlertImageView.layer?.opacity = 1
        CATransaction.commit()
        workAlertImageView.isHidden = true
    }

    private func cancelPerformance() {
        guard performanceState != nil else { return }
        let cancelledCalendarAlert =
            performanceState?.kind == .calendarAlert
        hideWorkAlertBadge()
        performanceState = nil
        if cancelledCalendarAlert {
            pendingWorkAlertTaskMessage = nil
        }
        seatedIdleStartedAt = ProcessInfo.processInfo.systemUptime
        nextIdleActionAt = seatedIdleStartedAt + Double.random(in: 4.0...7.5)
        nextWalkAt = seatedIdleStartedAt + Double.random(in: 7.0...12.0)
        if let origin = window?.frame.origin {
            onPositionChanged?(origin)
        }
    }

    private func movementPlacement(
        maximumDistance: CGFloat
    ) -> (origin: NSPoint, distance: CGFloat, direction: CGFloat) {
        guard let window, let screen = window.screen ?? NSScreen.main else {
            return (.zero, 0, -1)
        }

        let visible = screen.visibleFrame.insetBy(dx: 10, dy: 0)
        let start = window.frame.origin
        let availableLeft = max(0, start.x - visible.minX)
        let availableRight = max(
            0,
            visible.maxX - window.frame.width - start.x
        )
        let direction: CGFloat = availableLeft >= 55 ? -1 : 1
        let available = direction < 0 ? availableLeft : availableRight
        return (start, min(maximumDistance, available), direction)
    }

    private func calendarAlertPlacement() -> (
        start: NSPoint,
        destination: NSPoint,
        direction: CGFloat
    ) {
        guard let window, let screen = window.screen ?? NSScreen.main else {
            return (.zero, .zero, facingDirection)
        }
        let visible = screen.visibleFrame
        let start = window.frame.origin
        let destination = NSPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.midY - window.frame.height / 2
        )
        let direction: CGFloat = destination.x >= start.x ? 1 : -1
        return (start, destination, direction)
    }

    private func updateCursorLean(delta: TimeInterval) {
        guard !reduceMotion,
              taskTimerFrameIndex == nil,
              walkState == nil,
              performanceState == nil,
              feedingStage == nil,
              let window else {
            cursorLean = 0
            return
        }

        let mouse = NSEvent.mouseLocation
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let distance = hypot(mouse.x - center.x, mouse.y - center.y)
        let proximity = max(0, min(1, 1 - distance / 520))
        let horizontal = max(-1, min(1, (mouse.x - center.x) / 260))
        let target = CGFloat(horizontal * proximity)
        let response = CGFloat(min(1, delta * 4.8))
        cursorLean += (target - cursorLean) * response
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            stopTaskTimerAnimation()
            cancelPerformance()
            cancelWalk()
            attentionStartedAt = nil
            quickActionsAnimationStartedAt = nil
            quickActionsProgress = quickActionsVisible ? 1 : 0
            quickActionsAnimationTarget = quickActionsProgress
            applyQuickActionVisuals(progress: quickActionsProgress)
            workAlertStartedAt = nil
            idleAction = nil
            idleActionStartedAt = nil
            eyeLookStartedAt = nil
            spontaneousEyePose = .open
            cursorLean = 0
        } else if taskTimerFrameIndex != nil {
            startTaskTimerAnimation()
        }
        updateCharacter(at: ProcessInfo.processInfo.systemUptime)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if characterView == nil {
            drawFallbackBird()
        }

        if let messageImage {
            drawMessageImage(messageImage)
        } else if let message {
            drawSpeechBubble(message)
        }
    }

    private func updateCharacter(at now: TimeInterval) {
        guard let characterView else { return }
        let motion = motionValues(at: now)
        let rotation = -motion.rotation * .pi / 180
        var transform = CGAffineTransform(
            translationX: motion.offsetX,
            y: -motion.offsetY
        )
        transform = transform
            .rotated(by: rotation)
            .scaledBy(x: motion.scaleX * facingDirection, y: motion.scaleY)
        characterView.applyMotion(transform)
        updateEyes(on: characterView, at: now)
    }

    private func updateEyes(on characterView: CharacterView, at now: TimeInterval) {
        if feedingActionStartedAt != nil {
            characterView.eyePose = .open
            characterView.eyeAmount = 0
            return
        }
        if now < workAlertEyeUntil {
            characterView.eyePose = .up
            characterView.eyeAmount = 1
            return
        }

        let blink = blinkAmount(at: now)
        if blink > 0 {
            characterView.eyePose = .blink
            characterView.eyeAmount = blink
            return
        }

        if walkState != nil || feedingApproachState != nil {
            characterView.eyePose = .open
            characterView.eyeAmount = 0
            return
        }

        if abs(cursorLean) > 0.08 {
            let localLean = cursorLean * facingDirection
            characterView.eyePose = localLean > 0 ? .right : .left
            characterView.eyeAmount = min(abs(cursorLean) * 1.8, 1)
            return
        }

        if let eyeLookStartedAt {
            let progress = min(max((now - eyeLookStartedAt) / 0.9, 0), 1)
            characterView.eyePose = spontaneousEyePose
            characterView.eyeAmount = CGFloat(sin(progress * .pi))
            return
        }

        characterView.eyePose = .open
        characterView.eyeAmount = 0
    }

    private func motionValues(at now: TimeInterval) -> MotionValues {
        guard !reduceMotion else { return .identity }

        if taskTimerFrameIndex != nil {
            return .identity
        }

        if feedingApproachState != nil
            || feedingActionStartedAt != nil
        {
            return .identity
        }

        if let performanceState {
            if performanceState.kind == .calendarAlert {
                return calendarAlertMotionValues(
                    at: now,
                    state: performanceState
                )
            }
            return .identity
        }

        if walkState != nil {
            return .identity
        }

        let elapsed = now - animationStartedAt
        let breathPhase = elapsed * (2 * .pi / 4.2)
        let breath = CGFloat((1 - cos(breathPhase)) * 0.5)
        let sway = CGFloat(sin(elapsed * (2 * .pi / 6.4)))
        let counterSway = CGFloat(sin(elapsed * (2 * .pi / 3.7) + 0.8))

        var values = MotionValues(
            scaleX: 1 - breath * 0.006,
            scaleY: 1 + breath * 0.013,
            offsetX: sway * 0.7 + counterSway * 0.25 + cursorLean * 1.3,
            offsetY: -breath * 1.5,
            rotation: sway * 0.55 + cursorLean * 1.7
        )

        applyIdleAction(to: &values, at: now)
        applyWorkAlert(to: &values, at: now)

        if let attentionStartedAt {
            let reactionElapsed = now - attentionStartedAt
            if reactionElapsed >= 1.05 {
                self.attentionStartedAt = nil
            } else {
                let t = CGFloat(reactionElapsed)
                let decay = exp(-3.8 * t)
                let spring = sin(t * .pi * 6.2) * decay * attentionStrength
                let hopProgress = min(t / 0.68, 1)
                let hop = sin(hopProgress * .pi) * exp(-1.3 * t) * attentionStrength

                values.scaleX += spring * 0.035
                values.scaleY -= spring * 0.025
                values.offsetY -= hop * 18
                values.rotation += spring * 1.2
            }
        }

        return values
    }

    private func calendarAlertMotionValues(
        at now: TimeInterval,
        state: PerformanceState
    ) -> MotionValues {
        let elapsed = CGFloat(max(0, now - state.startedAt))
        let runDuration = CGFloat(PerformanceTiming.calendarRunDuration)
        if elapsed < runDuration {
            let progress = elapsed / runDuration
            let stride = abs(sin(progress * .pi * 6))
            return MotionValues(
                scaleX: 1 + stride * 0.018,
                scaleY: 1 - stride * 0.012,
                offsetX: 0,
                offsetY: -stride * 5,
                rotation: sin(progress * .pi * 6)
                    * 1.4
                    * state.direction
            )
        }

        let popElapsed = elapsed - runDuration
        let callHoldEnd = CGFloat(
            PerformanceTiming.calendarCallLeadDuration
                + PerformanceTiming.calendarCallDuration
        )
        let settleDuration: CGFloat = 1.15
        let scale: CGFloat
        if popElapsed < 0.32 {
            scale = 1 + easedOut(popElapsed / 0.32) * 0.38
        } else if popElapsed < callHoldEnd {
            let hold = (popElapsed - 0.32) / max(callHoldEnd - 0.32, 0.01)
            scale = 1.38 + sin(hold * .pi * 6) * 0.018
        } else if popElapsed < callHoldEnd + settleDuration {
            let settle = (popElapsed - callHoldEnd) / settleDuration
            let spring = sin(settle * .pi * 3)
                * (1 - settle)
                * 0.035
            scale = 1 + (1 - easedOut(settle)) * 0.38 + spring
        } else {
            scale = 1
        }

        let liftEnvelope = max(
            0,
            1 - popElapsed / (callHoldEnd + settleDuration)
        )
        return MotionValues(
            scaleX: scale,
            scaleY: scale,
            offsetX: 0,
            offsetY: -10 * liftEnvelope,
            rotation: 0
        )
    }

    private func applyWorkAlert(to values: inout MotionValues, at now: TimeInterval) {
        guard let workAlertStartedAt else { return }
        let elapsed = CGFloat(now - workAlertStartedAt)
        let duration: CGFloat = 1.3
        if elapsed >= duration {
            self.workAlertStartedAt = nil
            nextIdleActionAt = now + 2.5
            return
        }

        // Fast rise, a short alert hold, then a soft settle. Only transform values
        // change, so the reaction remains smooth even while the window is floating.
        let rise = easedOut(min(max(elapsed / 0.24, 0), 1))
        let settleProgress = min(max((elapsed - 0.72) / 0.58, 0), 1)
        let hold = rise * (1 - easedOut(settleProgress))
        let perk = sin(min(elapsed / 0.5, 1) * .pi) * exp(-2.4 * elapsed)

        values.offsetY -= hold * 10
        values.rotation -= hold * 4.8 * facingDirection
        values.scaleX -= hold * 0.018
        values.scaleY += hold * 0.026
        values.offsetY -= perk * 5
    }

    private func easedOut(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    private func applyIdleAction(to values: inout MotionValues, at now: TimeInterval) {
        guard let idleAction, let idleActionStartedAt else { return }
        let elapsed = CGFloat(now - idleActionStartedAt)
        let progress = min(max(elapsed / CGFloat(idleAction.duration), 0), 1)
        let envelope = sin(progress * .pi)

        switch idleAction {
        case .hop:
            let hops = abs(sin(progress * .pi * 2.15))
            let squash = sin(progress * .pi * 4.3) * envelope
            values.offsetY -= hops * envelope * 9
            values.scaleX += squash * 0.018
            values.scaleY -= squash * 0.013
            values.rotation += sin(progress * .pi * 2) * envelope * 0.8
        case .wiggle:
            let wiggle = sin(progress * .pi * 6) * envelope
            values.offsetX += wiggle * 2.2
            values.rotation += wiggle * 3.2
            values.scaleX += abs(wiggle) * 0.009
            values.scaleY -= abs(wiggle) * 0.006
        case .peek:
            let eased = sin(progress * .pi)
            values.offsetX += eased * 7
            values.offsetY -= eased * 2
            values.rotation -= eased * 2.8
            values.scaleY += eased * 0.009
        }
    }

    private func drawSpeechBubble(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(
                calibratedRed: 0.24,
                green: 0.31,
                blue: 0.18,
                alpha: 1
            ),
            .paragraphStyle: paragraph
        ]

        let horizontalTextPadding: CGFloat = 20
        let maximumBubbleWidth = min(bounds.width - 40, 280)
        let provisionalTextBounds = text.boundingRect(
            with: NSSize(
                width: maximumBubbleWidth
                    - horizontalTextPadding * 2,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let bubbleWidth = min(
            maximumBubbleWidth,
            max(
                190,
                provisionalTextBounds.width
                    + horizontalTextPadding * 2
                    + 4
            )
        )
        let textWidth = bubbleWidth - horizontalTextPadding * 2
        let textBounds = text.boundingRect(
            with: NSSize(
                width: textWidth,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let bubbleHeight = min(110, max(76, textBounds.height + 32))
        let bubbleBottomY = max(
            bubbleHeight + 6,
            characterRect.minY + 48
        )
        let bubbleRect = NSRect(
            x: bounds.midX - bubbleWidth / 2,
            y: bubbleBottomY - bubbleHeight,
            width: bubbleWidth,
            height: bubbleHeight
        )

        let fillColor = NSColor(
            calibratedRed: 0.92,
            green: 0.95,
            blue: 0.84,
            alpha: 0.98
        )
        let borderColor = NSColor(
            calibratedRed: 0.73,
            green: 0.83,
            blue: 0.55,
            alpha: 1
        )
        let bubble = thoughtBubblePath(in: bubbleRect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        fillColor.setFill()
        bubble.fill()
        NSGraphicsContext.restoreGraphicsState()

        borderColor.setStroke()
        bubble.lineWidth = 3.5
        bubble.lineJoinStyle = .round
        bubble.stroke()

        drawThoughtDot(
            center: NSPoint(
                x: bubbleRect.midX - 18,
                y: bubbleRect.maxY + 7
            ),
            radius: 7,
            fillColor: fillColor,
            borderColor: borderColor,
            lineWidth: 2.5
        )
        drawThoughtDot(
            center: NSPoint(
                x: bubbleRect.midX - 4,
                y: bubbleRect.maxY + 18
            ),
            radius: 4,
            fillColor: fillColor,
            borderColor: borderColor,
            lineWidth: 2
        )

        let visibleTextHeight = min(textBounds.height, bubbleHeight - 26)
        let textRect = NSRect(
            x: bubbleRect.minX + horizontalTextPadding,
            y: bubbleRect.midY - visibleTextHeight / 2,
            width: textWidth,
            height: bubbleHeight - 26
        )
        text.draw(
            with: textRect,
            options: [
                .usesLineFragmentOrigin,
                .usesFontLeading,
                .truncatesLastVisibleLine
            ],
            attributes: attributes
        )
    }

    private func drawMessageImage(_ image: NSImage) {
        let side = min(bounds.width - 120, 196)
        let imageRect = NSRect(
            x: bounds.midX - side / 2,
            y: max(4, characterRect.minY - side + 44),
            width: side,
            height: side
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: imageRect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func thoughtBubblePath(in rect: NSRect) -> NSBezierPath {
        let point: (CGFloat, CGFloat) -> NSPoint = {
            NSPoint(
                x: rect.minX + $0 * rect.width,
                y: rect.minY + $1 * rect.height
            )
        }

        let path = NSBezierPath()
        path.move(to: point(0.04, 0.58))
        path.curve(
            to: point(0.10, 0.28),
            controlPoint1: point(0.01, 0.46),
            controlPoint2: point(0.04, 0.34)
        )
        path.curve(
            to: point(0.25, 0.14),
            controlPoint1: point(0.14, 0.17),
            controlPoint2: point(0.20, 0.19)
        )
        path.curve(
            to: point(0.40, 0.08),
            controlPoint1: point(0.30, 0.03),
            controlPoint2: point(0.35, 0.11)
        )
        path.curve(
            to: point(0.56, 0.10),
            controlPoint1: point(0.46, 0.02),
            controlPoint2: point(0.51, 0.04)
        )
        path.curve(
            to: point(0.72, 0.10),
            controlPoint1: point(0.62, 0.02),
            controlPoint2: point(0.67, 0.14)
        )
        path.curve(
            to: point(0.90, 0.22),
            controlPoint1: point(0.80, 0.04),
            controlPoint2: point(0.87, 0.10)
        )
        path.curve(
            to: point(0.97, 0.50),
            controlPoint1: point(0.98, 0.28),
            controlPoint2: point(0.96, 0.40)
        )
        path.curve(
            to: point(0.90, 0.75),
            controlPoint1: point(1.00, 0.61),
            controlPoint2: point(0.96, 0.70)
        )
        path.curve(
            to: point(0.73, 0.86),
            controlPoint1: point(0.87, 0.89),
            controlPoint2: point(0.80, 0.80)
        )
        path.curve(
            to: point(0.56, 0.90),
            controlPoint1: point(0.68, 0.96),
            controlPoint2: point(0.62, 0.87)
        )
        path.curve(
            to: point(0.38, 0.88),
            controlPoint1: point(0.49, 0.97),
            controlPoint2: point(0.44, 0.84)
        )
        path.curve(
            to: point(0.21, 0.87),
            controlPoint1: point(0.32, 0.97),
            controlPoint2: point(0.27, 0.83)
        )
        path.curve(
            to: point(0.07, 0.75),
            controlPoint1: point(0.15, 0.93),
            controlPoint2: point(0.09, 0.85)
        )
        path.curve(
            to: point(0.04, 0.58),
            controlPoint1: point(0.01, 0.71),
            controlPoint2: point(0.02, 0.63)
        )
        path.close()
        return path
    }

    private func drawThoughtDot(
        center: NSPoint,
        radius: CGFloat,
        fillColor: NSColor,
        borderColor: NSColor,
        lineWidth: CGFloat
    ) {
        let dot = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        fillColor.setFill()
        dot.fill()
        borderColor.setStroke()
        dot.lineWidth = lineWidth
        dot.stroke()
    }

    private func drawFallbackBird() {
        let bodyRect = NSRect(x: 54, y: 58, width: 170, height: 190)
        NSColor(calibratedRed: 0.51, green: 0.42, blue: 0.32, alpha: 1).setFill()
        NSBezierPath(ovalIn: bodyRect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard feedingApproachState == nil,
              feedingActionStartedAt == nil else { return }
        cancelPerformance()
        cancelWalk()
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginOnMouseDown = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let mouseDownLocation, let windowOriginOnMouseDown else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(
            x: current.x - mouseDownLocation.x,
            y: current.y - mouseDownLocation.y
        )
        if abs(delta.x) > 2 || abs(delta.y) > 2 {
            if !didDrag {
                setQuickActionsVisible(false)
            }
            didDrag = true
        }
        window.setFrameOrigin(NSPoint(
            x: windowOriginOnMouseDown.x + delta.x,
            y: windowOriginOnMouseDown.y + delta.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag, let origin = window?.frame.origin {
            onPositionChanged?(origin)
        } else if event.clickCount >= 2 {
            startWalkNow()
        } else {
            playAttentionAnimation()
            onTap?()
        }
        mouseDownLocation = nil
        windowOriginOnMouseDown = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(convert(event.locationInWindow, from: nil))
    }
}

private enum EyePose: Hashable {
    case open
    case blink
    case left
    case right
    case up
    case half
}

private final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class CharacterView: NSView {
    private let idleImage: NSImage
    private let eyeImages: [EyePose: NSImage]
    private let naturalWalkFrames: [NSImage]
    private let alternateWalkFrames: [NSImage]
    private let walkFrames: [NSImage]
    private let walkBlinkFrames: [NSImage]
    private let performanceFrames: [NSImage]
    private let feedingFrames: [NSImage]
    private let taskTimerFrames: [NSImage]
    private let contentLayer = CALayer()
    private let baseImageLayer = CALayer()
    private let overlayImageLayer = CALayer()

    var eyePose: EyePose = .open {
        didSet {
            if eyePose != oldValue {
                updateLayerContents()
            }
        }
    }

    var eyeAmount: CGFloat = 0 {
        didSet {
            if abs(eyeAmount - oldValue) > 0.02 {
                updateLayerContents()
            }
        }
    }

    var walkFrameIndex: Int? {
        didSet {
            if walkFrameIndex != oldValue {
                updateLayerContents()
            }
        }
    }

    var naturalWalkFrameIndex: Int? {
        didSet {
            if naturalWalkFrameIndex != oldValue {
                updateLayerContents()
            }
        }
    }

    var alternateWalkFrameIndex: Int? {
        didSet {
            if alternateWalkFrameIndex != oldValue {
                updateLayerContents()
            }
        }
    }

    var performanceFrameIndex: Int? {
        didSet {
            if performanceFrameIndex != oldValue {
                updateLayerContents()
            }
        }
    }

    var feedingFrameIndex: Int? {
        didSet {
            if feedingFrameIndex != oldValue {
                updateLayerContents()
            }
        }
    }

    private var taskTimerFrameIndex: Int?

    func setTaskTimerFrame(
        _ index: Int?,
        animated: Bool
    ) {
        guard index != taskTimerFrameIndex else { return }
        if animated {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.26
            transition.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                1,
                0.36,
                1
            )
            baseImageLayer.add(
                transition,
                forKey: "taskTimerFrame"
            )
        }
        taskTimerFrameIndex = index
        updateLayerContents()
    }

    init(frame: NSRect, idleImage: NSImage, blinkImage: NSImage?) {
        self.idleImage = idleImage
        var eyeImages: [EyePose: NSImage] = [:]
        if let blinkImage {
            eyeImages[.blink] = blinkImage
        }
        eyeImages[.left] = AssetLoader.frame(named: "eye-left.png")
        eyeImages[.right] = AssetLoader.frame(named: "eye-right.png")
        eyeImages[.up] = AssetLoader.frame(named: "eye-up.png")
        eyeImages[.half] = AssetLoader.frame(named: "eye-half.png")
        self.eyeImages = eyeImages
        self.naturalWalkFrames = (1...21).compactMap {
            AssetLoader.frame(
                named: String(format: "natural-walk-%02d.png", $0)
            )
        }
        self.alternateWalkFrames = (1...14).compactMap {
            AssetLoader.frame(
                named: String(format: "alternate-walk-%02d.png", $0)
            )
        }
        self.walkFrames = (1...3).compactMap {
            AssetLoader.frame(named: String(format: "walk-%02d.png", $0))
        }
        self.walkBlinkFrames = (1...3).compactMap {
            AssetLoader.frame(named: String(format: "walk-%02d-blink.png", $0))
        }
        self.performanceFrames = (1...61).compactMap {
            AssetLoader.frame(
                named: String(format: "performance-%03d.png", $0)
            )
        }
        self.feedingFrames = (1...4).compactMap {
            AssetLoader.frame(
                named: String(format: "feed-action-%02d.png", $0)
            )
        }
        self.taskTimerFrames = (1...5).compactMap {
            AssetLoader.frame(
                named: String(format: "task-timer-%02d.png", $0)
            )
        }
        super.init(frame: frame)
        wantsLayer = true
        let containerLayer = CALayer()
        containerLayer.masksToBounds = false
        layer = containerLayer
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentLayer.masksToBounds = false
        containerLayer.addSublayer(contentLayer)
        for imageLayer in [baseImageLayer, overlayImageLayer] {
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.magnificationFilter = .linear
            imageLayer.minificationFilter = .trilinear
            imageLayer.masksToBounds = false
            contentLayer.addSublayer(imageLayer)
        }
        updateLayerContents()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        refreshLayerGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreContents()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func restoreContents() {
        refreshLayerGeometry()
        updateLayerContents()
        layer?.isHidden = false
        layer?.opacity = 1
        contentLayer.isHidden = false
        contentLayer.opacity = 1
    }

    func applyMotion(_ transform: CGAffineTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.setAffineTransform(transform)
        CATransaction.commit()
    }

    private func refreshLayerGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = bounds
        contentLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        baseImageLayer.frame = contentLayer.bounds
        overlayImageLayer.frame = contentLayer.bounds
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        baseImageLayer.contentsScale = scale
        overlayImageLayer.contentsScale = scale
        CATransaction.commit()
    }

    private func updateLayerContents() {
        let feedingIndex = feedingFrameIndex.flatMap {
            feedingFrames.indices.contains($0) ? $0 : nil
        }
        let taskTimerIndex = taskTimerFrameIndex.flatMap {
            taskTimerFrames.indices.contains($0) ? $0 : nil
        }
        let performanceIndex = performanceFrameIndex.flatMap {
            performanceFrames.indices.contains($0) ? $0 : nil
        }
        let naturalWalkIndex = naturalWalkFrameIndex.flatMap {
            naturalWalkFrames.indices.contains($0) ? $0 : nil
        }
        let alternateWalkIndex = alternateWalkFrameIndex.flatMap {
            alternateWalkFrames.indices.contains($0) ? $0 : nil
        }
        let walkIndex = walkFrameIndex.flatMap {
            walkFrames.indices.contains($0) ? $0 : nil
        }
        let baseImage = feedingIndex.map {
            feedingFrames[$0]
        } ?? performanceIndex.map {
            performanceFrames[$0]
        } ?? taskTimerIndex.map {
            taskTimerFrames[$0]
        } ?? naturalWalkIndex.map {
            naturalWalkFrames[$0]
        } ?? alternateWalkIndex.map {
            alternateWalkFrames[$0]
        } ?? walkIndex.map {
            walkFrames[$0]
        } ?? idleImage
        let overlay: NSImage?
        if feedingIndex != nil
            || performanceIndex != nil
            || taskTimerIndex != nil
            || naturalWalkIndex != nil
            || alternateWalkIndex != nil
        {
            overlay = nil
        } else if let walkIndex,
                  eyePose == .blink,
                  walkBlinkFrames.indices.contains(walkIndex) {
            overlay = walkBlinkFrames[walkIndex]
        } else if walkIndex == nil {
            overlay = eyeImages[eyePose]
        } else {
            overlay = nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseImageLayer.contents = cgImage(from: baseImage)
        overlayImageLayer.contents = overlay.flatMap { cgImage(from: $0) }
        overlayImageLayer.opacity = Float(min(max(eyeAmount, 0), 1))
        CATransaction.commit()
    }

    private func cgImage(from image: NSImage) -> CGImage? {
        var imageRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)
    }
}

private struct MotionValues {
    var scaleX: CGFloat
    var scaleY: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat
    var rotation: CGFloat

    static let identity = MotionValues(
        scaleX: 1,
        scaleY: 1,
        offsetX: 0,
        offsetY: 0,
        rotation: 0
    )
}
