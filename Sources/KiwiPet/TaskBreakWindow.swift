import AppKit
import QuartzCore
import WebKit

enum TextEditingShortcut {
    static func action(
        forCharacters characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Selector? {
        let editingModifiers = modifierFlags.intersection(
            [.command, .shift, .option, .control]
        )
        guard editingModifiers == .command else { return nil }

        switch characters?.lowercased() {
        case "x":
            return #selector(NSText.cut(_:))
        case "c":
            return #selector(NSText.copy(_:))
        case "v":
            return #selector(NSText.paste(_:))
        case "a":
            return #selector(NSText.selectAll(_:))
        default:
            return nil
        }
    }

    static func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        for command in [
            ("剪切", #selector(NSText.cut(_:))),
            ("复制", #selector(NSText.copy(_:))),
            ("粘贴", #selector(NSText.paste(_:)))
        ] {
            let item = NSMenuItem(
                title: command.0,
                action: command.1,
                keyEquivalent: ""
            )
            item.target = nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let selectAllItem = NSMenuItem(
            title: "全选",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: ""
        )
        selectAllItem.target = nil
        menu.addItem(selectAllItem)
        return menu
    }
}

final class TextEditingShortcutMonitor {
    private var eventMonitor: Any?

    init(textField: NSTextField) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak textField] event in
            guard let textField,
                  let action = TextEditingShortcut.action(
                      forCharacters: event.charactersIgnoringModifiers,
                      modifierFlags: event.modifierFlags
                  ),
                  let editor = textField.currentEditor(),
                  textField.window?.firstResponder === editor else {
                return event
            }
            return NSApp.sendAction(
                action,
                to: editor,
                from: textField
            ) ? nil : event
        }
    }

    func invalidate() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    deinit {
        invalidate()
    }
}

struct BilibiliVideoChoice: Equatable {
    static let defaultChoice = BilibiliVideoChoice(
        bvid: "BV1hR4y1X7zF",
        page: 1
    )

    let bvid: String
    let page: Int

    init(bvid: String, page: Int = 1) {
        self.bvid = Self.normalizedBVID(bvid)
        self.page = max(1, page)
    }

    init?(input: String) {
        let trimmed = input.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              let match = Self.firstBVID(in: trimmed) else {
            return nil
        }

        let page = Self.pageNumber(in: trimmed) ?? 1
        self.init(bvid: match, page: page)
    }

    var playerURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "player.bilibili.com"
        components.path = "/player.html"
        components.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "p", value: String(page)),
            URLQueryItem(name: "autoplay", value: "0"),
            URLQueryItem(name: "danmaku", value: "0"),
            URLQueryItem(name: "poster", value: "1")
        ]
        return components.url!
    }

    var publicURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.bilibili.com"
        components.path = "/video/\(bvid)/"
        if page > 1 {
            components.queryItems = [
                URLQueryItem(name: "p", value: String(page))
            ]
        }
        return components.url!
    }

    fileprivate var storedValue: String {
        "\(bvid)|\(page)"
    }

    fileprivate init?(storedValue: String) {
        let parts = storedValue.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let rawBVID = parts.first,
              Self.firstBVID(in: String(rawBVID)) != nil else {
            return nil
        }
        let page = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        self.init(bvid: String(rawBVID), page: page)
    }

    private static func firstBVID(in text: String) -> String? {
        let pattern = #"(?i)BV[0-9A-Za-z]{10}"#
        guard let range = text.range(
            of: pattern,
            options: .regularExpression
        ) else {
            return nil
        }
        return normalizedBVID(String(text[range]))
    }

    private static func normalizedBVID(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        return "BV" + value.dropFirst(2)
    }

    private static func pageNumber(in input: String) -> Int? {
        let candidate = input.contains("://")
            ? input
            : "https://www.bilibili.com/\(input)"
        guard let components = URLComponents(string: candidate),
              let rawPage = components.queryItems?.first(
                where: { $0.name.lowercased() == "p" }
              )?.value,
              let page = Int(rawPage),
              page > 0 else {
            return nil
        }
        return page
    }
}

enum BilibiliVideoPreference {
    static let defaultsKey = "taskBreak.bilibiliVideo"

    static func load(
        from defaults: UserDefaults = .standard
    ) -> BilibiliVideoChoice {
        guard let storedValue = defaults.string(forKey: defaultsKey),
              let choice = BilibiliVideoChoice(
                storedValue: storedValue
              ) else {
            return .defaultChoice
        }
        return choice
    }

    static func save(
        _ choice: BilibiliVideoChoice,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(choice.storedValue, forKey: defaultsKey)
    }

