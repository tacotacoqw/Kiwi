import AppKit

enum ReminderIntervalInput {
    static let allowedMinutes = 1...720

    static func parseMinutes(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let minutes = Int(trimmed),
              allowedMinutes.contains(minutes) else {
            return nil
        }
        return minutes
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let compactStatusItemLength: CGFloat = 22

    private enum DefaultsKey {
        static let monitoringEnabled = "monitoringEnabled"
        static let codexTaskMonitoringEnabled = "codexTaskMonitoringEnabled"
        static let codexMobileNotificationsEnabled =
            "codexMobileNotificationsEnabled"
        static let pendingCodexCompletionNotifications =
            "pendingCodexCompletionNotifications"
        static let codexMobileNotificationDeliveryState =
            "codexMobileNotificationDeliveryState"
        static let soundEnabled = "soundEnabled"
        static let reminderMinutes = "reminderMinutes"
        static let hydrationEnabled = "hydrationEnabled"
        static let hydrationMinutes = "hydrationMinutes"
        static let windowX = "windowX"
        static let windowY = "windowY"
    }

    private enum FeishuReminderTiming {
        static let syncInterval: TimeInterval = 60
        static let localCheckInterval: TimeInterval = 15
    }

    private enum CodexVideoTiming {
        static let shortVideoCheckpoint: TimeInterval = 5 * 60
        static let forceKnowledgeVideo: TimeInterval = 10 * 60
    }

    private struct PendingCodexCompletionNotification: Codable {
        let id: String
        let duration: TimeInterval
        let finishedAt: Date
    }

    private let userDefaults = UserDefaults.standard
    private let animationPreviewMode =
        ProcessInfo.processInfo.arguments.contains("--animation-preview")
        || ProcessInfo.processInfo.arguments.contains(
            "--calendar-alert-preview"
        )
        || ProcessInfo.processInfo.arguments.contains(
            "--quick-actions-preview"
        )
        || ProcessInfo.processInfo.arguments.contains(
            "--message-preview"
        )
        || ProcessInfo.processInfo.arguments.contains(
            "--today-schedule-preview"
        )
        || ProcessInfo.processInfo.arguments.contains(
            "--persistent-reminder-preview"
        )
        || ProcessInfo.processInfo.arguments.contains(
            "--persistent-reminder-exit-preview"
        )
    private let calendarAlertPreviewMode = ProcessInfo.processInfo.arguments
        .contains("--calendar-alert-preview")
    private let quickActionsPreviewMode = ProcessInfo.processInfo.arguments
        .contains("--quick-actions-preview")
    private let messagePreviewMode = ProcessInfo.processInfo.arguments
        .contains("--message-preview")
    private let todaySchedulePreviewMode = ProcessInfo.processInfo.arguments
        .contains("--today-schedule-preview")
    private let persistentReminderPreviewMode =
        ProcessInfo.processInfo.arguments.contains(
            "--persistent-reminder-preview"
        )
    private let persistentReminderExitPreviewMode =
        ProcessInfo.processInfo.arguments.contains(
            "--persistent-reminder-exit-preview"
        )
    private let cameraMonitor = CameraMonitor()
    private let codexTaskMonitor = CodexTaskMonitor()
    private let codexLocalTaskMonitor = CodexLocalTaskMonitor()
    private lazy var sittingTracker = SittingTracker(reminderInterval: savedReminderInterval)
    private lazy var hydrationTracker = HydrationTracker(
        reminderInterval: savedHydrationReminderInterval,
        isEnabled: userDefaults.bool(forKey: DefaultsKey.hydrationEnabled)
    )
    private let feishuConfigurationStore = FeishuConfigurationStore()
    private let feishuOAuthService = FeishuOAuthService()
    private lazy var feishuCalendarService = FeishuCalendarService(
        oauthService: feishuOAuthService
    )

    private var petWindow: PetWindow!
    private var petView: PetView!
    private lazy var reminderEscalationController =
        ReminderEscalationWindowController { [weak self] in
            self?.petWindow?.screen ?? NSScreen.main
        }
    private var statusItem: NSStatusItem?
    private var cameraStatusItem: NSMenuItem!
    private var cameraToggleItem: NSMenuItem!
    private var cameraSettingsItem: NSMenuItem!
    private var durationItems: [NSMenuItem] = []
    private var customDurationItem: NSMenuItem!
    private var hydrationStatusItem: NSMenuItem!
    private var hydrationToggleItem: NSMenuItem!
    private var hydrationDurationItems: [NSMenuItem] = []
    private var customHydrationDurationItem: NSMenuItem!
    private var codexMenuRootItem: NSMenuItem!
    private var codexStatusItem: NSMenuItem!
    private var codexTaskStatusItem: NSMenuItem!
    private var codexToggleItem: NSMenuItem!
    private var codexScreenSettingsItem: NSMenuItem!
    private var codexMobileNotificationItem: NSMenuItem!
    private var taskBreakWindowController: TaskBreakWindowController? {
        didSet {
            taskBreakWindowController?.onRequestFeeding = {
                [weak self] in
                self?.petView.startFeeding()
            }
        }
    }
    private var todayScheduleWindowController:
        TodayScheduleWindowController?
    private var codexActiveTaskStartedAt: Date?
    private var codexVideoSessionStarted = false
    private var codexLocalTaskSignalAvailable = false
    private var codexLocalActiveTurnID: String?
    private var codexNotificationDeliveryInProgress = false
    private var codexNotificationRetryWorkItem: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var feishuTimer: Timer?
    private var feishuReminderTimer: Timer?
    private var feishuStatusItem: NSMenuItem!
    private var feishuNextEventItem: NSMenuItem!
    private var feishuReminderRuleItem: NSMenuItem!
    private var feishuOAuthItem: NSMenuItem!
    private var feishuSettingsController: FeishuSettingsWindowController?
    private var feishuSyncInProgress = false
    private var feishuAuthorizationInProgress = false
    private var feishuCallbackServer: FeishuOAuthCallbackServer?
    private var alertedFeishuEvents: [String: Date] = [:]
    private var cachedFeishuEvents: [FeishuCalendarEvent] = []
    private var monitoringEnabled = true
    private var codexTaskMonitoringEnabled = true
    private var soundEnabled = true
    private var cameraStatus: CameraMonitor.Status = .stopped
    private var demoPreviousInterval: TimeInterval?
    private var isAwaitingStandingConfirmation = false
    private var standingDetectionProgress: StandingDetectionProgress?

    private var savedReminderInterval: TimeInterval {
        let savedMinutes = userDefaults.double(forKey: DefaultsKey.reminderMinutes)
        let minutes = savedMinutes > 0 ? savedMinutes : 45
        return minutes * 60
    }

    private var savedHydrationReminderInterval: TimeInterval {
        let savedMinutes = userDefaults.double(
            forKey: DefaultsKey.hydrationMinutes
        )
        let minutes = savedMinutes > 0 ? savedMinutes : 45
        return minutes * 60
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerDefaults()
        soundEnabled = userDefaults.bool(forKey: DefaultsKey.soundEnabled)
        if !animationPreviewMode {
            ensureStatusMenuAvailable()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createPet()
        if animationPreviewMode {
            petView.monitorState = .off
            if messagePreviewMode {
                petView.showMessage(
                    "今天的任务：21:00「蓝调（福气脱口秀）」81 分钟后开始",
                    duration: 30
                )
            } else if quickActionsPreviewMode {
                petView.toggleQuickActions()
            } else if todaySchedulePreviewMode {
                previewTodaySchedule()
            } else if persistentReminderExitPreviewMode {
                reminderEscalationController.previewNow()
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 10
                ) { [weak self] in
                    self?.reminderEscalationController.resolve(
                        .standing
                    )
                }
            } else if persistentReminderPreviewMode {
                reminderEscalationController.previewNow()
            } else if calendarAlertPreviewMode {
                petView.showWorkAlert(
                    details: "16:30「项目进度会」5 分钟后开始"
                )
            } else {
                petView.playPerformanceNow()
            }
            return
        }
        ensureStatusMenuAvailable()
        DispatchQueue.main.async { [weak self] in
            self?.ensureStatusMenuAvailable()
        }
        connectMonitoring()
        connectCodexTaskMonitoring()
        startHeartbeat()
        startFeishuCalendarPolling()
        deliverPendingCodexCompletionNotifications()
        if CommandLine.arguments.contains("--authorize-feishu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.authorizeFeishuUser()
            }
        } else if CommandLine.arguments.contains("--open-feishu-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openFeishuSettings()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        monitoringEnabled = userDefaults.bool(forKey: DefaultsKey.monitoringEnabled)
        codexTaskMonitoringEnabled = userDefaults.bool(
            forKey: DefaultsKey.codexTaskMonitoringEnabled
        )
        if monitoringEnabled {
            cameraMonitor.start(requestPermissionIfNeeded: true)
        } else {
            petView.monitorState = .off
        }
        if codexTaskMonitoringEnabled {
            codexLocalTaskMonitor.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.codexTaskMonitoringEnabled else { return }
                self.codexTaskMonitor.start()
            }
        }
        updateMenu()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        ensureStatusMenuAvailable()
        showKiwi()
        DispatchQueue.main.async { [weak self] in
            self?.presentStatusMenuFromPet()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !animationPreviewMode else { return }
        ensureStatusMenuAvailable()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cameraMonitor.stop()
        codexTaskMonitor.stop()
        codexLocalTaskMonitor.stop()
        heartbeatTimer?.invalidate()
        feishuTimer?.invalidate()
        feishuReminderTimer?.invalidate()
        feishuCallbackServer?.stop()
        codexNotificationRetryWorkItem?.cancel()
        reminderEscalationController.cancelAll()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationDidHide(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            NSApp.unhideWithoutActivation()
            self?.ensurePetIsVisible()
        }
    }

    private func registerDefaults() {
        userDefaults.register(defaults: [
            DefaultsKey.monitoringEnabled: true,
            DefaultsKey.codexTaskMonitoringEnabled: true,
            DefaultsKey.codexMobileNotificationsEnabled: true,
            DefaultsKey.soundEnabled: true,
            DefaultsKey.reminderMinutes: 45,
            DefaultsKey.hydrationEnabled: true,
            DefaultsKey.hydrationMinutes: 45
        ])
    }

    private func createPet() {
        let windowSize = PetView.preferredWindowSize
        let origin: NSPoint
        if animationPreviewMode {
            let visible = NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            origin = NSPoint(
                x: visible.minX + 36,
                y: visible.maxY - windowSize.height - 36
            )
        } else {
            origin = restoredWindowOrigin(for: windowSize)
        }
        petWindow = PetWindow(frame: NSRect(origin: origin, size: windowSize))
        petView = PetView(frame: NSRect(origin: .zero, size: windowSize))
        petView.autoresizingMask = [.width, .height]
        petView.setSoundEnabled(soundEnabled)
        petView.onTap = { [weak self] in
            self?.handlePetTap()
        }
        petView.onQuickAction = { [weak self] action in
            self?.handlePetQuickAction(action)
        }
        petView.onContextMenu = { [weak self] point in
            self?.presentStatusMenuFromPet(at: point)
        }
        petView.onSoundEnabledChanged = { [weak self] enabled in
            guard let self else { return }
            self.soundEnabled = enabled
            self.userDefaults.set(enabled, forKey: DefaultsKey.soundEnabled)
        }
        petView.onPositionChanged = { [weak self] point in
            self?.userDefaults.set(point.x, forKey: DefaultsKey.windowX)
            self?.userDefaults.set(point.y, forKey: DefaultsKey.windowY)
        }
        petWindow.contentView = petView
        petWindow.orderFrontRegardless()
    }

    private func restoredWindowOrigin(for size: NSSize) -> NSPoint {
        let fallbackFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        if userDefaults.object(forKey: DefaultsKey.windowX) != nil,
           userDefaults.object(forKey: DefaultsKey.windowY) != nil {
            let saved = NSPoint(
                x: userDefaults.double(forKey: DefaultsKey.windowX),
                y: userDefaults.double(forKey: DefaultsKey.windowY)
            )
            let savedRect = NSRect(origin: saved, size: size)
            let targetScreen = NSScreen.screens.first {
                $0.visibleFrame.intersection(savedRect).width >= 80
                    && $0.visibleFrame.intersection(savedRect).height >= 80
            }
            return clampedOrigin(
                saved,
                size: size,
                visibleFrame: targetScreen?.visibleFrame ?? fallbackFrame
            )
        }

        return NSPoint(
            x: fallbackFrame.maxX - size.width - 24,
            y: fallbackFrame.minY + 24
        )
    }

    private func clampedOrigin(
        _ origin: NSPoint,
        size: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let inset: CGFloat = 12
        let minimumX = visibleFrame.minX + inset
        let maximumX = max(minimumX, visibleFrame.maxX - size.width - inset)
        let minimumY = visibleFrame.minY + inset
        let maximumY = max(minimumY, visibleFrame.maxY - size.height - inset)
        return NSPoint(
            x: min(max(origin.x, minimumX), maximumX),
            y: min(max(origin.y, minimumY), maximumY)
        )
    }

    private func ensurePetIsVisible() {
        guard let petWindow else { return }
        let currentRect = petWindow.frame
        let targetScreen = NSScreen.screens.first {
            $0.visibleFrame.intersection(currentRect).width >= 80
                && $0.visibleFrame.intersection(currentRect).height >= 80
        }
        let visibleFrame = targetScreen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let origin = clampedOrigin(
            currentRect.origin,
            size: currentRect.size,
            visibleFrame: visibleFrame
        )
        petWindow.setFrameOrigin(origin)
        petWindow.orderFrontRegardless()
        petView.restoreVisibility()
        userDefaults.set(origin.x, forKey: DefaultsKey.windowX)
        userDefaults.set(origin.y, forKey: DefaultsKey.windowY)
    }

    @objc private func screenConfigurationChanged() {
        ensurePetIsVisible()
        ensureStatusMenuAvailable()
        reminderEscalationController.screenConfigurationChanged()
    }

    private func applyMenuIcon(_ item: NSMenuItem, named name: String) {
        guard let icon = AssetLoader.icon(named: name) else { return }
        icon.size = NSSize(width: 17, height: 17)
        icon.isTemplate = true
        item.image = icon
    }

    private func createStatusMenu() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(
            withLength: Self.compactStatusItemLength
        )
        statusItem = item
        item.autosaveName = "KiwiStatusItem.v2"
        item.isVisible = true
        if let button = item.button {
            button.image = AssetLoader.icon(named: "kiwi.svg")
                ?? AssetLoader.frame(named: "idle-08.png")
            button.image?.size = NSSize(width: 17, height: 17)
            button.image?.isTemplate = true
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Kiwi 后台"
            button.setAccessibilityLabel("Kiwi 后台")
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(
            title: "显示 Kiwi",
            action: #selector(showKiwi),
            keyEquivalent: ""
        )
        showItem.target = self
        applyMenuIcon(showItem, named: "kiwi.svg")
        menu.addItem(showItem)
        menu.addItem(.separator())

        cameraStatusItem = NSMenuItem(title: "正在准备…", action: nil, keyEquivalent: "")
        cameraStatusItem.isEnabled = false
        applyMenuIcon(cameraStatusItem, named: "status.svg")
        menu.addItem(cameraStatusItem)
        menu.addItem(.separator())

        cameraToggleItem = NSMenuItem(
            title: "摄像头监测",
            action: #selector(toggleMonitoring),
            keyEquivalent: ""
        )
        cameraToggleItem.target = self
        applyMenuIcon(cameraToggleItem, named: "camera.svg")
        menu.addItem(cameraToggleItem)

        cameraSettingsItem = NSMenuItem(
            title: "打开摄像头权限设置…",
            action: #selector(openCameraSettings),
            keyEquivalent: ""
        )
        cameraSettingsItem.target = self
        cameraSettingsItem.isHidden = true
        applyMenuIcon(cameraSettingsItem, named: "settings.svg")
        menu.addItem(cameraSettingsItem)

        let durationItem = NSMenuItem(
            title: "散步提醒间隔",
            action: nil,
            keyEquivalent: ""
        )
        applyMenuIcon(durationItem, named: "timer.svg")
        let durationMenu = NSMenu()
        for minutes in [25, 45, 60] {
            let item = NSMenuItem(
                title: "\(minutes) 分钟",
                action: #selector(changeDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = minutes
            applyMenuIcon(item, named: "timer.svg")
            durationMenu.addItem(item)
            durationItems.append(item)
        }
        durationMenu.addItem(.separator())
        customDurationItem = NSMenuItem(
            title: "自定义…",
            action: #selector(changeCustomDuration),
            keyEquivalent: ""
        )
        customDurationItem.target = self
        applyMenuIcon(customDurationItem, named: "settings.svg")
        durationMenu.addItem(customDurationItem)
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)

        let demoItem = NSMenuItem(
            title: "10 秒体验久坐提醒",
            action: #selector(startDemo),
            keyEquivalent: ""
        )
        demoItem.target = self
        applyMenuIcon(demoItem, named: "bell.svg")
        menu.addItem(demoItem)

        menu.addItem(.separator())
        hydrationStatusItem = NSMenuItem(
            title: "喝水提醒：正在准备…",
            action: nil,
            keyEquivalent: ""
        )
        hydrationStatusItem.isEnabled = false
        applyMenuIcon(hydrationStatusItem, named: "water.svg")
        menu.addItem(hydrationStatusItem)

        hydrationToggleItem = NSMenuItem(
            title: "喝水提醒（摄像头确认）",
            action: #selector(toggleHydrationReminder),
            keyEquivalent: ""
        )
        hydrationToggleItem.target = self
        applyMenuIcon(hydrationToggleItem, named: "water.svg")
        menu.addItem(hydrationToggleItem)

        let hydrationDurationItem = NSMenuItem(
            title: "喝水提醒间隔",
            action: nil,
            keyEquivalent: ""
        )
        applyMenuIcon(hydrationDurationItem, named: "timer.svg")
        let hydrationDurationMenu = NSMenu()
        for minutes in [30, 45, 60] {
            let item = NSMenuItem(
                title: "\(minutes) 分钟",
                action: #selector(changeHydrationDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = minutes
            applyMenuIcon(item, named: "water.svg")
            hydrationDurationMenu.addItem(item)
            hydrationDurationItems.append(item)
        }
        hydrationDurationMenu.addItem(.separator())
        customHydrationDurationItem = NSMenuItem(
            title: "自定义…",
            action: #selector(changeCustomHydrationDuration),
            keyEquivalent: ""
        )
        customHydrationDurationItem.target = self
        applyMenuIcon(customHydrationDurationItem, named: "settings.svg")
        hydrationDurationMenu.addItem(customHydrationDurationItem)
        hydrationDurationItem.submenu = hydrationDurationMenu
        menu.addItem(hydrationDurationItem)

        let hydrationDemoItem = NSMenuItem(
            title: "立即体验喝水检测",
            action: #selector(startHydrationDemo),
            keyEquivalent: ""
        )
        hydrationDemoItem.target = self
        applyMenuIcon(hydrationDemoItem, named: "water.svg")
        menu.addItem(hydrationDemoItem)

        menu.addItem(.separator())
        let walkItem = NSMenuItem(
            title: "让 Kiwi 走一走",
            action: #selector(startWalk),
            keyEquivalent: ""
        )
        walkItem.target = self
        applyMenuIcon(walkItem, named: "walk.svg")
        menu.addItem(walkItem)

        menu.addItem(.separator())
        codexMenuRootItem = NSMenuItem(
            title: "Codex 画面监测（等待启动）",
            action: nil,
            keyEquivalent: ""
        )
        applyMenuIcon(codexMenuRootItem, named: "codex.svg")
        let codexMenu = NSMenu()
        codexStatusItem = NSMenuItem(
            title: "画面监测：等待启动",
            action: nil,
            keyEquivalent: ""
        )
        codexStatusItem.isEnabled = false
        applyMenuIcon(codexStatusItem, named: "status.svg")
        codexMenu.addItem(codexStatusItem)

        codexTaskStatusItem = NSMenuItem(
            title: "任务：暂无",
            action: nil,
            keyEquivalent: ""
        )
        codexTaskStatusItem.isEnabled = false
        applyMenuIcon(codexTaskStatusItem, named: "task.svg")
        codexMenu.addItem(codexTaskStatusItem)
        codexMenu.addItem(.separator())

        codexToggleItem = NSMenuItem(
            title: "逐张识别 Codex 画面（每 5 秒）",
            action: #selector(toggleCodexTaskMonitoring),
            keyEquivalent: ""
        )
        codexToggleItem.target = self
        applyMenuIcon(codexToggleItem, named: "codex.svg")
        codexMenu.addItem(codexToggleItem)

        codexScreenSettingsItem = NSMenuItem(
            title: "打开屏幕录制权限设置…",
            action: #selector(openScreenCaptureSettings),
            keyEquivalent: ""
        )
        codexScreenSettingsItem.target = self
        codexScreenSettingsItem.isHidden = true
        applyMenuIcon(codexScreenSettingsItem, named: "settings.svg")
        codexMenu.addItem(codexScreenSettingsItem)
        codexMenu.addItem(.separator())

        codexMobileNotificationItem = NSMenuItem(
            title: "完成后发送飞书手机提醒",
            action: #selector(toggleCodexMobileNotifications),
            keyEquivalent: ""
        )
        codexMobileNotificationItem.target = self
        applyMenuIcon(codexMobileNotificationItem, named: "phone.svg")
        codexMenu.addItem(codexMobileNotificationItem)

        codexMenuRootItem.submenu = codexMenu
        menu.addItem(codexMenuRootItem)

        menu.addItem(.separator())
        let feishuItem = NSMenuItem(title: "飞书日历", action: nil, keyEquivalent: "")
        applyMenuIcon(feishuItem, named: "calendar.svg")
        let feishuMenu = NSMenu()
        feishuStatusItem = NSMenuItem(title: "状态：未配置", action: nil, keyEquivalent: "")
        feishuStatusItem.isEnabled = false
        applyMenuIcon(feishuStatusItem, named: "status.svg")
        feishuMenu.addItem(feishuStatusItem)

        feishuNextEventItem = NSMenuItem(title: "下一项：—", action: nil, keyEquivalent: "")
        feishuNextEventItem.isEnabled = false
        applyMenuIcon(feishuNextEventItem, named: "task.svg")
        feishuMenu.addItem(feishuNextEventItem)

        feishuReminderRuleItem = NSMenuItem(
            title: "提醒：提前 5 分钟 · 每 3 分钟重复",
            action: nil,
            keyEquivalent: ""
        )
        feishuReminderRuleItem.isEnabled = false
        applyMenuIcon(feishuReminderRuleItem, named: "bell.svg")
        feishuMenu.addItem(feishuReminderRuleItem)

        feishuOAuthItem = NSMenuItem(
            title: "登录飞书读取标题…",
            action: #selector(authorizeFeishuUser),
            keyEquivalent: ""
        )
        feishuOAuthItem.target = self
        applyMenuIcon(feishuOAuthItem, named: "login.svg")
        feishuMenu.addItem(feishuOAuthItem)

        let feishuSettingsItem = NSMenuItem(
            title: "连接与提醒设置…",
            action: #selector(openFeishuSettings),
            keyEquivalent: ""
        )
        feishuSettingsItem.target = self
        applyMenuIcon(feishuSettingsItem, named: "settings.svg")
        feishuMenu.addItem(feishuSettingsItem)

        let feishuSyncItem = NSMenuItem(
            title: "立即同步",
            action: #selector(syncFeishuNow),
            keyEquivalent: ""
        )
        feishuSyncItem.target = self
        applyMenuIcon(feishuSyncItem, named: "sync.svg")
        feishuMenu.addItem(feishuSyncItem)

        let feishuTestItem = NSMenuItem(
            title: "创建 2 分钟测试提醒",
            action: #selector(createFeishuTestReminder),
            keyEquivalent: ""
        )
        feishuTestItem.target = self
        applyMenuIcon(feishuTestItem, named: "bell.svg")
        feishuMenu.addItem(feishuTestItem)

        feishuItem.submenu = feishuMenu
        menu.addItem(feishuItem)

        menu.addItem(.separator())
        let privacyItem = NSMenuItem(
            title: "Codex 截图逐张识别后立即清除，不会保存或上传",
            action: nil,
            keyEquivalent: ""
        )
        privacyItem.isEnabled = false
        applyMenuIcon(privacyItem, named: "shield.svg")
        menu.addItem(privacyItem)

        let cameraPrivacyItem = NSMenuItem(
            title: "摄像头画面仅在本机识别久坐、站立和喝水动作，不保存或上传",
            action: nil,
            keyEquivalent: ""
        )
        cameraPrivacyItem.isEnabled = false
        applyMenuIcon(cameraPrivacyItem, named: "shield.svg")
        menu.addItem(cameraPrivacyItem)

        let quitItem = NSMenuItem(
            title: "退出 Kiwi",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applyMenuIcon(quitItem, named: "quit.svg")
        menu.addItem(quitItem)
        item.menu = menu
        ensureStatusMenuAvailable()
    }

    private func ensureStatusMenuAvailable() {
        if statusItem == nil {
            createStatusMenu()
            return
        }

        statusItem?.length = Self.compactStatusItemLength
        statusItem?.isVisible = true
        if let button = statusItem?.button {
            button.isHidden = false
            button.alphaValue = 1
            button.isEnabled = true
            button.needsDisplay = true
        }
    }

    private func presentStatusMenuFromPet(at point: NSPoint? = nil) {
        ensureStatusMenuAvailable()
        updateMenu()
        guard let menu = statusItem?.menu, let petView else { return }
        let anchor = point ?? NSPoint(
            x: petView.bounds.midX,
            y: petView.bounds.midY
        )
        menu.popUp(positioning: nil, at: anchor, in: petView)
    }

    private func connectMonitoring() {
        cameraMonitor.onPresenceChanged = { [weak self] present in
            guard let self else { return }
            self.sittingTracker.updatePresence(present)
            self.hydrationTracker.updatePresence(present)
            self.petView.monitorState = present ? .present : .waiting
            self.updateMenu()
        }

        cameraMonitor.onDrinkDetected = { [weak self] in
            self?.handleDetectedDrink()
        }
        cameraMonitor.onStandingConfirmed = { [weak self] in
            self?.handleStandingConfirmed()
        }
        cameraMonitor.onStandingProgress = { [weak self] progress in
            guard let self,
                  self.isAwaitingStandingConfirmation else {
                return
            }
            self.standingDetectionProgress = progress
            self.updateMenu()
        }

        cameraMonitor.onStatusChanged = { [weak self] status in
            guard let self else { return }
            self.cameraStatus = status
            switch status {
            case .running:
                self.petView.monitorState = .waiting
                self.cameraMonitor.setDrinkDetectionEnabled(
                    self.hydrationTracker.isAwaitingDrink
                )
            case .permissionRequired:
                self.cancelStandingConfirmation()
                self.reminderEscalationController.resolve(.drinking)
                self.restoreReminderIntervalAfterDemo()
                self.sittingTracker.reset()
                self.hydrationTracker.updatePresence(false)
                self.petView.monitorState = .off
            case .denied:
                self.cancelStandingConfirmation()
                self.reminderEscalationController.resolve(.drinking)
                self.restoreReminderIntervalAfterDemo()
                self.sittingTracker.reset()
                self.hydrationTracker.updatePresence(false)
                self.petView.monitorState = .off
                self.petView.showMessage(
                    "需要摄像头权限才能记录久坐和确认喝水。请在系统设置中允许 Kiwi 使用摄像头。",
                    duration: 12
                )
            case .unavailable(let reason):
                self.cancelStandingConfirmation()
                self.reminderEscalationController.resolve(.drinking)
                self.restoreReminderIntervalAfterDemo()
                self.sittingTracker.reset()
                self.hydrationTracker.updatePresence(false)
                self.petView.monitorState = .off
                self.petView.showMessage("摄像头暂时不可用：\(reason)", duration: 10)
            case .stopped:
                self.cancelStandingConfirmation()
                self.reminderEscalationController.resolve(.drinking)
                self.restoreReminderIntervalAfterDemo()
                self.sittingTracker.reset()
                self.hydrationTracker.updatePresence(false)
                self.petView.monitorState = .off
            case .requestingPermission:
                self.petView.monitorState = .waiting
                self.petView.showMessage(
                    "请在系统弹窗中允许 Kiwi 使用摄像头，画面只会在本机分析。",
                    duration: 10
                )
            case .starting:
                self.petView.monitorState = .waiting
            }
            self.updateMenu()
        }
    }

    private func connectCodexTaskMonitoring() {
        codexLocalTaskMonitor.onTaskCompleted = { [weak self] completion in
            self?.handleCodexLocalTaskCompletion(completion)
        }
        codexLocalTaskMonitor.onStatusChanged = { [weak self] status in
            guard let self else { return }
            switch status {
            case .watching:
                self.codexLocalTaskSignalAvailable = true
                if self.codexLocalActiveTurnID != nil {
                    // The exact completion callback normally clears this
                    // first. This is only a safety net for malformed logs.
                    self.cancelCodexTaskTracking()
                }
                self.codexLocalActiveTurnID = nil
            case .active(let task):
                self.codexLocalTaskSignalAvailable = true
                if self.codexLocalActiveTurnID != task.turnID {
                    self.codexLocalActiveTurnID = task.turnID
                    self.beginCodexTaskTracking(startedAt: task.startedAt)
                }
            case .unavailable, .stopped:
                self.codexLocalTaskSignalAvailable = false
                self.codexLocalActiveTurnID = nil
            }
            self.updateCodexMenu()
        }

        codexTaskMonitor.onStatusChanged = { [weak self] status in
            guard let self else { return }
            guard !self.codexLocalTaskSignalAvailable else {
                self.updateCodexMenu()
                return
            }
            switch status {
            case .timing(let startedAt):
                self.beginCodexTaskTracking(startedAt: startedAt)
            case .stopped, .permissionRequired, .lookingForCodex, .unavailable:
                self.cancelCodexTaskTracking()
            case .watching:
                break
            }
            self.updateCodexMenu()
        }
        codexTaskMonitor.onTaskCompleted = { [weak self] completion in
            guard let self, !self.codexLocalTaskSignalAvailable else { return }
            self.handleCodexTaskCompletion(completion)
        }
    }

    private func handleCodexLocalTaskCompletion(
        _ completion: CodexLocalTaskMonitor.Completion
    ) {
        NSLog(
            "Kiwi detected Codex completion turn=%@ duration=%.1fs",
            completion.turnID,
            completion.duration
        )
        // Every primary Codex task gets its own mobile notification, even
        // while another task remains active in a different conversation.
        enqueueCodexCompletionNotification(
            id: completion.turnID,
            duration: completion.duration,
            finishedAt: completion.finishedAt
        )

        if codexLocalActiveTurnID == completion.turnID {
            codexLocalActiveTurnID = nil
            finishCodexTaskTracking(duration: completion.duration)
        } else if codexLocalActiveTurnID == nil {
            // A short task can start and finish between two five-second
            // scans, and a freshly rebuilt Kiwi can catch up a completion
            // without first publishing its active state. Do not silently
            // lose the task popup in either case.
            codexActiveTaskStartedAt = nil
            codexVideoSessionStarted = false
            showTaskBreakPopup(
                recommendation: .recommendation(
                    for: completion.duration
                ),
                duration: completion.duration
            )
        }
    }

    private func handleCodexTaskCompletion(
        _ completion: CodexTaskMonitor.Completion
    ) {
        finishCodexTaskTracking(duration: completion.duration)
        enqueueCodexCompletionNotification(
            id: "screen-\(UUID().uuidString)",
            duration: completion.duration,
            finishedAt: completion.finishedAt
        )
    }

    private func finishCodexTaskTracking(duration: TimeInterval) {
        codexActiveTaskStartedAt = nil
        if codexVideoSessionStarted {
            taskBreakWindowController?.completeActiveTask(duration: duration)
        }
        codexVideoSessionStarted = false
    }

    private func beginCodexTaskTracking(startedAt: Date) {
        guard codexActiveTaskStartedAt != startedAt else { return }
        codexActiveTaskStartedAt = startedAt
        if taskBreakWindowController == nil {
            taskBreakWindowController = TaskBreakWindowController()
        }
        codexVideoSessionStarted = true
        taskBreakWindowController?.beginActiveTask(
            duration: max(0, Date().timeIntervalSince(startedAt))
        )
    }

    private func cancelCodexTaskTracking() {
        codexActiveTaskStartedAt = nil
        codexVideoSessionStarted = false
        taskBreakWindowController?.cancelActiveTask()
    }

    private func updateActiveCodexTaskVideo(now: Date = Date()) {
        guard let startedAt = codexActiveTaskStartedAt else { return }
        let duration = max(0, now.timeIntervalSince(startedAt))

        if taskBreakWindowController == nil {
            taskBreakWindowController = TaskBreakWindowController()
        }
        if !codexVideoSessionStarted {
            codexVideoSessionStarted = true
            taskBreakWindowController?.beginActiveTask(duration: duration)
        } else {
            taskBreakWindowController?.updateActiveTask(duration: duration)
        }
    }

    private func showTaskBreakPopup(
        recommendation: TaskBreakRecommendation,
        duration: TimeInterval
    ) {
        if taskBreakWindowController == nil {
            taskBreakWindowController = TaskBreakWindowController()
        }
        taskBreakWindowController?.show(
            recommendation: recommendation,
            duration: duration
        )
    }

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.sittingTracker.tick() == .reminder {
                self.showSittingReminder()
            }
            if self.hydrationTracker.tick() == .reminder {
                self.showHydrationReminder()
            }
            self.updateActiveCodexTaskVideo()
            self.updateMenu()
        }
        if let heartbeatTimer {
            RunLoop.main.add(heartbeatTimer, forMode: .common)
        }
    }

    private func startFeishuCalendarPolling() {
        let configuration = feishuConfigurationStore.load()
        updateFeishuAuthorizationMenu(configuration: configuration)
        updateFeishuReminderRule(configuration: configuration)
        if !configuration.hasCredentials {
            updateFeishuStatus("未配置")
        } else if feishuOAuthService.hasAuthorization(for: configuration.appID) {
            updateFeishuStatus("等待同步")
        } else {
            updateFeishuStatus("待登录飞书")
        }

        let timer = Timer(
            timeInterval: FeishuReminderTiming.syncInterval,
            repeats: true
        ) { [weak self] _ in
            self?.syncFeishuCalendar(showFeedback: false)
        }
        feishuTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        let reminderTimer = Timer(
            timeInterval: FeishuReminderTiming.localCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkCachedFeishuReminders()
        }
        feishuReminderTimer = reminderTimer
        RunLoop.main.add(reminderTimer, forMode: .common)

        if configuration.hasCredentials,
           feishuOAuthService.hasAuthorization(for: configuration.appID) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.syncFeishuCalendar(showFeedback: false)
            }
        }
    }

    private func syncFeishuCalendar(showFeedback: Bool) {
        guard !feishuSyncInProgress else { return }
        let configuration = feishuConfigurationStore.load()
        guard configuration.hasCredentials else {
            updateFeishuStatus("未配置")
            updateFeishuNextEvent(nil, now: Date())
            if showFeedback {
                openFeishuSettings()
                feishuSettingsController?.setStatus("请填写 App ID 和 App Secret。", isError: true)
            }
            return
        }

        feishuSyncInProgress = true
        updateFeishuStatus("同步中…")
        if showFeedback {
            feishuSettingsController?.setStatus("正在连接飞书日历…")
        }

        let now = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.feishuCalendarService.upcomingEvents(
                    configuration: configuration,
                    from: now,
                    to: now.addingTimeInterval(24 * 60 * 60)
                )
                let activeEvents = result.events.filter {
                    $0.status != "cancelled"
                }
                self.cachedFeishuEvents = activeEvents
                let didPlayAutomaticAlert = self.handleUpcomingFeishuEvents(
                    activeEvents,
                    leadMinutes: configuration.leadMinutes,
                    repeatMinutes: configuration.repeatMinutes,
                    now: now
                )
                let nextEvent = self.nextFeishuEvent(in: activeEvents, now: now)
                self.updateFeishuNextEvent(nextEvent, now: now)
                self.updateFeishuStatus("标题可见 · \(activeEvents.count) 个近日程")
                self.updateFeishuAuthorizationMenu(configuration: configuration)
                self.updateFeishuReminderRule(configuration: configuration)
                self.feishuSettingsController?.setStatus(
                    "连接成功；任务开始前 \(configuration.leadMinutes) 分钟起，"
                        + "每 \(configuration.repeatMinutes) 分钟提醒一次。"
                )
                if showFeedback {
                    self.showManualSyncFeedback(
                        nextEvent: nextEvent,
                        now: now,
                        didPlayAutomaticAlert: didPlayAutomaticAlert
                    )
                }
            } catch {
                let needsAuthorization = self.isFeishuAuthorizationError(error)
                self.updateFeishuStatus(needsAuthorization ? "待登录飞书" : "同步失败")
                self.updateFeishuAuthorizationMenu(configuration: configuration)
                self.updateFeishuNextEvent(nil, now: now)
                let message = error.localizedDescription
                self.feishuSettingsController?.setStatus(message, isError: true)
                if showFeedback {
                    if needsAuthorization {
                        self.openFeishuSettings()
                    }
                    self.petView.showMessage(message, duration: 12)
                }
            }
            self.feishuSyncInProgress = false
        }
    }

    private func handleUpcomingFeishuEvents(
        _ events: [FeishuCalendarEvent],
        leadMinutes: Int,
        repeatMinutes: Int,
        now: Date
    ) -> Bool {
        let policy = FeishuReminderPolicy(
            leadMinutes: leadMinutes,
            repeatMinutes: repeatMinutes
        )
        let due = events
            .filter {
                $0.status != "cancelled"
                    && Calendar.current.isDate(
                        $0.startDate,
                        inSameDayAs: now
                    )
            }
            .sorted { $0.startDate < $1.startDate }
            .filter {
                policy.shouldAlert(
                    eventStart: $0.startDate,
                    lastAlert: alertedFeishuEvents[eventAlertKey($0)],
                    now: now
                )
            }

        alertedFeishuEvents = alertedFeishuEvents.filter {
            now.timeIntervalSince($0.value) < 2 * 24 * 60 * 60
        }

        guard let first = due.first else { return false }
        playFeishuEventAlert(first, now: now)
        return true
    }

    private func playFeishuEventAlert(
        _ event: FeishuCalendarEvent,
        now: Date
    ) {
        alertedFeishuEvents[eventAlertKey(event)] = now
        ensurePetIsVisible()
        petView.showWorkAlert(details: feishuEventDescription(event, now: now))
    }

    private func checkCachedFeishuReminders() {
        guard !cachedFeishuEvents.isEmpty else { return }
        let configuration = feishuConfigurationStore.load()
        let now = Date()
        _ = handleUpcomingFeishuEvents(
            cachedFeishuEvents,
            leadMinutes: configuration.leadMinutes,
            repeatMinutes: configuration.repeatMinutes,
            now: now
        )
    }

    private func showManualSyncFeedback(
        nextEvent: FeishuCalendarEvent?,
        now: Date,
        didPlayAutomaticAlert: Bool
    ) {
        guard !didPlayAutomaticAlert else { return }
        ensurePetIsVisible()

        if let nextEvent,
           Calendar.current.isDate(
               nextEvent.startDate,
               inSameDayAs: now
           ) {
            petView.showWorkAlert(
                details: feishuEventDescription(nextEvent, now: now)
            )
        } else {
            petView.showMessage(
                "同步完成！今天没有待办日程。",
                duration: 8
            )
            petView.playAttentionAnimation(strength: 1.0)
            if soundEnabled {
                NSSound(named: "Ping")?.play()
            }
        }
    }

    private func eventAlertKey(_ event: FeishuCalendarEvent) -> String {
        "\(event.eventID)|\(Int(event.startDate.timeIntervalSince1970))"
    }

    private func nextFeishuEvent(
        in events: [FeishuCalendarEvent],
        now: Date
    ) -> FeishuCalendarEvent? {
        return events
            .filter { $0.status != "cancelled" && $0.startDate >= now }
            .min { $0.startDate < $1.startDate }
    }

    private func updateFeishuNextEvent(
        _ event: FeishuCalendarEvent?,
        now: Date
    ) {
        guard let event else {
            feishuNextEventItem?.title = "下一项：未来 24 小时暂无日程"
            return
        }
        feishuNextEventItem?.title = "下一项：\(feishuEventDescription(event, now: now))"
    }

    private func feishuEventDescription(
        _ event: FeishuCalendarEvent,
        now: Date
    ) -> String {
        let calendar = Calendar.current
        let dayLabel: String
        if calendar.isDateInToday(event.startDate) {
            dayLabel = ""
        } else if calendar.isDateInTomorrow(event.startDate) {
            dayLabel = "明天 "
        } else {
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "zh_CN")
            dayFormatter.dateFormat = "M月d日 "
            dayLabel = dayFormatter.string(from: event.startDate)
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"
        let startLabel = dayLabel + timeFormatter.string(from: event.startDate)

        let interval = event.startDate.timeIntervalSince(now)
        let timing: String
        if interval < -30 {
            timing = "已开始"
        } else if interval <= 30 {
            timing = "马上开始"
        } else {
            let minutes = max(1, Int(ceil(interval / 60)))
            timing = "\(minutes) 分钟后开始"
        }

        let title = event.title
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(startLabel)「\(title.isEmpty ? "未命名日程" : title)」\(timing)"
    }

    private func updateFeishuStatus(_ status: String) {
        feishuStatusItem?.title = "状态：\(status)"
    }

    private func updateFeishuReminderRule(
        configuration: FeishuConfiguration
    ) {
        feishuReminderRuleItem?.title =
            "提醒：开始前 \(configuration.leadMinutes) 分钟起 · "
            + "每 \(configuration.repeatMinutes) 分钟重复"
    }

    private func updateFeishuAuthorizationMenu(
        configuration: FeishuConfiguration
    ) {
        let isAuthorized = feishuOAuthService.hasAuthorization(
            for: configuration.appID
        )
        feishuOAuthItem?.title = isAuthorized
            ? "重新授权飞书…"
            : "登录飞书读取标题…"
    }

    private func isFeishuAuthorizationError(_ error: Error) -> Bool {
        guard let error = error as? FeishuOAuthError else { return false }
        switch error {
        case .authorizationRequired, .authorizationExpired, .offlineAccessMissing:
            return true
        default:
            return false
        }
    }

    private func showSittingReminder() {
        guard !isAwaitingStandingConfirmation else { return }
        isAwaitingStandingConfirmation = true
        standingDetectionProgress = nil
        cameraMonitor.setStandingDetectionEnabled(true)
        reminderEscalationController.beginWaiting(for: .standing)
        petView.showMessageImage(
            named: "standing-reminder-bubble.png",
            accessibilityText: "站起来走走～",
            untilDismissed: true
        )
        petView.playAttentionAnimation(strength: 1.45)
        if soundEnabled {
            NSSound(named: "Ping")?.play()
        }

        if let previous = demoPreviousInterval {
            restoreReminderIntervalAfterDemo(previousInterval: previous)
        }
    }

    private func handleStandingConfirmed() {
        guard isAwaitingStandingConfirmation else { return }
        isAwaitingStandingConfirmation = false
        standingDetectionProgress = nil
        cameraMonitor.setStandingDetectionEnabled(false)
        reminderEscalationController.resolve(.standing)
        sittingTracker.restartSession()
        petView.dismissMessage()
        updateMenu()
    }

    private func cancelStandingConfirmation() {
        guard isAwaitingStandingConfirmation else { return }
        isAwaitingStandingConfirmation = false
        standingDetectionProgress = nil
        cameraMonitor.setStandingDetectionEnabled(false)
        reminderEscalationController.resolve(.standing)
        petView.dismissMessage()
    }

    private func showHydrationReminder() {
        cameraMonitor.setDrinkDetectionEnabled(true)
        reminderEscalationController.beginWaiting(for: .drinking)
        petView.showMessageImage(
            named: "hydration-reminder-bubble.png",
            accessibilityText: "喝水时间到！",
            duration: 18
        )
        petView.playAttentionAnimation(strength: 1.35)
        if soundEnabled {
            NSSound(named: "Ping")?.play()
        }
    }

    private func handleDetectedDrink() {
        guard hydrationTracker.confirmDrink() else { return }
        cameraMonitor.setDrinkDetectionEnabled(false)
        reminderEscalationController.resolve(.drinking)
        let minutes = Int(round(hydrationTracker.reminderInterval / 60))
        petView.showMessage(
            "看到你喝水啦！做得好，\(minutes) 分钟后我再提醒你。💧",
            duration: 9
        )
        petView.playAttentionAnimation(strength: 0.75)
        if soundEnabled {
            NSSound(named: "Pop")?.play()
        }
        updateMenu()
    }

    private func restoreReminderIntervalAfterDemo(
        previousInterval: TimeInterval? = nil
    ) {
        guard let previous = previousInterval ?? demoPreviousInterval else {
            return
        }
        demoPreviousInterval = nil
        sittingTracker.reminderInterval = previous
        sittingTracker.restartSession()
    }

    private func handlePetTap() {
        petView.toggleQuickActions()
    }

    private func handlePetQuickAction(_ action: PetView.QuickAction) {
        switch action {
        case .sound:
            break
        case .status:
            presentStatusMenuFromPet()
        case .walk:
            petView.startWalkNow()
        case .calendar:
            showTodayFeishuSchedule()
        case .feed:
            petView.startFeeding()
        }
    }

    private func showTodayFeishuSchedule() {
        let now = Date()
        let controller: TodayScheduleWindowController
        if let existing = todayScheduleWindowController {
            controller = existing
        } else {
            controller = TodayScheduleWindowController()
            todayScheduleWindowController = controller
        }
        controller.showLoading(for: now, relativeTo: petWindow)

        let configuration = feishuConfigurationStore.load()
        guard configuration.hasCredentials else {
            controller.showError(
                "请先从 Kiwi 菜单完成飞书日历设置。",
                for: now
            )
            return
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: dayStart
        ) else {
            controller.showError("无法计算今天的日期范围。", for: now)
            return
        }

        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else { return }
            do {
                let result = try await self.feishuCalendarService
                    .upcomingEvents(
                        configuration: configuration,
                        from: dayStart,
                        to: dayEnd
                    )
                let events = result.events
                    .filter {
                        $0.status != "cancelled"
                            && calendar.isDate(
                                $0.startDate,
                                inSameDayAs: now
                            )
                    }
                    .sorted { $0.startDate < $1.startDate }
                let timeFormatter = DateFormatter()
                timeFormatter.locale = Locale(identifier: "zh_CN")
                timeFormatter.dateFormat = "HH:mm"
                let items = events.map { event in
                    let title = event.title
                        .replacingOccurrences(
                            of: #"\s+"#,
                            with: " ",
                            options: .regularExpression
                        )
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    let hasStarted =
                        !event.isAllDay && event.startDate < now
                    let statusLabel: String
                    if event.isAllDay {
                        statusLabel = "全天日程"
                    } else if hasStarted {
                        statusLabel = "已开始"
                    } else {
                        let minutes = max(
                            1,
                            Int(
                                ceil(
                                    event.startDate
                                        .timeIntervalSince(now) / 60
                                )
                            )
                        )
                        statusLabel = minutes < 60
                            ? "\(minutes) 分钟后"
                            : "待开始"
                    }
                    return TodayScheduleItem(
                        timeLabel: event.isAllDay
                            ? "全天"
                            : timeFormatter.string(
                                from: event.startDate
                            ),
                        title: title.isEmpty ? "未命名日程" : title,
                        statusLabel: statusLabel,
                        hasStarted: hasStarted
                    )
                }
                controller.show(items: items, for: now)
                self.updateFeishuStatus("今日 \(items.count) 项日程")
            } catch {
                let needsAuthorization =
                    self.isFeishuAuthorizationError(error)
                controller.showError(
                    needsAuthorization
                        ? "请先登录飞书，再查看今天的日程。"
                        : "读取失败：\(error.localizedDescription)",
                    for: now
                )
                self.updateFeishuStatus(
                    needsAuthorization ? "待登录飞书" : "同步失败"
                )
            }
        }
    }

    private func previewTodaySchedule() {
        let controller = TodayScheduleWindowController()
        todayScheduleWindowController = controller
        let now = Date()
        controller.showLoading(for: now, relativeTo: petWindow)
        controller.show(
            items: [
                TodayScheduleItem(
                    timeLabel: "09:30",
                    title: "产品晨会与本周任务同步",
                    statusLabel: "已开始",
                    hasStarted: true
                ),
                TodayScheduleItem(
                    timeLabel: "14:00",
                    title: "桌宠动画与交互评审",
                    statusLabel: "待开始",
                    hasStarted: false
                ),
                TodayScheduleItem(
                    timeLabel: "16:30",
                    title: "项目进度会",
                    statusLabel: "待开始",
                    hasStarted: false
                ),
                TodayScheduleItem(
                    timeLabel: "全天",
                    title: "提交设计方案",
                    statusLabel: "全天日程",
                    hasStarted: false
                )
            ],
            for: now
        )
    }

    @objc private func toggleMonitoring() {
        monitoringEnabled.toggle()
        userDefaults.set(monitoringEnabled, forKey: DefaultsKey.monitoringEnabled)
        if monitoringEnabled {
            cameraMonitor.start(requestPermissionIfNeeded: true)
            petView.showMessage("摄像头监测已打开，画面只在本机分析。", duration: 7)
        } else {
            cancelStandingConfirmation()
            reminderEscalationController.resolve(.drinking)
            cameraMonitor.stop()
            restoreReminderIntervalAfterDemo()
            petView.showMessage("摄像头监测已关闭。", duration: 5)
        }
        updateMenu()
    }

    @objc private func toggleCodexTaskMonitoring() {
        codexTaskMonitoringEnabled.toggle()
        userDefaults.set(
            codexTaskMonitoringEnabled,
            forKey: DefaultsKey.codexTaskMonitoringEnabled
        )
        if codexTaskMonitoringEnabled {
            codexLocalTaskMonitor.start()
            codexTaskMonitor.start()
            petView.showMessage(
                "Codex 任务陪伴已打开。每张截图识别后会立即清除，不会保存或上传。",
                duration: 9
            )
        } else {
            codexTaskMonitor.stop()
            codexLocalTaskMonitor.stop()
            cancelCodexTaskTracking()
            petView.showMessage("Codex 任务陪伴已关闭。", duration: 5)
        }
        updateCodexMenu()
    }

    @objc private func previewShortTaskBreak() {
        showTaskBreakPopup(
            recommendation: .shortVideos,
            duration: 6 * 60
        )
    }

    @objc private func previewLongTaskBreak() {
        showTaskBreakPopup(
            recommendation: .knowledgeVideo,
            duration: 12 * 60
        )
    }

    @objc private func toggleCodexMobileNotifications() {
        let enabled = !userDefaults.bool(
            forKey: DefaultsKey.codexMobileNotificationsEnabled
        )
        userDefaults.set(
            enabled,
            forKey: DefaultsKey.codexMobileNotificationsEnabled
        )
        petView.showMessage(
            enabled ? "AI Coding 完成后会发送飞书手机提醒。"
                : "AI Coding 手机提醒已关闭。",
            duration: 6
        )
        if enabled {
            deliverPendingCodexCompletionNotifications()
        }
        updateCodexMenu()
    }

    @objc private func testCodexMobileNotification() {
        sendCodexMobileCompletionNotification(
            duration: 6 * 60 + 18,
            finishedAt: Date(),
            isManualTest: true
        )
    }

    private func sendCodexMobileCompletionNotification(
        duration: TimeInterval,
        finishedAt: Date,
        isManualTest: Bool = false
    ) {
        guard isManualTest
                || userDefaults.bool(
                    forKey: DefaultsKey.codexMobileNotificationsEnabled
                ) else {
            return
        }

        let configuration = feishuConfigurationStore.load()
        guard configuration.hasCredentials,
              !configuration.targetOpenID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            if isManualTest {
                petView.showMessage(
                    "手机提醒尚未配置：请先填写飞书应用信息和提醒对象 Open ID。",
                    duration: 10
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let retryDelays: [UInt64] = [
                0,
                3_000_000_000,
                12_000_000_000
            ]
            var lastError: Error?
            for delay in retryDelays {
                if delay > 0 {
                    try? await Task<Never, Never>.sleep(nanoseconds: delay)
                }
                do {
                    try await self.feishuCalendarService
                        .sendCodexCompletionNotification(
                            configuration: configuration,
                            duration: duration,
                            finishedAt: finishedAt
                        )
                    if isManualTest {
                        self.petView.showMessage(
                            "测试消息已发送，请看一下手机飞书。",
                            duration: 8
                        )
                    }
                    NSLog(
                        "Kiwi delivered Feishu completion notification duration=%.1fs",
                        duration
                    )
                    return
                } catch {
                    lastError = error
                }
            }

            let errorDescription = lastError?.localizedDescription ?? "未知错误"
            NSLog(
                "Kiwi failed Feishu completion notification: %@",
                errorDescription
            )
            self.petView.showMessage(
                isManualTest
                    ? "手机提醒发送失败：\(errorDescription)"
                    : "AI 任务已完成，但飞书提醒发送失败：\(errorDescription)",
                duration: 12
            )
        }
    }

    private func enqueueCodexCompletionNotification(
        id: String,
        duration: TimeInterval,
        finishedAt: Date
    ) {
        guard userDefaults.bool(
            forKey: DefaultsKey.codexMobileNotificationsEnabled
        ) else {
            userDefaults.set(
                "已关闭 · 未发送",
                forKey: DefaultsKey.codexMobileNotificationDeliveryState
            )
            return
        }

        var pending = pendingCodexCompletionNotifications()
        guard !pending.contains(where: { $0.id == id }) else {
            deliverPendingCodexCompletionNotifications()
            return
        }
        pending.append(
            PendingCodexCompletionNotification(
                id: id,
                duration: duration,
                finishedAt: finishedAt
            )
        )
        savePendingCodexCompletionNotifications(pending)
        userDefaults.set(
            "待发送 · \(pending.count) 条",
            forKey: DefaultsKey.codexMobileNotificationDeliveryState
        )
        deliverPendingCodexCompletionNotifications()
    }

    private func pendingCodexCompletionNotifications()
        -> [PendingCodexCompletionNotification] {
        guard let data = userDefaults.data(
            forKey: DefaultsKey.pendingCodexCompletionNotifications
        ) else {
            return []
        }
        return (try? JSONDecoder().decode(
            [PendingCodexCompletionNotification].self,
            from: data
        )) ?? []
    }

    private func savePendingCodexCompletionNotifications(
        _ pending: [PendingCodexCompletionNotification]
    ) {
        if pending.isEmpty {
            userDefaults.removeObject(
                forKey: DefaultsKey.pendingCodexCompletionNotifications
            )
        } else if let data = try? JSONEncoder().encode(pending) {
            userDefaults.set(
                data,
                forKey: DefaultsKey.pendingCodexCompletionNotifications
            )
        }
    }

    private func deliverPendingCodexCompletionNotifications() {
        guard !codexNotificationDeliveryInProgress,
              userDefaults.bool(
                forKey: DefaultsKey.codexMobileNotificationsEnabled
              ),
              let notification = pendingCodexCompletionNotifications().first else {
            return
        }

        let configuration = feishuConfigurationStore.load()
        guard configuration.hasCredentials,
              !configuration.targetOpenID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            userDefaults.set(
                "等待飞书配置 · 已保留待发送消息",
                forKey: DefaultsKey.codexMobileNotificationDeliveryState
            )
            scheduleCodexNotificationRetry()
            return
        }

        codexNotificationRetryWorkItem?.cancel()
        codexNotificationRetryWorkItem = nil
        codexNotificationDeliveryInProgress = true
        userDefaults.set(
            "正在发送…",
            forKey: DefaultsKey.codexMobileNotificationDeliveryState
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.feishuCalendarService
                    .sendCodexCompletionNotification(
                        configuration: configuration,
                        duration: notification.duration,
                        finishedAt: notification.finishedAt
                    )
                var pending = self.pendingCodexCompletionNotifications()
                pending.removeAll { $0.id == notification.id }
                self.savePendingCodexCompletionNotifications(pending)
                let deliveredTime = DateFormatter.localizedString(
                    from: Date(),
                    dateStyle: .none,
                    timeStyle: .medium
                )
                self.userDefaults.set(
                    "已发送 · \(deliveredTime)",
                    forKey: DefaultsKey.codexMobileNotificationDeliveryState
                )
                NSLog(
                    "Kiwi delivered queued Feishu completion id=%@ duration=%.1fs",
                    notification.id,
                    notification.duration
                )
                self.codexNotificationDeliveryInProgress = false
                self.deliverPendingCodexCompletionNotifications()
            } catch {
                self.codexNotificationDeliveryInProgress = false
                self.userDefaults.set(
                    "发送失败，等待重试 · \(error.localizedDescription)",
                    forKey: DefaultsKey.codexMobileNotificationDeliveryState
                )
                NSLog(
                    "Kiwi retained failed Feishu completion id=%@: %@",
                    notification.id,
                    error.localizedDescription
                )
                self.scheduleCodexNotificationRetry()
            }
        }
    }

    private func scheduleCodexNotificationRetry() {
        guard codexNotificationRetryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.codexNotificationRetryWorkItem = nil
            self?.deliverPendingCodexCompletionNotifications()
        }
        codexNotificationRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 60,
            execute: workItem
        )
    }

    @objc private func changeDuration(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        applySittingReminder(minutes: minutes)
    }

    @objc private func changeCustomDuration() {
        let currentMinutes = Int(
            round(sittingTracker.reminderInterval / 60)
        )
        guard let minutes = promptForCustomMinutes(
            title: "自定义散步提醒时间",
            message: "连续坐多久后提醒你站起来散步？",
            currentMinutes: currentMinutes
        ) else {
            return
        }
        applySittingReminder(minutes: minutes)
    }

    private func applySittingReminder(minutes: Int) {
        userDefaults.set(Double(minutes), forKey: DefaultsKey.reminderMinutes)
        sittingTracker.reminderInterval = TimeInterval(minutes * 60)
        sittingTracker.restartSession()
        demoPreviousInterval = nil
        petView.showMessage("好，连续在桌前 \(minutes) 分钟就提醒你。", duration: 7)
        updateMenu()
    }

    @objc private func toggleHydrationReminder() {
        let enabled = !hydrationTracker.isEnabled
        userDefaults.set(enabled, forKey: DefaultsKey.hydrationEnabled)
        hydrationTracker.setEnabled(enabled)

        if enabled {
            monitoringEnabled = true
            userDefaults.set(true, forKey: DefaultsKey.monitoringEnabled)
            hydrationTracker.updatePresence(sittingTracker.isPresent)
            cameraMonitor.start(requestPermissionIfNeeded: true)
            petView.showMessage(
                "喝水提醒已打开。我会用摄像头在本机确认你真的喝了。",
                duration: 9
            )
        } else {
            cameraMonitor.setDrinkDetectionEnabled(false)
            reminderEscalationController.resolve(.drinking)
            petView.showMessage("喝水提醒已关闭。", duration: 5)
        }
        updateMenu()
    }

    @objc private func changeHydrationDuration(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        applyHydrationReminder(minutes: minutes)
    }

    @objc private func changeCustomHydrationDuration() {
        let currentMinutes = Int(
            round(hydrationTracker.reminderInterval / 60)
        )
        guard let minutes = promptForCustomMinutes(
            title: "自定义喝水提醒时间",
            message: "每隔多久提醒你喝水？",
            currentMinutes: currentMinutes
        ) else {
            return
        }
        applyHydrationReminder(minutes: minutes)
    }

    private func applyHydrationReminder(minutes: Int) {
        userDefaults.set(
            Double(minutes),
            forKey: DefaultsKey.hydrationMinutes
        )
        hydrationTracker.reminderInterval = TimeInterval(minutes * 60)
        petView.showMessage(
            "好，每 \(minutes) 分钟提醒喝水；检测到喝水动作后重新计时。",
            duration: 8
        )
        updateMenu()
    }

    private func promptForCustomMinutes(
        title: String,
        message: String,
        currentMinutes: Int
    ) -> Int? {
        let input = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 240, height: 24)
        )
        input.stringValue = String(currentMinutes)
        input.placeholderString = "1–720 分钟"

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText =
            "\(message)\n请输入 1–720 之间的整数分钟数。"
        alert.alertStyle = .informational
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input
        input.selectText(nil)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        guard let minutes = ReminderIntervalInput.parseMinutes(
            input.stringValue
        ) else {
            let errorAlert = NSAlert()
            errorAlert.messageText = "时间格式不正确"
            errorAlert.informativeText =
                "请输入 1–720 之间的整数分钟数。"
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "知道了")
            errorAlert.runModal()
            return nil
        }
        return minutes
    }

    @objc private func startHydrationDemo() {
        userDefaults.set(true, forKey: DefaultsKey.hydrationEnabled)
        hydrationTracker.setEnabled(true)
        hydrationTracker.requestDrinkNow()
        monitoringEnabled = true
        userDefaults.set(true, forKey: DefaultsKey.monitoringEnabled)
        cameraMonitor.start(requestPermissionIfNeeded: true)
        showHydrationReminder()
        updateMenu()
    }

    @objc private func startDemo() {
        monitoringEnabled = true
        userDefaults.set(true, forKey: DefaultsKey.monitoringEnabled)
        cameraMonitor.start(requestPermissionIfNeeded: true)

        if demoPreviousInterval == nil {
            demoPreviousInterval = sittingTracker.reminderInterval
        }
        sittingTracker.reminderInterval = 10
        sittingTracker.restartSession()
        petView.showMessage("体验模式：保持在镜头前，检测到你后 10 秒提醒。", duration: 8)
        updateMenu()
    }

    @objc private func startWalk() {
        petView.startWalkNow()
        petView.showMessage("出发散步！", duration: 3)
    }

    @objc private func previewPerformance() {
        ensurePetIsVisible()
        petView.playPerformanceNow()
    }

    @objc private func showKiwi() {
        NSApp.unhideWithoutActivation()
        ensurePetIsVisible()
        petView.playAttentionAnimation(strength: 0.8)
    }

    @objc private func openFeishuSettings() {
        let configuration = feishuConfigurationStore.load()
        let needsStableCredentialMigration =
            !configuration.appID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                && configuration.appSecret.isEmpty
        if feishuSettingsController == nil {
            let controller = FeishuSettingsWindowController(configuration: configuration)
            controller.onSave = { [weak self] configuration, shouldTest in
                self?.saveFeishuConfiguration(configuration, shouldTest: shouldTest)
            }
            controller.onAuthorize = { [weak self] configuration in
                self?.saveAndAuthorizeFeishu(configuration)
            }
            feishuSettingsController = controller
        } else {
            feishuSettingsController?.update(configuration: configuration)
        }
        NSApp.activate(ignoringOtherApps: true)
        feishuSettingsController?.showWindow(nil)
        feishuSettingsController?.window?.center()
        feishuSettingsController?.window?.makeKeyAndOrderFront(nil)
        if needsStableCredentialMigration {
            feishuSettingsController?.setStatus(
                "请重新粘贴一次飞书 App Secret 并保存；"
                    + "不需要输入 Mac 密码，保存后会立即补发等待中的任务提醒。",
                isError: true
            )
        }
    }

    private func saveFeishuConfiguration(
        _ configuration: FeishuConfiguration,
        shouldTest: Bool
    ) {
        do {
            try feishuConfigurationStore.save(configuration)
            updateFeishuStatus(configuration.hasCredentials ? "已保存" : "未配置")
            updateFeishuAuthorizationMenu(configuration: configuration)
            updateFeishuReminderRule(configuration: configuration)
            feishuSettingsController?.setStatus(
                configuration.hasCredentials
                    ? "设置已保存；只会在设定的提前窗口内提醒。"
                    : "设置已清空。"
            )
            if configuration.hasCredentials {
                deliverPendingCodexCompletionNotifications()
                syncFeishuCalendar(showFeedback: false)
            }
            if shouldTest {
                syncFeishuCalendar(showFeedback: true)
            }
        } catch {
            feishuSettingsController?.setStatus(error.localizedDescription, isError: true)
        }
    }

    private func saveAndAuthorizeFeishu(_ configuration: FeishuConfiguration) {
        do {
            try feishuConfigurationStore.save(configuration)
            updateFeishuAuthorizationMenu(configuration: configuration)
            beginFeishuAuthorization(configuration: configuration)
        } catch {
            feishuSettingsController?.setStatus(
                error.localizedDescription,
                isError: true
            )
        }
    }

    @objc private func authorizeFeishuUser() {
        let configuration = feishuConfigurationStore.load()
        guard configuration.hasCredentials else {
            openFeishuSettings()
            feishuSettingsController?.setStatus(
                "请先填写并保存 App ID 和 App Secret。",
                isError: true
            )
            return
        }
        beginFeishuAuthorization(configuration: configuration)
    }

    private func beginFeishuAuthorization(
        configuration: FeishuConfiguration
    ) {
        guard !feishuAuthorizationInProgress else {
            feishuSettingsController?.setStatus(
                "授权正在进行，请在浏览器中完成操作。"
            )
            return
        }

        feishuAuthorizationInProgress = true
        updateFeishuStatus("等待登录…")
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = FeishuOAuthCallbackServer()
        feishuCallbackServer = server

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await server.start(expectedState: state)
                let authorizationURL = try self.feishuOAuthService.authorizationURL(
                    configuration: configuration,
                    state: state
                )
                self.feishuSettingsController?.setStatus(
                    "已打开飞书授权页，请确认授权后返回 Kiwi。"
                )
                self.petView.showMessage(
                    "请在浏览器完成飞书授权，我就能看到日程标题啦。",
                    duration: 14
                )
                guard NSWorkspace.shared.open(authorizationURL) else {
                    throw FeishuOAuthError.invalidAuthorizationURL
                }

                let code = try await server.waitForCode()
                let authorization = try await self.feishuOAuthService
                    .exchangeAuthorizationCode(
                        code,
                        configuration: configuration
                    )

                var updatedConfiguration = configuration
                let expectedOpenID = configuration.targetOpenID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !expectedOpenID.isEmpty,
                   expectedOpenID != authorization.openID {
                    self.feishuOAuthService.clearAuthorization()
                    throw FeishuOAuthError.wrongUser(
                        expected: expectedOpenID,
                        actual: authorization.openID
                    )
                }
                if expectedOpenID.isEmpty {
                    updatedConfiguration.targetOpenID = authorization.openID
                    try self.feishuConfigurationStore.save(updatedConfiguration)
                    self.feishuSettingsController?.update(
                        configuration: updatedConfiguration
                    )
                }

                self.feishuAuthorizationInProgress = false
                self.feishuCallbackServer = nil
                self.updateFeishuAuthorizationMenu(
                    configuration: updatedConfiguration
                )
                self.updateFeishuStatus("授权成功")
                self.feishuSettingsController?.setStatus(
                    "已授权 \(authorization.userName)，正在读取真实日程标题。"
                )
                self.petView.showMessage(
                    "飞书授权成功！现在我能准确告诉你下一项任务了。",
                    duration: 10
                )
                self.syncFeishuCalendar(showFeedback: true)
                return
            } catch {
                server.stop()
                self.feishuAuthorizationInProgress = false
                self.feishuCallbackServer = nil
                self.updateFeishuStatus("授权失败")
                self.updateFeishuAuthorizationMenu(configuration: configuration)
                let message = error.localizedDescription
                self.feishuSettingsController?.setStatus(message, isError: true)
                self.petView.showMessage(message, duration: 14)
            }
        }
    }

    @objc private func syncFeishuNow() {
        syncFeishuCalendar(showFeedback: true)
    }

    @objc private func createFeishuTestReminder() {
        guard !feishuSyncInProgress else { return }
        let configuration = feishuConfigurationStore.load()
        guard configuration.hasCredentials else {
            openFeishuSettings()
            feishuSettingsController?.setStatus("请先配置飞书连接。", isError: true)
            return
        }
        guard !configuration.targetOpenID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            openFeishuSettings()
            feishuSettingsController?.setStatus(
                "请填写提醒对象 Open ID，才能把日程邀请发给那个人。",
                isError: true
            )
            return
        }

        feishuSyncInProgress = true
        updateFeishuStatus("创建测试提醒…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let event = try await self.feishuCalendarService.createTestReminder(
                    configuration: configuration
                )
                self.cachedFeishuEvents.removeAll {
                    self.eventAlertKey($0) == self.eventAlertKey(event)
                }
                self.cachedFeishuEvents.append(event)
                self.alertedFeishuEvents[self.eventAlertKey(event)] = Date()
                self.ensurePetIsVisible()
                self.petView.showWorkAlert(
                    details: self.feishuEventDescription(event, now: Date())
                )
                self.updateFeishuStatus("测试提醒已创建")
                self.feishuSettingsController?.setStatus(
                    "测试日程已创建；会按重复间隔继续自动播报。"
                )
            } catch {
                let message = error.localizedDescription
                self.updateFeishuStatus("测试失败")
                self.petView.showMessage("创建飞书提醒失败：\(message)", duration: 12)
                self.feishuSettingsController?.setStatus(message, isError: true)
            }
            self.feishuSyncInProgress = false
        }
    }

    @objc private func previewFeishuWorkAlert() {
        ensurePetIsVisible()
        petView.showWorkAlert(details: "16:30「项目进度会」5 分钟后开始")
    }

    @objc private func openCameraSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openScreenCaptureSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func updateMenu() {
        updateCodexMenu()
        cameraToggleItem?.state = monitoringEnabled ? .on : .off
        cameraSettingsItem?.isHidden = cameraStatus != .denied

        let selectedMinutes = Int(round(sittingTracker.reminderInterval / 60))
        for item in durationItems {
            item.state = (item.representedObject as? Int) == selectedMinutes ? .on : .off
        }
        let usesCustomDuration = !durationItems.contains {
            ($0.representedObject as? Int) == selectedMinutes
        }
        customDurationItem?.state = usesCustomDuration ? .on : .off
        customDurationItem?.title = usesCustomDuration
            ? "自定义…（当前 \(selectedMinutes) 分钟）"
            : "自定义…"

        hydrationToggleItem?.state =
            hydrationTracker.isEnabled ? .on : .off
        let selectedHydrationMinutes = Int(
            round(hydrationTracker.reminderInterval / 60)
        )
        for item in hydrationDurationItems {
            item.state =
                (item.representedObject as? Int)
                == selectedHydrationMinutes ? .on : .off
        }
        let usesCustomHydrationDuration =
            !hydrationDurationItems.contains {
                ($0.representedObject as? Int)
                    == selectedHydrationMinutes
            }
        customHydrationDurationItem?.state =
            usesCustomHydrationDuration ? .on : .off
        customHydrationDurationItem?.title =
            usesCustomHydrationDuration
                ? "自定义…（当前 \(selectedHydrationMinutes) 分钟）"
                : "自定义…"
        if !hydrationTracker.isEnabled {
            hydrationStatusItem?.title = "喝水提醒：已关闭"
        } else if hydrationTracker.isAwaitingDrink {
            hydrationStatusItem?.title = cameraStatus == .running
                ? "喝水提醒：等你喝水 · 摄像头确认中"
                : "喝水提醒：等你喝水 · 等待摄像头"
        } else if let remaining =
            hydrationTracker.timeUntilNextAction() {
            hydrationStatusItem?.title =
                "喝水提醒：\(formatDuration(remaining))后"
        } else {
            hydrationStatusItem?.title =
                monitoringEnabled
                ? "喝水提醒：等待检测到你"
                : "喝水提醒：需要开启摄像头"
        }

        guard monitoringEnabled else {
            cameraStatusItem?.title = "监测已关闭"
            return
        }

        switch cameraStatus {
        case .stopped:
            cameraStatusItem?.title = "摄像头未启动"
        case .permissionRequired:
            cameraStatusItem?.title = "摄像头未启用"
        case .requestingPermission:
            cameraStatusItem?.title = "等待摄像头权限…"
        case .starting:
            cameraStatusItem?.title = "正在启动摄像头…"
        case .running:
            if isAwaitingStandingConfirmation {
                cameraStatusItem?.title = standingDetectionStatusTitle()
            } else if sittingTracker.isPresent {
                let elapsed = formatDuration(sittingTracker.elapsed())
                let remaining = sittingTracker.timeUntilNextReminder()
                    .map(formatDuration) ?? "稍后"
                cameraStatusItem?.title =
                    "已在桌前 \(elapsed) · \(remaining)后提醒"
            } else {
                cameraStatusItem?.title = "正在等待检测到你"
            }
        case .denied:
            cameraStatusItem?.title = "摄像头监测不可用"
        case .unavailable(let reason):
            cameraStatusItem?.title = "摄像头不可用：\(reason)"
        }
    }

    private func standingDetectionStatusTitle() -> String {
        guard let progress = standingDetectionProgress else {
            return "久坐提醒：Apple Vision 正在寻找人体骨骼…"
        }

        let mode = progress.preset == .nearHead
            ? "近距 3D 骨骼"
            : "远距 3D 骨骼"
        let seconds = min(
            Int(progress.requiredDuration),
            Int(progress.confirmedDuration.rounded(.down))
        )
        let counter =
            "\(seconds)/\(Int(progress.requiredDuration)) 秒"
        switch progress.observation {
        case .standing:
            return "站立识别：Apple Vision \(mode) · "
                + "已确认 \(counter)"
        case .notStanding:
            if seconds > 0 {
                return "站立识别：已保留 \(counter) · 正在复核姿势"
            }
            return "站立识别：Apple Vision \(mode) · 请站直并保持"
        case .unavailable:
            if seconds > 0 {
                return "站立识别：已保留 \(counter) · 画面不清，计时暂停"
            }
            return progress.preset == .nearHead
                ? "站立识别：请让上半身保持在摄像头内"
                : "站立识别：请让躯干保持在摄像头内"
        }
    }

    private func updateCodexMenu() {
        codexToggleItem?.state = codexTaskMonitoringEnabled ? .on : .off
        codexMobileNotificationItem?.state = userDefaults.bool(
            forKey: DefaultsKey.codexMobileNotificationsEnabled
        ) ? .on : .off
        codexScreenSettingsItem?.isHidden =
            codexTaskMonitor.status != .permissionRequired
                || codexLocalTaskSignalAvailable

        guard codexTaskMonitoringEnabled else {
            codexMenuRootItem?.title = "Codex 画面监测（已关闭）"
            codexStatusItem?.title = "画面监测：已关闭"
            codexTaskStatusItem?.title = "任务：不检测"
            return
        }

        switch codexTaskMonitor.status {
        case .stopped:
            codexMenuRootItem?.title = "Codex 画面监测（等待启动）"
            codexStatusItem?.title = "画面监测：等待启动"
            codexTaskStatusItem?.title = "任务：暂无"
        case .permissionRequired:
            codexMenuRootItem?.title = "Codex 画面监测（需要权限）"
            codexStatusItem?.title = "画面监测：需要屏幕录制权限"
            codexTaskStatusItem?.title = "任务：尚未检测"
        case .lookingForCodex:
            codexMenuRootItem?.title = "Codex 画面监测（等待窗口）"
            codexStatusItem?.title = "画面监测：已开启 · 等待 Codex 窗口"
            codexTaskStatusItem?.title = "任务：暂无"
        case .watching:
            codexMenuRootItem?.title = "Codex 画面监测（运行中）"
            codexStatusItem?.title = codexLocalTaskSignalAvailable
                ? "任务事件 + 画面监测：每 5 秒"
                : "画面监测：运行中 · 每 5 秒"
            codexTaskStatusItem?.title = "任务：暂无 · 普通画面变化会忽略"
        case .timing(let startedAt):
            let elapsed = max(0, Date().timeIntervalSince(startedAt))
            codexMenuRootItem?.title = "Codex 画面监测（任务中）"
            codexStatusItem?.title = "画面监测：持续检查 · 每 5 秒"
            if elapsed < CodexVideoTiming.shortVideoCheckpoint {
                codexTaskStatusItem?.title =
                    "任务：处理中 \(formatDuration(elapsed)) · 抖音播放中"
            } else if elapsed <= CodexVideoTiming.forceKnowledgeVideo {
                codexTaskStatusItem?.title =
                    "任务：已超过 5 分钟 · 抖音继续播放"
            } else {
                codexTaskStatusItem?.title =
                    "任务：处理中 \(formatDuration(elapsed)) · 已强制切换 B 站"
            }
        case .unavailable(let reason):
            codexMenuRootItem?.title = "Codex 画面监测（不可用）"
            codexStatusItem?.title = "画面监测：暂不可用 · \(reason)"
            codexTaskStatusItem?.title = "任务：无法检测"
        }

        if codexLocalTaskSignalAvailable {
            codexMenuRootItem?.title = "Codex 任务监测（运行中）"
            switch codexTaskMonitor.status {
            case .watching, .timing:
                codexStatusItem?.title =
                    "本地任务事件 + 画面兜底：每 5 秒"
            case .permissionRequired:
                codexStatusItem?.title =
                    "本地任务检测：每 5 秒"
            case .lookingForCodex:
                codexStatusItem?.title =
                    "本地任务事件：每 5 秒 · 等待 Codex 画面"
            case .unavailable:
                codexStatusItem?.title =
                    "本地任务事件：每 5 秒 · 画面兜底暂不可用"
            case .stopped:
                codexStatusItem?.title =
                    "本地任务事件：每 5 秒 · 画面兜底待启动"
            }
        }

        if let startedAt = codexActiveTaskStartedAt {
            let elapsed = max(0, Date().timeIntervalSince(startedAt))
            codexMenuRootItem?.title = "Codex 任务监测（任务中）"
            if elapsed < CodexVideoTiming.shortVideoCheckpoint {
                codexTaskStatusItem?.title =
                    "任务：处理中 \(formatDuration(elapsed)) · 抖音播放中"
            } else if elapsed <= CodexVideoTiming.forceKnowledgeVideo {
                codexTaskStatusItem?.title =
                    "任务：已超过 5 分钟 · 抖音继续播放"
            } else {
                codexTaskStatusItem?.title =
                    "任务：处理中 \(formatDuration(elapsed)) · 已强制切换 B 站"
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let remainder = value % 60
        if hours > 0 {
            return "\(hours)小时\(minutes)分"
        }
        if minutes > 0 {
            return "\(minutes)分\(remainder)秒"
        }
        return "\(remainder)秒"
    }
}