    static func reset(
        in defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

enum TaskVideoSource: Int {
    case douyin
    case bilibili

    var title: String {
        switch self {
        case .douyin: return "抖音短视频"
        case .bilibili: return "B站自选视频"
        }
    }

    var url: URL {
        switch self {
        case .douyin:
            // The full Douyin web feed is loaded directly inside Kiwi so the
            // user can swipe/scroll between short videos without opening a
            // separate browser.
            return URL(string: "https://www.douyin.com/?recommend=1")!
        case .bilibili:
            // Use Bilibili's official external player instead of loading the
            // full video page. The full site depends on navigation, login,
            // and page features that are unreliable inside WKWebView.
            return BilibiliVideoPreference.load().playerURL
        }
    }

    var externalURL: URL {
        switch self {
        case .douyin:
            return url
        case .bilibili:
            return BilibiliVideoPreference.load().publicURL
        }
    }

}

enum TaskBreakRecommendation {
    case shortVideos
    case knowledgeVideo

    static func recommendation(
        for taskDuration: TimeInterval
    ) -> TaskBreakRecommendation {
        taskDuration > 10 * 60 ? .knowledgeVideo : .shortVideos
    }

    var title: String {
        switch self {
        case .shortVideos:
            return "任务完成，轻松一下吧"
        case .knowledgeVideo:
            return "任务有点长，换个长视频"
        }
    }

    var suggestion: String {
        switch self {
        case .shortVideos:
            return "Kiwi 已在弹窗里准备好抖音，放松 5～10 分钟吧。"
        case .knowledgeVideo:
            return "处理超过 10 分钟，已自动换成你选择的 B 站视频。"
        }
    }

    var initialSource: TaskVideoSource {
        switch self {
        case .shortVideos: return .douyin
        case .knowledgeVideo: return .bilibili
        }
    }
}

enum TaskBreakActivity: CaseIterable, Equatable {
    case watchVideo
    case nap
    case feedKiwi
    case woodenFish

    var title: String {
        switch self {
        case .watchVideo: return "刷一会儿视频"
        case .nap: return "小眯一会儿"
        case .feedKiwi: return "给 Kiwi 喂点东西"
        case .woodenFish: return "敲一会儿木鱼"
        }
    }

    var instruction: String {
        switch self {
        case .watchVideo:
            return "放松一下，Kiwi 会继续替你盯着任务进度。"
        case .nap:
            return "靠一会儿、闭闭眼；计时动画合拢时再回来看看。"
        case .feedKiwi:
            return "点下面的按钮拿出食物袋，拖动食物让 Kiwi 自己走过去吃。"
        case .woodenFish:
            return "轻轻敲几下，等 Codex 把任务处理完。"
        }
    }

    var actionTitle: String? {
        switch self {
        case .watchVideo: return nil
        case .nap: return "开始小眯"
        case .feedKiwi: return "拿食物喂 Kiwi"
        case .woodenFish: return "敲一下木鱼"
        }
    }

    static func choices(
        excluding activity: TaskBreakActivity?
    ) -> [TaskBreakActivity] {
        allCases.filter { $0 != activity }
    }

    static func random(
        excluding activity: TaskBreakActivity? = nil
    ) -> TaskBreakActivity {
        choices(excluding: activity).randomElement() ?? .watchVideo
    }
}

enum TaskBreakActivitySelection {
    static func initialActivity(
        for recommendation: TaskBreakRecommendation,
        randomActivity: () -> TaskBreakActivity = {
            TaskBreakActivity.random()
        }
    ) -> TaskBreakActivity {
        switch recommendation {
        case .shortVideos:
            return randomActivity()
        case .knowledgeVideo:
            return .watchVideo
        }
    }
}

enum TaskBreakTimerProgress {
    static let cycleDuration: TimeInterval = 2 * 60
    static let animationDuration: TimeInterval = 30
    static let frameCount = 5
    static let frameDuration =
        animationDuration / Double(frameCount)

    static func cycleIndex(for duration: TimeInterval) -> Int {
        Int(max(0, duration) / cycleDuration)
    }

    static func frameIndex(for duration: TimeInterval) -> Int {
        let phase = max(0, duration).truncatingRemainder(
            dividingBy: animationDuration
        )
        return min(frameCount - 1, Int(phase / frameDuration))
    }

    static func nextFrameIndex(after index: Int) -> Int {
        (max(0, index) + 1) % frameCount
    }

    static func remainingSeconds(for duration: TimeInterval) -> Int {
        let phase = max(0, duration).truncatingRemainder(
            dividingBy: cycleDuration
        )
        return max(1, Int(ceil(cycleDuration - phase)))
    }

    static func remainingDescription(
        for duration: TimeInterval
    ) -> String {
        let remaining = remainingSeconds(for: duration)
        return String(
            format: "本轮还剩 %02d:%02d",
            remaining / 60,
            remaining % 60
        )
    }
}

struct TaskBreakResizeEdges: OptionSet {
    let rawValue: Int

    static let left = TaskBreakResizeEdges(rawValue: 1 << 0)
    static let right = TaskBreakResizeEdges(rawValue: 1 << 1)
    static let bottom = TaskBreakResizeEdges(rawValue: 1 << 2)
    static let top = TaskBreakResizeEdges(rawValue: 1 << 3)
}

struct TaskBreakWindowResizeTracker {
    private var startingMouseLocation: NSPoint?
    private var startingWindowFrame: NSRect?
    private var resizeEdges: TaskBreakResizeEdges = []

    mutating func begin(
        mouseLocation: NSPoint,
        windowFrame: NSRect,
        edges: TaskBreakResizeEdges
    ) {
        startingMouseLocation = mouseLocation
        startingWindowFrame = windowFrame
        resizeEdges = edges
    }

    func windowFrame(
        for mouseLocation: NSPoint,
        minimumSize: NSSize
    ) -> NSRect? {
        guard let startingMouseLocation,
              let startingWindowFrame,
              !resizeEdges.isEmpty else {
            return nil
        }
        let deltaX = mouseLocation.x - startingMouseLocation.x
        let deltaY = mouseLocation.y - startingMouseLocation.y

        var minimumX = startingWindowFrame.minX
        var maximumX = startingWindowFrame.maxX
        var minimumY = startingWindowFrame.minY
        var maximumY = startingWindowFrame.maxY

        if resizeEdges.contains(.left) {
            minimumX += deltaX
        }
        if resizeEdges.contains(.right) {
            maximumX += deltaX
        }
        if resizeEdges.contains(.bottom) {
            minimumY += deltaY
        }
        if resizeEdges.contains(.top) {
            maximumY += deltaY
        }

        if maximumX - minimumX < minimumSize.width {
            if resizeEdges.contains(.left) {
                minimumX = maximumX - minimumSize.width
            } else {
                maximumX = minimumX + minimumSize.width
            }
        }
        if maximumY - minimumY < minimumSize.height {
            if resizeEdges.contains(.bottom) {
                minimumY = maximumY - minimumSize.height
            } else {
                maximumY = minimumY + minimumSize.height
            }
        }

        return NSRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    mutating func reset() {
        startingMouseLocation = nil
        startingWindowFrame = nil
        resizeEdges = []
    }
}

final class TaskBreakPanel: NSPanel {
    private var resizeTracker = TaskBreakWindowResizeTracker()
    private var isResizingFromVisibleBorder = false
    var visibleTopBorderInset: CGFloat = 108

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let edges = resizeEdges(for: event)
            guard !edges.isEmpty else {
                super.sendEvent(event)
                return
            }
            isResizingFromVisibleBorder = true
            resizeTracker.begin(
                mouseLocation: NSEvent.mouseLocation,
                windowFrame: frame,
                edges: edges
            )
        case .leftMouseDragged:
            guard isResizingFromVisibleBorder,
                  let resizedFrame = resizeTracker.windowFrame(
                    for: NSEvent.mouseLocation,
                    minimumSize: minimumFrameSize
                  ) else {
                super.sendEvent(event)
                return
            }
            setFrame(resizedFrame, display: true)
        case .leftMouseUp:
            guard isResizingFromVisibleBorder else {
                super.sendEvent(event)
                return
            }
            isResizingFromVisibleBorder = false
            resizeTracker.reset()
            NSCursor.arrow.set()
        case .mouseMoved:
            super.sendEvent(event)
            updateResizeCursor(for: event)
        default:
            super.sendEvent(event)
        }
    }

    static func resizeEdges(
        at point: NSPoint,
        in bounds: NSRect,
        borderWidth: CGFloat = 24,
        visibleTopBorderInset: CGFloat = 108
    ) -> TaskBreakResizeEdges {
        var edges: TaskBreakResizeEdges = []
        if point.x <= bounds.minX + borderWidth {
            edges.insert(.left)
        } else if point.x >= bounds.maxX - borderWidth {
            edges.insert(.right)
        }
        if point.y <= bounds.minY + borderWidth {
            edges.insert(.bottom)
        } else {
            let visibleTopBorderY =
                bounds.maxY - visibleTopBorderInset
            let isNearVisibleTopBorder =
                abs(point.y - visibleTopBorderY)
                    <= borderWidth / 2
            if point.y >= bounds.maxY - borderWidth
                || isNearVisibleTopBorder {
                edges.insert(.top)
            }
        }
        return edges
    }

    private var minimumFrameSize: NSSize {
        frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: contentMinSize
            )
        ).size
    }

    private func resizeEdges(
        for event: NSEvent
    ) -> TaskBreakResizeEdges {
        guard let contentView else { return [] }
        let point = contentView.convert(
            event.locationInWindow,
            from: nil
        )
        return Self.resizeEdges(
            at: point,
            in: contentView.bounds,
            visibleTopBorderInset: visibleTopBorderInset
        )
    }

    private func updateResizeCursor(for event: NSEvent) {
        let edges = resizeEdges(for: event)
        if edges.contains(.top) || edges.contains(.bottom) {
            NSCursor.resizeUpDown.set()
        } else if edges.contains(.left) || edges.contains(.right) {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

private final class TaskBreakBackgroundView: NSView {
    var restoresArrowCursorOnExit = false {
        didSet {
            updateTrackingAreas()
        }
    }
    private var cursorExitTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func updateTrackingAreas() {
        if let cursorExitTrackingArea {
            removeTrackingArea(cursorExitTrackingArea)
        }
        cursorExitTrackingArea = nil

        if restoresArrowCursorOnExit {
            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [
                    .mouseEnteredAndExited,
                    .activeAlways,
                    .inVisibleRect
                ],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            cursorExitTrackingArea = trackingArea
        }
        super.updateTrackingAreas()
    }

    override func mouseExited(with event: NSEvent) {
        if restoresArrowCursorOnExit {
            NSCursor.arrow.set()
        }
        super.mouseExited(with: event)
    }
}

private final class TaskBreakActionButton: NSButton {
    private let titleColor = NSColor.white

    override var title: String {
        didSet {
            applyTitleStyle()
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let textSize = attributedTitle.size()
        return NSSize(
            width: ceil(textSize.width) + 24,
            height: max(30, ceil(textSize.height) + 10)
        )
    }

    func applyDarkStyle(
        fillColor: NSColor,
        font: NSFont
    ) {
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.backgroundColor = fillColor.cgColor
        layer?.cornerRadius = 15
        self.font = font
        applyTitleStyle()
    }

    private func applyTitleStyle() {
        guard let font else { return }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: titleColor,
                .paragraphStyle: paragraphStyle
            ]
        )
    }
}

final class TaskBreakWindowController:
    NSWindowController,
    WKNavigationDelegate,
    WKUIDelegate,
    NSWindowDelegate
{
    private let titleLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let suggestionLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceControl = NSSegmentedControl(
        labels: [
            "抖音",
            "B站"
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let progressIndicator = NSProgressIndicator()
    private let webStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let customizeBilibiliButton = TaskBreakActionButton(
        title: "更换视频",
        target: nil,
        action: nil
    )
    private let reloadButton = TaskBreakActionButton(
        title: "重新加载",
        target: nil,
        action: nil
    )
    private let browserButton = TaskBreakActionButton(
        title: "浏览器打开",
        target: nil,
        action: nil
    )
    private let closeButton = TaskBreakActionButton(
        title: "休息好了",
        target: nil,
        action: nil
    )
    private let activityActionButton = TaskBreakActionButton(
        title: "",
        target: nil,
        action: nil
    )
    private let activityView = NSView()
    private let activityImageView = NSImageView()
    private let woodenFishSceneView = NSView()
    private let woodenFishFrameView = NSImageView()
    private let woodenFishMalletView = NSImageView()
    private let activityTitleLabel = NSTextField(labelWithString: "")
    private let activityInstructionLabel =
        NSTextField(wrappingLabelWithString: "")
    private let activityTimerLabel = NSTextField(labelWithString: "")
    private let activityCountLabel = NSTextField(labelWithString: "")
    private let taskTimerFrames: [NSImage] = (1...5).compactMap {
        AssetLoader.frame(
            named: String(format: "task-timer-%02d.png", $0)
        )
    }
    private let woodenFishFrames: [NSImage] = (1...2).compactMap {
        AssetLoader.frame(
            named: String(format: "wooden-fish-%02d.png", $0)
        )
    }
    private let woodenFishMalletImage = AssetLoader.frame(
        named: "wooden-fish-mallet.png"
    )
    private let webView: WKWebView
    var onRequestFeeding: (() -> Void)?
    private var selectedSource: TaskVideoSource = .douyin
    private var currentActivity: TaskBreakActivity = .watchVideo
    private var currentActivityCycle = -1
    private var currentTimerFrameIndex = -1
    private var woodenFishCount = 0
    private var woodenFishImpactWorkItem: DispatchWorkItem?
    private var woodenFishResetWorkItem: DispatchWorkItem?
    private var napHasStarted = false
    private var napAnimationFrameIndex = 0
    private var napAnimationTimer: Timer?
    private var latestActiveDuration: TimeInterval = 0
    private var isShowingActiveTask = false
    private var knowledgeVideoLocked = false
    private var loadGeneration = 0
    private var hasPlacedWindow = false
    private weak var cardView: NSView?
    private weak var peekImageView: NSImageView?
    private weak var headerStack: NSStackView?
    private weak var headerIcon: NSTextField?
    private weak var buttonStack: NSStackView?
    private weak var videoContainer: NSView?
    private weak var activityTextStack: NSStackView?
    private var activityTextBelowImageConstraint: NSLayoutConstraint?
    private var activityTextBelowWoodenFishConstraint: NSLayoutConstraint?
    private var activityTextCenteredConstraint: NSLayoutConstraint?
    private var cardTopConstraint: NSLayoutConstraint?
    private var peekWidthConstraint: NSLayoutConstraint?
    private var peekHeightConstraint: NSLayoutConstraint?
    private var peekCenterXConstraint: NSLayoutConstraint?
    private var normalHeaderConstraints: [NSLayoutConstraint] = []
    private var compactHeaderConstraints: [NSLayoutConstraint] = []

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.adaptiveVideoScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        webView = WKWebView(frame: .zero, configuration: configuration)

        let panel = TaskBreakPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        panel.contentMinSize = NSSize(width: 300, height: 360)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .alertPanel
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: panel)
        panel.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopNapAnimation()
        woodenFishImpactWorkItem?.cancel()
        woodenFishResetWorkItem?.cancel()
    }

    func show(
        recommendation: TaskBreakRecommendation,
        duration: TimeInterval
    ) {
        stopNapAnimation()
        isShowingActiveTask = true
        latestActiveDuration = duration
        woodenFishCount = 0
        napHasStarted = false
        currentTimerFrameIndex = -1
        knowledgeVideoLocked = recommendation == .knowledgeVideo
        sourceControl.setEnabled(!knowledgeVideoLocked, forSegment: 0)
        durationLabel.stringValue =
            "Codex 本次处理了 \(Self.formatDuration(duration))"

        let activity = TaskBreakActivitySelection.initialActivity(
            for: recommendation
        )
        if knowledgeVideoLocked {
            currentActivity = .watchVideo
            currentActivityCycle = -1
            titleLabel.stringValue = recommendation.title
            suggestionLabel.stringValue = recommendation.suggestion
            select(.bilibili, forceReload: true)
            applyActivityPresentation()
        } else {
            currentActivityCycle = TaskBreakTimerProgress.cycleIndex(
                for: duration
            )
            setActivity(
                activity,
                duration: duration,
                forceReloadVideo: true
            )
            titleLabel.stringValue = "任务完成 · \(activity.title)"
            suggestionLabel.stringValue = activity.instruction
        }
        presentWindow()
    }

    func beginActiveTask(duration: TimeInterval) {
        stopNapAnimation()
        isShowingActiveTask = true
        latestActiveDuration = duration
        woodenFishCount = 0
        napHasStarted = false
        let shouldForceKnowledge = duration > 10 * 60
        knowledgeVideoLocked = shouldForceKnowledge
        sourceControl.setEnabled(!shouldForceKnowledge, forSegment: 0)
        durationLabel.stringValue =
            "Codex 已处理 \(Self.formatDuration(duration)) · 每 5 秒确认一次"
        if shouldForceKnowledge {
            currentActivity = .watchVideo
            currentActivityCycle = TaskBreakTimerProgress.cycleIndex(
                for: duration
            )
            titleLabel.stringValue = "任务超过 10 分钟，切换自选视频"
            suggestionLabel.stringValue =
                "短视频已停止，Kiwi 强制切换到你的 B 站自选视频。"
            select(.bilibili, forceReload: true)
            applyActivityPresentation()
            updateTimerAnimation(duration: duration)
        } else {
            currentActivityCycle = TaskBreakTimerProgress.cycleIndex(
                for: duration
            )
            setActivity(
                .random(),
                duration: duration,
                forceReloadVideo: true
            )
        }
        presentWindow()
    }

    func updateActiveTask(duration: TimeInterval) {
        guard isShowingActiveTask else { return }
        latestActiveDuration = duration
        let recommendation = TaskBreakRecommendation.recommendation(
            for: duration
        )
        durationLabel.stringValue =
            "Codex 已处理 \(Self.formatDuration(duration)) · 每 5 秒确认一次"

        switch recommendation {
        case .shortVideos:
            let cycle = TaskBreakTimerProgress.cycleIndex(
                for: duration
            )
            if cycle != currentActivityCycle {
                currentActivityCycle = cycle
                setActivity(
                    .random(excluding: currentActivity),
                    duration: duration,
                    forceReloadVideo: true
                )
            } else {
                updateActivityCopy(duration: duration)
                updateTimerAnimation(duration: duration)
            }
        case .knowledgeVideo:
            updateTimerAnimation(duration: duration)
            titleLabel.stringValue = "任务超过 10 分钟，换个长视频"
            suggestionLabel.stringValue =
                "短视频已停止，Kiwi 强制切换到你的 B 站自选视频。"
            if !knowledgeVideoLocked {
                knowledgeVideoLocked = true
                currentActivity = .watchVideo
                stopNapAnimation()
                sourceControl.setEnabled(false, forSegment: 0)
                select(.bilibili, forceReload: true)
                applyActivityPresentation()
                // "强制切换" also means bringing the existing popup back if
                // the user closed it during the short-video interval.
                presentWindow()
            }
        }
    }

    func completeActiveTask(duration: TimeInterval) {
        guard isShowingActiveTask else { return }
        stopNapAnimation()
        latestActiveDuration = duration
        isShowingActiveTask = false
        currentTimerFrameIndex = -1
        titleLabel.stringValue = "Codex 已经处理完成"
        durationLabel.stringValue =
            "本次一共处理了 \(Self.formatDuration(duration))"
        if currentActivity == .watchVideo {
            suggestionLabel.stringValue =
                "视频还会留在这个弹窗里；休息好了，点“休息好了”关闭即可。"
        } else {
            suggestionLabel.stringValue =
                "Kiwi 的本轮小任务结束啦；点“休息好了”关闭即可。"
            if currentActivity == .nap {
                showTimerFrame(
                    TaskBreakTimerProgress.frameCount - 1,
                    animated: true
                )
            }
            activityTimerLabel.stringValue = "任务完成"
            activityActionButton.isEnabled = false
            updateResponsiveLayout()
        }
    }

    func configureActivityPreview(
        _ activity: TaskBreakActivity,
        duration: TimeInterval
    ) {
        isShowingActiveTask = true
        currentActivityCycle = TaskBreakTimerProgress.cycleIndex(
            for: duration
        )
        setActivity(
            activity,
            duration: duration,
            forceReloadVideo: false
        )
    }

    func cancelActiveTask() {
        guard isShowingActiveTask else { return }
        stopNapAnimation()
        isShowingActiveTask = false
        knowledgeVideoLocked = false
        currentActivityCycle = -1
        currentTimerFrameIndex = -1
        sourceControl.setEnabled(true, forSegment: 0)
        close()
    }

    private func presentWindow() {
        guard let window else { return }
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_200, height: 800)
        if !hasPlacedWindow {
            window.setContentSize(
                preferredContentSize(
                    for: selectedSource,
                    visibleFrame: visibleFrame
                )
            )
            let topLeft = NSPoint(
                x: visibleFrame.maxX - window.frame.width - 24,
                y: visibleFrame.maxY - 24
            )
            window.setFrameTopLeftPoint(topLeft)
            hasPlacedWindow = true
        }
        updateResponsiveLayout()
        window.contentView?.layoutSubtreeIfNeeded()
        updateWebContentScale()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    override func close() {
        stopNapAnimation()
        resetWoodenFishAnimation()
        loadGeneration += 1
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        NSCursor.arrow.set()
        super.close()
    }

    private func buildContent() {
        guard let window else { return }

        let rootView = TaskBreakBackgroundView()
        rootView.restoresArrowCursorOnExit = true
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        let cardView = TaskBreakBackgroundView()
        cardView.wantsLayer = true
        cardView.layer?.backgroundColor = NSColor(
            calibratedRed: 1.00,
            green: 0.99,
            blue: 0.83,
            alpha: 0.99
        ).cgColor
        cardView.layer?.cornerRadius = 42
        cardView.layer?.borderWidth = 7
        cardView.layer?.borderColor = NSColor(
            calibratedRed: 0.78,
            green: 0.84,
            blue: 0.58,
            alpha: 1
        ).cgColor
        cardView.translatesAutoresizingMaskIntoConstraints = false

        let peekImageView = NSImageView()
        peekImageView.image = AssetLoader.frame(
            named: "task-break-peek.png"
        )
        peekImageView.imageAlignment = .alignCenter
        peekImageView.imageScaling = .scaleProportionallyUpOrDown
        peekImageView.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSTextField(labelWithString: "🥝")
        icon.font = .systemFont(ofSize: 28)
        icon.alignment = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let primaryTextColor = NSColor(
            calibratedRed: 0.23,
            green: 0.20,
            blue: 0.14,
            alpha: 1
        )
        let secondaryTextColor = NSColor(
            calibratedRed: 0.38,
            green: 0.39,
            blue: 0.27,
            alpha: 1
        )

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = primaryTextColor
        durationLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        durationLabel.textColor = secondaryTextColor
        suggestionLabel.font = .systemFont(ofSize: 11.5)
        suggestionLabel.textColor = secondaryTextColor
        suggestionLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(
            views: [titleLabel, durationLabel, suggestionLabel]
        )
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let headerStack = NSStackView(views: [icon, textStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        sourceControl.selectedSegment = 0
        sourceControl.target = self
        sourceControl.action = #selector(changeSource)
        sourceControl.segmentStyle = .capsule
        sourceControl.controlSize = .large
        sourceControl.font = .systemFont(ofSize: 12, weight: .semibold)
        sourceControl.selectedSegmentBezelColor = NSColor(
            calibratedRed: 0.66,
            green: 0.75,
            blue: 0.43,
            alpha: 1
        )
        sourceControl.translatesAutoresizingMaskIntoConstraints = false

        let videoContainer = NSView()
        videoContainer.wantsLayer = true
        videoContainer.layer?.backgroundColor = NSColor.white.cgColor
        videoContainer.layer?.cornerRadius = 28
        videoContainer.layer?.masksToBounds = true
        videoContainer.translatesAutoresizingMaskIntoConstraints = false

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsMagnification = true
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        webView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        webView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .vertical
        )

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        webStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        webStatusLabel.alignment = .center
        webStatusLabel.textColor = secondaryTextColor
        webStatusLabel.maximumNumberOfLines = 3
        webStatusLabel.isHidden = true
        webStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        activityView.wantsLayer = true
        activityView.layer?.backgroundColor = NSColor.white.cgColor
        activityView.translatesAutoresizingMaskIntoConstraints = false
        activityView.isHidden = true

        activityImageView.image = taskTimerFrames.first
        activityImageView.imageAlignment = .alignCenter
        activityImageView.imageScaling = .scaleProportionallyUpOrDown
        activityImageView.wantsLayer = true
        activityImageView.translatesAutoresizingMaskIntoConstraints = false
        activityImageView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        activityImageView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .vertical
        )

        woodenFishSceneView.wantsLayer = true
        woodenFishSceneView.translatesAutoresizingMaskIntoConstraints = false
        woodenFishSceneView.isHidden = true

        woodenFishFrameView.image = woodenFishFrames.first
        woodenFishFrameView.imageAlignment = .alignCenter
        woodenFishFrameView.imageScaling = .scaleProportionallyUpOrDown
        woodenFishFrameView.wantsLayer = true
        woodenFishFrameView.identifier = NSUserInterfaceItemIdentifier(
            "woodenFishFrame"
        )
        woodenFishFrameView.translatesAutoresizingMaskIntoConstraints = false

        woodenFishMalletView.image = woodenFishMalletImage
        woodenFishMalletView.imageAlignment = .alignCenter
        woodenFishMalletView.imageScaling = .scaleProportionallyUpOrDown
        woodenFishMalletView.wantsLayer = true
        woodenFishMalletView.identifier = NSUserInterfaceItemIdentifier(
            "woodenFishMallet"
        )
        woodenFishMalletView.translatesAutoresizingMaskIntoConstraints = false

        activityTitleLabel.font = .systemFont(
            ofSize: 17,
            weight: .semibold
        )
        activityTitleLabel.textColor = primaryTextColor
        activityTitleLabel.alignment = .center
        activityInstructionLabel.font = .systemFont(ofSize: 12)
        activityInstructionLabel.textColor = secondaryTextColor
        activityInstructionLabel.alignment = .center
        activityInstructionLabel.maximumNumberOfLines = 2
        activityTimerLabel.font = .monospacedDigitSystemFont(
            ofSize: 14,
            weight: .semibold
        )
        activityTimerLabel.textColor = primaryTextColor
        activityTimerLabel.alignment = .center
        activityCountLabel.font = .systemFont(
            ofSize: 12,
            weight: .semibold
        )
        activityCountLabel.textColor = NSColor(
            calibratedRed: 0.46,
            green: 0.58,
            blue: 0.20,
            alpha: 1
        )
        activityCountLabel.alignment = .center
        activityCountLabel.isHidden = true

        let activityTextStack = NSStackView(
            views: [
                activityTitleLabel,
                activityInstructionLabel,
                activityTimerLabel,
                activityCountLabel
            ]
        )
        activityTextStack.orientation = .vertical
        activityTextStack.alignment = .centerX
        activityTextStack.spacing = 4
        activityTextStack.translatesAutoresizingMaskIntoConstraints = false

        reloadButton.target = self
        reloadButton.action = #selector(reloadVideo)
        browserButton.target = self
        browserButton.action = #selector(openCurrentVideoInBrowser)
        customizeBilibiliButton.target = self
        customizeBilibiliButton.action = #selector(customizeBilibiliVideo)
        customizeBilibiliButton.isHidden = true
        activityActionButton.target = self
        activityActionButton.action = #selector(performCurrentActivity)
        activityActionButton.isHidden = true

        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.keyEquivalent = "\r"

        let actionButtonColor = NSColor(
            calibratedRed: 0.27,
            green: 0.34,
            blue: 0.16,
            alpha: 1
        )
        for button in [
            reloadButton,
            customizeBilibiliButton,
            browserButton,
            activityActionButton
        ] {
            button.controlSize = .large
            button.applyDarkStyle(
                fillColor: actionButtonColor,
                font: .systemFont(ofSize: 12, weight: .semibold)
            )
        }
        closeButton.controlSize = .large
        closeButton.applyDarkStyle(
            fillColor: actionButtonColor,
            font: .systemFont(ofSize: 12, weight: .semibold)
        )

        let buttonStack = NSStackView(
            views: [
                reloadButton,
                customizeBilibiliButton,
                browserButton,
                activityActionButton,
                closeButton
            ]
        )
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.detachesHiddenViews = true
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        self.cardView = cardView
        self.peekImageView = peekImageView
        self.headerStack = headerStack
        self.headerIcon = icon
        self.buttonStack = buttonStack
        self.videoContainer = videoContainer
        self.activityTextStack = activityTextStack

        rootView.addSubview(peekImageView)
        rootView.addSubview(cardView)
        cardView.addSubview(headerStack)
        cardView.addSubview(sourceControl)
        cardView.addSubview(videoContainer)
        cardView.addSubview(buttonStack)
        videoContainer.addSubview(webView)
        videoContainer.addSubview(progressIndicator)
        videoContainer.addSubview(webStatusLabel)
        videoContainer.addSubview(activityView)
        activityView.addSubview(activityImageView)
        activityView.addSubview(woodenFishSceneView)
        woodenFishSceneView.addSubview(woodenFishFrameView)
        woodenFishSceneView.addSubview(woodenFishMalletView)
        activityView.addSubview(activityTextStack)
        window.contentView = rootView

        let cardTopConstraint = cardView.topAnchor.constraint(
            equalTo: rootView.topAnchor,
            constant: 108
        )
        self.cardTopConstraint = cardTopConstraint
        let peekWidthConstraint = peekImageView.widthAnchor.constraint(
            equalToConstant: 210
        )
        let peekHeightConstraint = peekImageView.heightAnchor.constraint(
            equalToConstant: 108
        )
        let peekCenterXConstraint = peekImageView.centerXAnchor.constraint(
            equalTo: cardView.centerXAnchor,
            constant: 66
        )
        self.peekWidthConstraint = peekWidthConstraint
        self.peekHeightConstraint = peekHeightConstraint
        self.peekCenterXConstraint = peekCenterXConstraint
        let preferredActivityImageWidth =
            activityImageView.widthAnchor.constraint(
                equalTo: activityView.widthAnchor,
                multiplier: 0.46
            )
        preferredActivityImageWidth.priority = .defaultHigh
        let minimumActivityImageWidth =
            activityImageView.widthAnchor.constraint(
                greaterThanOrEqualToConstant: 56
            )
        minimumActivityImageWidth.priority = .defaultHigh
        let preferredWoodenFishWidth =
            woodenFishSceneView.widthAnchor.constraint(
                equalTo: activityView.widthAnchor,
                multiplier: 0.80
            )
        preferredWoodenFishWidth.priority = .defaultHigh
        let activityTextBelowImageConstraint =
            activityTextStack.topAnchor.constraint(
                equalTo: activityImageView.bottomAnchor,
                constant: 4
            )
        let activityTextBelowWoodenFishConstraint =
            activityTextStack.topAnchor.constraint(
                equalTo: woodenFishSceneView.bottomAnchor,
                constant: 2
            )
        let activityTextCenteredConstraint =
            activityTextStack.centerYAnchor.constraint(
                equalTo: activityView.centerYAnchor
            )
        self.activityTextBelowImageConstraint =
            activityTextBelowImageConstraint
        self.activityTextBelowWoodenFishConstraint =
            activityTextBelowWoodenFishConstraint
        self.activityTextCenteredConstraint =
            activityTextCenteredConstraint
        normalHeaderConstraints = [
            headerStack.leadingAnchor.constraint(
                equalTo: cardView.leadingAnchor,
                constant: 28
            ),
            headerStack.trailingAnchor.constraint(
                lessThanOrEqualTo: sourceControl.leadingAnchor,
                constant: -12
            ),
            headerStack.topAnchor.constraint(
                equalTo: cardView.topAnchor,
                constant: 24
            ),
            sourceControl.topAnchor.constraint(
                equalTo: cardView.topAnchor,
                constant: 24
            ),
            sourceControl.trailingAnchor.constraint(
                equalTo: cardView.trailingAnchor,
                constant: -28
            )
        ]
        compactHeaderConstraints = [
            sourceControl.topAnchor.constraint(
                equalTo: cardView.topAnchor,
                constant: 16
            ),
            sourceControl.centerXAnchor.constraint(
                equalTo: cardView.centerXAnchor
            ),
            headerStack.leadingAnchor.constraint(
                equalTo: cardView.leadingAnchor,
                constant: 18
            ),
            headerStack.trailingAnchor.constraint(
                equalTo: cardView.trailingAnchor,
                constant: -18
            ),
            headerStack.topAnchor.constraint(
                equalTo: sourceControl.bottomAnchor,
                constant: 8
            )
        ]
        NSLayoutConstraint.activate(normalHeaderConstraints)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(
                equalTo: rootView.leadingAnchor,
                constant: 14
            ),
            cardView.trailingAnchor.constraint(
                equalTo: rootView.trailingAnchor,
                constant: -14
            ),
            cardTopConstraint,
            cardView.bottomAnchor.constraint(
                equalTo: rootView.bottomAnchor,
                constant: -14
            ),

            peekWidthConstraint,
            peekHeightConstraint,
            peekCenterXConstraint,
            peekImageView.bottomAnchor.constraint(
                equalTo: cardView.topAnchor,
                constant: 8
            ),

            sourceControl.widthAnchor.constraint(
                equalToConstant: 132
            ),
            sourceControl.heightAnchor.constraint(
                equalToConstant: 32
            ),

            videoContainer.leadingAnchor.constraint(
                equalTo: cardView.leadingAnchor,
                constant: 24
            ),
            videoContainer.trailingAnchor.constraint(
                equalTo: cardView.trailingAnchor,
                constant: -24
            ),
            videoContainer.topAnchor.constraint(
                equalTo: headerStack.bottomAnchor,
                constant: 16
            ),
            videoContainer.topAnchor.constraint(
                greaterThanOrEqualTo: sourceControl.bottomAnchor,
                constant: 16
            ),
            videoContainer.bottomAnchor.constraint(
                equalTo: buttonStack.topAnchor,
                constant: -16
            ),
            videoContainer.heightAnchor.constraint(
                greaterThanOrEqualToConstant: 100
            ),

            webView.leadingAnchor.constraint(
                equalTo: videoContainer.leadingAnchor
            ),
            webView.trailingAnchor.constraint(
                equalTo: videoContainer.trailingAnchor
            ),
            webView.topAnchor.constraint(
                equalTo: videoContainer.topAnchor
            ),
            webView.bottomAnchor.constraint(
                equalTo: videoContainer.bottomAnchor
            ),

            activityView.leadingAnchor.constraint(
                equalTo: videoContainer.leadingAnchor
            ),
            activityView.trailingAnchor.constraint(
                equalTo: videoContainer.trailingAnchor
            ),
            activityView.topAnchor.constraint(
                equalTo: videoContainer.topAnchor
            ),
            activityView.bottomAnchor.constraint(
                equalTo: videoContainer.bottomAnchor
            ),
            activityImageView.centerXAnchor.constraint(
                equalTo: activityView.centerXAnchor
            ),
            activityImageView.topAnchor.constraint(
                equalTo: activityView.topAnchor,
                constant: 8
            ),
            preferredActivityImageWidth,
            minimumActivityImageWidth,
            activityImageView.widthAnchor.constraint(
                lessThanOrEqualToConstant: 280
            ),
            activityImageView.heightAnchor.constraint(
                equalTo: activityImageView.widthAnchor,
                multiplier: 720.0 / 563.0
            ),
            activityImageView.heightAnchor.constraint(
                lessThanOrEqualTo: activityView.heightAnchor,
                constant: -52
            ),
            activityTextBelowImageConstraint,

            woodenFishSceneView.centerXAnchor.constraint(
                equalTo: activityView.centerXAnchor
            ),
            woodenFishSceneView.topAnchor.constraint(
                equalTo: activityView.topAnchor,
                constant: 6
            ),
            preferredWoodenFishWidth,
            woodenFishSceneView.widthAnchor.constraint(
                lessThanOrEqualToConstant: 340
            ),
            woodenFishSceneView.heightAnchor.constraint(
                equalTo: woodenFishSceneView.widthAnchor,
                multiplier: 898.0 / 1352.0
            ),
            woodenFishSceneView.heightAnchor.constraint(
                lessThanOrEqualTo: activityView.heightAnchor,
                constant: -48
            ),
            woodenFishFrameView.leadingAnchor.constraint(
                equalTo: woodenFishSceneView.leadingAnchor
            ),
            woodenFishFrameView.trailingAnchor.constraint(
                equalTo: woodenFishSceneView.trailingAnchor
            ),
            woodenFishFrameView.topAnchor.constraint(
                equalTo: woodenFishSceneView.topAnchor
            ),
            woodenFishFrameView.bottomAnchor.constraint(
                equalTo: woodenFishSceneView.bottomAnchor
            ),
            woodenFishMalletView.widthAnchor.constraint(
                equalTo: woodenFishSceneView.widthAnchor,
                multiplier: 0.30
            ),
            woodenFishMalletView.heightAnchor.constraint(
                equalTo: woodenFishMalletView.widthAnchor,
                multiplier: 850.0 / 685.0
            ),
            woodenFishMalletView.trailingAnchor.constraint(
                equalTo: woodenFishSceneView.trailingAnchor,
                constant: -4
            ),
            woodenFishMalletView.topAnchor.constraint(
                equalTo: woodenFishSceneView.topAnchor,
                constant: 1
            ),

            activityTextStack.leadingAnchor.constraint(
                equalTo: activityView.leadingAnchor,
                constant: 12
            ),
            activityTextStack.trailingAnchor.constraint(
                equalTo: activityView.trailingAnchor,
                constant: -12
            ),
            activityTextStack.bottomAnchor.constraint(
                lessThanOrEqualTo: activityView.bottomAnchor,
                constant: -8
            ),

            progressIndicator.centerXAnchor.constraint(
                equalTo: videoContainer.centerXAnchor
            ),
            progressIndicator.centerYAnchor.constraint(
                equalTo: videoContainer.centerYAnchor
            ),

            webStatusLabel.centerXAnchor.constraint(
                equalTo: videoContainer.centerXAnchor
            ),
            webStatusLabel.centerYAnchor.constraint(
                equalTo: videoContainer.centerYAnchor
            ),
            webStatusLabel.widthAnchor.constraint(
                lessThanOrEqualTo: videoContainer.widthAnchor,
                constant: -60
            ),

            buttonStack.trailingAnchor.constraint(
                equalTo: cardView.trailingAnchor,
                constant: -24
            ),
            buttonStack.bottomAnchor.constraint(
                equalTo: cardView.bottomAnchor,
                constant: -20
            ),
            buttonStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: cardView.leadingAnchor,
                constant: 24
            ),
            buttonStack.heightAnchor.constraint(
                greaterThanOrEqualToConstant: 30
            )
        ])
        updateResponsiveLayout()
    }

    private func setActivity(
        _ activity: TaskBreakActivity,
        duration: TimeInterval,
        forceReloadVideo: Bool = false
    ) {
        stopNapAnimation()
        resetWoodenFishAnimation()
        latestActiveDuration = duration
        currentActivity = activity
        currentTimerFrameIndex = -1
        napHasStarted = false
        activityActionButton.isEnabled = true

        if activity == .watchVideo {
            select(.douyin, forceReload: forceReloadVideo)
        } else {
            loadGeneration += 1
            webView.stopLoading()
            webView.evaluateJavaScript(
                """
                document.querySelectorAll("video, audio").forEach(
                  media => media.pause()
                );
                """,
                completionHandler: nil
            )
            progressIndicator.stopAnimation(nil)
            hideWebStatus()
        }

        updateActivityCopy(duration: duration)
        applyActivityPresentation()
        if activity == .nap {
            startNapAnimation()
        }
        updateTimerAnimation(duration: duration)
    }

    private func applyActivityPresentation() {
        let showsVideo = currentActivity == .watchVideo
        webView.isHidden = !showsVideo
        activityView.isHidden = showsVideo
        let showsNapAnimation = currentActivity == .nap
        let showsWoodenFishAnimation = currentActivity == .woodenFish
        activityImageView.isHidden = !showsNapAnimation
        woodenFishSceneView.isHidden = !showsWoodenFishAnimation
        activityTextBelowImageConstraint?.isActive = false
        activityTextBelowWoodenFishConstraint?.isActive = false
        activityTextCenteredConstraint?.isActive = false
        activityTextBelowImageConstraint?.isActive = showsNapAnimation
        activityTextBelowWoodenFishConstraint?.isActive =
            showsWoodenFishAnimation
        activityTextCenteredConstraint?.isActive =
            !showsVideo
                && !showsNapAnimation
                && !showsWoodenFishAnimation
        if !showsVideo {
            progressIndicator.stopAnimation(nil)
            hideWebStatus()
        }
        updateResponsiveLayout()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func updateActivityCopy(duration: TimeInterval) {
        latestActiveDuration = duration

        if currentActivity == .watchVideo {
            if !knowledgeVideoLocked {
                titleLabel.stringValue = "Codex 正在处理 · 刷一会儿视频"
                suggestionLabel.stringValue = currentActivity.instruction
            }
            activityCountLabel.isHidden = true
            return
        }

        titleLabel.stringValue =
            duration >= 5 * 60
                ? "任务还在处理 · \(currentActivity.title)"
                : "Codex 正在处理 · \(currentActivity.title)"
        suggestionLabel.stringValue = currentActivity.instruction
        activityTitleLabel.stringValue = currentActivity.title
        activityInstructionLabel.stringValue = currentActivity.instruction
        activityActionButton.title =
            currentActivity.actionTitle ?? "开始"

        switch currentActivity {
        case .nap where napHasStarted:
            activityInstructionLabel.stringValue = "嘘……安静休息中。"
            activityActionButton.title = "正在小眯"
            activityActionButton.isEnabled = false
        case .woodenFish where woodenFishCount > 0:
            activityCountLabel.stringValue = "功德 +\(woodenFishCount)"
            activityCountLabel.isHidden = false
        default:
            activityCountLabel.stringValue = ""
            activityCountLabel.isHidden = true
        }
    }

    private func updateTimerAnimation(duration: TimeInterval) {
        guard currentActivity != .watchVideo else { return }
        activityTimerLabel.stringValue =
            TaskBreakTimerProgress.remainingDescription(for: duration)
    }

    private func startNapAnimation() {
        stopNapAnimation()
        guard currentActivity == .nap, !taskTimerFrames.isEmpty else {
            return
        }

        napAnimationFrameIndex = 0
        currentTimerFrameIndex = -1
        showTimerFrame(napAnimationFrameIndex, animated: false)

        let timer = Timer(
            timeInterval: TaskBreakTimerProgress.frameDuration,
            repeats: true
        ) { [weak self] timer in
            guard let self,
                  self.isShowingActiveTask,
                  self.currentActivity == .nap else {
                timer.invalidate()
                return
            }
            guard self.window?.isVisible != false else { return }

            self.napAnimationFrameIndex =
                TaskBreakTimerProgress.nextFrameIndex(
                    after: self.napAnimationFrameIndex
                )
            self.showTimerFrame(
                self.napAnimationFrameIndex,
                animated: true
            )
        }
        timer.tolerance = 0.15
        napAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopNapAnimation() {
        napAnimationTimer?.invalidate()
        napAnimationTimer = nil
    }

    private func showTimerFrame(
        _ index: Int,
        animated: Bool
    ) {
        guard !taskTimerFrames.isEmpty else { return }
        let safeIndex = min(
            max(0, index),
            taskTimerFrames.count - 1
        )
        guard safeIndex != currentTimerFrameIndex else { return }

        let shouldAnimate =
            animated
                && currentTimerFrameIndex >= 0
                && !NSWorkspace.shared
                    .accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.26
            transition.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                1,
                0.36,
                1
            )
            activityImageView.layer?.add(
                transition,
                forKey: "taskTimerFrame"
            )
        }

        activityImageView.image = taskTimerFrames[safeIndex]
        currentTimerFrameIndex = safeIndex
    }

    @objc private func performCurrentActivity() {
        guard isShowingActiveTask, !knowledgeVideoLocked else { return }

        switch currentActivity {
        case .watchVideo:
            break
        case .nap:
            napHasStarted = true
            updateActivityCopy(duration: latestActiveDuration)
        case .feedKiwi:
            onRequestFeeding?()
            activityInstructionLabel.stringValue =
                "食物袋已经拿出来了，拖动食物放好，Kiwi 会自己走过去吃。"
            activityActionButton.title = "再拿一袋"
        case .woodenFish:
            woodenFishCount += 1
            updateActivityCopy(duration: latestActiveDuration)
            animateWoodenFishTap()
        }
        updateResponsiveLayout()
    }

    private func animateWoodenFishTap() {
        guard woodenFishFrames.count >= 2 else { return }
        woodenFishImpactWorkItem?.cancel()
        woodenFishResetWorkItem?.cancel()
        woodenFishFrameView.image = woodenFishFrames.first

        let reducesMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let impactDelay: TimeInterval = reducesMotion ? 0 : 0.11
        let impactWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.currentActivity == .woodenFish else {
                return
            }
            self.woodenFishFrameView.image =
                self.woodenFishFrames[1]
            NSSound(named: "Tink")?.play()
        }
        woodenFishImpactWorkItem = impactWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + impactDelay,
            execute: impactWorkItem
        )

        let resetWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.woodenFishFrameView.image =
                self.woodenFishFrames.first
        }
        woodenFishResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (reducesMotion ? 0.24 : 0.32),
            execute: resetWorkItem
        )

        guard !reducesMotion else { return }

        let bodyAnimation = CAKeyframeAnimation(
            keyPath: "transform.scale"
        )
        bodyAnimation.values = [1, 0.97, 1.025, 1]
        bodyAnimation.keyTimes = [0, 0.36, 0.72, 1]
        bodyAnimation.duration = 0.32
        bodyAnimation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        woodenFishFrameView.layer?.add(
            bodyAnimation,
            forKey: "woodenFishTap"
        )

        let rotation = CAKeyframeAnimation(
            keyPath: "transform.rotation.z"
        )
        rotation.values = [0, -0.34, 0.10, 0]
        rotation.keyTimes = [0, 0.36, 0.72, 1]

        let sceneWidth = woodenFishSceneView.bounds.width
        let impactX = -max(30, min(66, sceneWidth * 0.21))
        let impactY = -max(18, min(42, sceneWidth * 0.13))

        let horizontal = CAKeyframeAnimation(
            keyPath: "transform.translation.x"
        )
        horizontal.values = [0, impactX, impactX * 0.30, 0]
        horizontal.keyTimes = rotation.keyTimes

        let vertical = CAKeyframeAnimation(
            keyPath: "transform.translation.y"
        )
        vertical.values = [0, impactY, impactY * 0.30, 0]
        vertical.keyTimes = rotation.keyTimes

        let malletAnimation = CAAnimationGroup()
        malletAnimation.animations = [rotation, horizontal, vertical]
        malletAnimation.duration = 0.32
        malletAnimation.timingFunction = CAMediaTimingFunction(
            name: .easeInEaseOut
        )
        woodenFishMalletView.layer?.add(
            malletAnimation,
            forKey: "woodenFishMalletTap"
        )
    }

    private func resetWoodenFishAnimation() {
        woodenFishImpactWorkItem?.cancel()
        woodenFishImpactWorkItem = nil
        woodenFishResetWorkItem?.cancel()
        woodenFishResetWorkItem = nil
        woodenFishFrameView.image = woodenFishFrames.first
        woodenFishFrameView.layer?.removeAnimation(
            forKey: "woodenFishTap"
        )
        woodenFishMalletView.layer?.removeAnimation(
            forKey: "woodenFishMalletTap"
        )
    }

    private func select(
        _ source: TaskVideoSource,
        forceReload: Bool = false
    ) {
        let shouldReload =
            forceReload || selectedSource != source || webView.url == nil
        sourceControl.selectedSegment = source.rawValue
        selectedSource = source
        updateResponsiveLayout()
        guard shouldReload else {
            updateWebContentScale()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        webView.stopLoading()
        hideWebStatus()
        progressIndicator.startAnimation(nil)
        var request = URLRequest(
            url: source.url,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 30
        )
        request.setValue(
            "zh-CN,zh;q=0.9,en;q=0.7",
            forHTTPHeaderField: "Accept-Language"
        )
        if source == .bilibili {
            request.setValue(
                "https://www.bilibili.com/",
                forHTTPHeaderField: "Referer"
            )
        }
        webView.load(request)
        schedulePlayerVerification(
            for: source,
            generation: generation
        )
    }

    private func updateResponsiveLayout() {
        guard let window else { return }
        let contentSize = window.contentRect(
            forFrameRect: window.frame
        ).size
        let usesCompactHeader = contentSize.width < 430
        let usesCompactHeight = contentSize.height < 560
        let usesCompactPresentation =
            usesCompactHeader || usesCompactHeight

        if usesCompactHeader {
            NSLayoutConstraint.deactivate(normalHeaderConstraints)
            NSLayoutConstraint.activate(compactHeaderConstraints)
        } else {
            NSLayoutConstraint.deactivate(compactHeaderConstraints)
            NSLayoutConstraint.activate(normalHeaderConstraints)
        }

        // Keep Kiwi visible and proportional as the popup becomes shorter.
        // It can shrink to 65%, but never grows beyond the authored image.
        let widthScale = (contentSize.width - 70) / 210
        let heightScale = (contentSize.height - 280) / 140
        let kiwiScale = max(
            0.65,
            min(1, min(widthScale, heightScale))
        )
        let kiwiWidth = 210 * kiwiScale
        let kiwiHeight = 108 * kiwiScale
        peekWidthConstraint?.constant = kiwiWidth
        peekHeightConstraint?.constant = kiwiHeight

        // Move the character toward the center on narrow windows so its
        // authored right-side pose is not clipped.
        let maximumCenterOffset = max(
            0,
            (contentSize.width - kiwiWidth) / 2 - 8
        )
        peekCenterXConstraint?.constant = min(
            66 * kiwiScale,
            maximumCenterOffset
        )

        let cardTopInset = kiwiHeight
        cardTopConstraint?.constant = cardTopInset
        (window as? TaskBreakPanel)?.visibleTopBorderInset =
            cardTopInset
        peekImageView?.isHidden = false
        headerIcon?.isHidden = usesCompactPresentation
        titleLabel.isHidden = usesCompactPresentation
        suggestionLabel.isHidden = usesCompactPresentation

        let showsVideo = currentActivity == .watchVideo
        sourceControl.isHidden = !showsVideo
        reloadButton.isHidden = !showsVideo
        webView.isHidden = !showsVideo
        activityView.isHidden = showsVideo
        activityActionButton.isHidden =
            showsVideo || !activityActionButton.isEnabled
        activityTitleLabel.isHidden = usesCompactPresentation
        activityInstructionLabel.isHidden = usesCompactPresentation
        activityCountLabel.isHidden =
            usesCompactPresentation
                || currentActivity != .woodenFish
                || woodenFishCount == 0

        sourceControl.controlSize =
            usesCompactPresentation ? .regular : .large
        sourceControl.font = .systemFont(
            ofSize: usesCompactPresentation ? 11 : 12,
            weight: .semibold
        )

        browserButton.isHidden = !showsVideo || usesCompactHeader
        customizeBilibiliButton.isHidden =
            !showsVideo
                || selectedSource != .bilibili
                || usesCompactHeader
        buttonStack?.spacing = usesCompactHeader ? 6 : 8

        for button in [
            reloadButton,
            customizeBilibiliButton,
            browserButton,
            activityActionButton,
            closeButton
        ] {
            button.controlSize =
                usesCompactPresentation ? .regular : .large
        }
        cardView?.layer?.cornerRadius =
            usesCompactPresentation ? 26 : 42
        cardView?.layer?.borderWidth =
            usesCompactPresentation ? 5 : 7
    }

    private func preferredContentSize(
        for source: TaskVideoSource,
        visibleFrame: NSRect
    ) -> NSSize {
        let maximumWidth = max(420, visibleFrame.width - 48)
        let maximumHeight = max(520, visibleFrame.height - 48)

        switch source {
        case .douyin:
            // Keep enough vertical room for a 9:16 feed while adapting to
            // both laptop screens and large external displays.
            let width = min(
                maximumWidth,
                max(460, min(620, visibleFrame.width * 0.36))
            )
            let height = min(
                maximumHeight,
                max(600, min(860, visibleFrame.height * 0.82))
            )
            return NSSize(width: width, height: height)
        case .bilibili:
            // Long-form Bilibili video benefits from a wider 16:9 viewport.
            let width = min(
                maximumWidth,
                max(620, min(960, visibleFrame.width * 0.64))
            )
            let height = min(
                maximumHeight,
                max(560, min(780, width * 9 / 16 + 190))
            )
            return NSSize(width: width, height: height)
        }
    }

    private func updateWebContentScale() {
        let availableWidth = max(1, webView.bounds.width)
        let availableHeight = max(1, webView.bounds.height)
        if selectedSource == .bilibili {
            webView.pageZoom = 1
        } else {
            let referenceWidth: CGFloat = 760
            let referenceHeight: CGFloat = 680
            webView.pageZoom = min(
                1,
                max(
                    0.30,
                    min(
                        availableWidth / referenceWidth,
                        availableHeight / referenceHeight
                    )
                )
            )
        }
        webView.evaluateJavaScript(
            """
            window.__kiwiResponsiveFit?.();
            window.dispatchEvent(new Event('resize'));
            """,
            completionHandler: nil
        )
    }

    func windowDidResize(_ notification: Notification) {
        updateResponsiveLayout()
        window?.contentView?.layoutSubtreeIfNeeded()
        updateWebContentScale()
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        let minutes = value / 60
        let remainder = value % 60
        if minutes > 0 {
            return "\(minutes)分\(remainder)秒"
        }
        return "\(remainder)秒"
    }

    @objc private func changeSource() {
        guard let source = TaskVideoSource(
            rawValue: sourceControl.selectedSegment
        ) else {
            return
        }
        if knowledgeVideoLocked, source == .douyin {
            sourceControl.selectedSegment = TaskVideoSource.bilibili.rawValue
            return
        }
        select(source)
    }

    @objc private func reloadVideo() {
        select(selectedSource, forceReload: true)
    }

    @objc private func openCurrentVideoInBrowser() {
        NSWorkspace.shared.open(selectedSource.externalURL)
    }

    @objc private func customizeBilibiliVideo() {
        guard let window else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "更换 B 站视频"
        alert.informativeText =
            "粘贴完整的 B 站视频链接或 BV 号。选择会保存在本机，"
            + "下次弹窗继续使用。"
        alert.addButton(withTitle: "保存并播放")
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")

        let currentChoice = BilibiliVideoPreference.load()
        let inputField = NSTextField(
            frame: NSRect(x: 0, y: 24, width: 430, height: 26)
        )
        inputField.placeholderString =
            "例如：https://www.bilibili.com/video/BV… 或 BV…"
        inputField.stringValue = currentChoice.publicURL.absoluteString

        let hintLabel = NSTextField(
            labelWithString: "多 P 视频会自动读取链接中的 p 参数。"
        )
        hintLabel.frame = NSRect(x: 0, y: 0, width: 430, height: 18)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)

        let accessoryView = NSView(
            frame: NSRect(x: 0, y: 0, width: 430, height: 52)
        )
        accessoryView.addSubview(inputField)
        accessoryView.addSubview(hintLabel)
        alert.accessoryView = accessoryView

        let shortcutMonitor = TextEditingShortcutMonitor(
            textField: inputField
        )
        alert.beginSheetModal(for: window) { [weak self] response in
            shortcutMonitor.invalidate()
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard let choice = BilibiliVideoChoice(
                    input: inputField.stringValue
                ) else {
                    self.showInvalidBilibiliVideoAlert()
                    return
                }
                BilibiliVideoPreference.save(choice)
                self.select(.bilibili, forceReload: true)
            case .alertSecondButtonReturn:
                BilibiliVideoPreference.reset()
                self.select(.bilibili, forceReload: true)
            default:
                break
            }
        }

        DispatchQueue.main.async {
            alert.window.makeFirstResponder(inputField)
            inputField.currentEditor()?.selectAll(nil)
            (inputField.currentEditor() as? NSTextView)?.menu =
                TextEditingShortcut.makeContextMenu()
        }
    }

    private func showInvalidBilibiliVideoAlert() {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "没有找到有效的 BV 号"
        alert.informativeText =
            "请粘贴形如 BV1xx411c7mD 的 BV 号，"
            + "或包含 BV 号的完整 bilibili.com 视频链接。"
            + "暂不支持 b23.tv 短链接。"
        alert.addButton(withTitle: "重新填写")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.customizeBilibiliVideo()
        }
    }

    @objc private func dismiss() {
        close()
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        progressIndicator.stopAnimation(nil)
        updateWebContentScale()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        progressIndicator.stopAnimation(nil)
        handleNavigationError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        progressIndicator.stopAnimation(nil)
        handleNavigationError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showWebStatus("播放器进程已停止，请点“重新加载”再试。")
    }

    private func schedulePlayerVerification(
        for source: TaskVideoSource,
        generation: Int
    ) {
        guard source == .bilibili else { return }
        for (delay, isFinalCheck) in [
            (2.0, false),
            (8.0, true)
        ] {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay
            ) { [weak self] in
                guard let self,
                      self.loadGeneration == generation,
                      self.selectedSource == source else {
                    return
                }
                self.verifyBilibiliPlayer(
                    generation: generation,
                    isFinalCheck: isFinalCheck
                )
            }
        }
    }

    private func verifyBilibiliPlayer(
        generation: Int,
        isFinalCheck: Bool
    ) {
        webView.evaluateJavaScript(Self.playerHealthScript) {
            [weak self] result, error in
            guard let self,
                  self.loadGeneration == generation,
                  self.selectedSource == .bilibili else {
                return
            }

            if let error {
                if isFinalCheck {
                    self.showWebStatus(
                        "B站播放器脚本没有正常启动："
                            + error.localizedDescription
                            + "。请点“重新加载”再试。"
                    )
                }
                return
            }

            guard let health = result as? [String: Any] else {
                if isFinalCheck {
                    self.showWebStatus(
                        "没有检测到 B站播放器，请点“重新加载”再试。"
                    )
                }
                return
            }

            let hasVideo = health["hasVideo"] as? Bool ?? false
            let errorText = (
                health["errorText"] as? String ?? ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            if !errorText.isEmpty {
                self.showWebStatus(
                    "B站播放器提示：\(errorText)"
                )
            } else if hasVideo {
                self.hideWebStatus()
            } else if isFinalCheck {
                self.showWebStatus(
                    "B站播放器加载超时，请点“重新加载”再试。"
                )
            }
        }
    }

    private func handleNavigationError(_ error: Error) {
        let nsError = error as NSError
        guard !(
            nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled
        ) else {
            return
        }
        showWebStatus(
            "视频页面加载失败：\(error.localizedDescription)"
                + "。请点“重新加载”再试。"
        )
    }

    private func showWebStatus(_ message: String) {
        webStatusLabel.stringValue = message
        webStatusLabel.isHidden = false
    }

    private func hideWebStatus() {
        webStatusLabel.stringValue = ""
        webStatusLabel.isHidden = true
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let requestURL = navigationAction.request.url,
           requestURL.scheme == "https" || requestURL.scheme == "http" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private static let adaptiveVideoScript = """
    (() => {
      let scheduled = false;
      const fitPage = () => {
        scheduled = false;
        let viewport = document.querySelector('meta[name="viewport"]');
        if (!viewport) {
          viewport = document.createElement("meta");
          viewport.name = "viewport";
          document.head?.appendChild(viewport);
        }
        viewport?.setAttribute(
          "content",
          "width=device-width, initial-scale=1, viewport-fit=cover"
        );

        [document.documentElement, document.body,
          document.querySelector("#root"),
          document.querySelector("#app")
        ].filter(Boolean).forEach((node) => {
          node.style.setProperty("width", "100%", "important");
          node.style.setProperty("min-width", "0", "important");
          node.style.setProperty("min-height", "100%", "important");
          node.style.setProperty("max-width", "100vw", "important");
          node.style.setProperty("margin", "0", "important");
          node.style.setProperty("padding", "0", "important");
          node.style.setProperty("overflow-x", "hidden", "important");
        });

        document.querySelectorAll("video").forEach((media) => {
          media.style.setProperty("max-width", "100%", "important");
          media.style.setProperty("max-height", "100%", "important");
          media.style.setProperty("object-fit", "contain", "important");
          media.setAttribute("playsinline", "");
        });
      };
      const scheduleFit = () => {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(fitPage);
      };

      window.__kiwiResponsiveFit = fitPage;
      new MutationObserver(scheduleFit).observe(document.documentElement, {
        childList: true,
        subtree: true
      });
      window.addEventListener("resize", scheduleFit, { passive: true });
      scheduleFit();
    })();
    """

    private static let playerHealthScript = """
    (() => {
      const video = document.querySelector("video");
      const errorNode = document.querySelector(
        ".bpx-player-error, .bpx-player-error-wrap, "
          + ".error-container, .error-text"
      );
      const mediaError = video && video.error
        ? (video.error.message || `媒体错误 ${video.error.code}`)
        : "";
      return {
        hasVideo: Boolean(video),
        readyState: video ? video.readyState : -1,
        networkState: video ? video.networkState : -1,
        errorText: mediaError || (
          errorNode ? errorNode.textContent.trim() : ""
        )
      };
    })();
    """
}
