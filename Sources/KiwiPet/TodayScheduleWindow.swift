import AppKit

struct TodayScheduleItem {
    let timeLabel: String
    let title: String
    let statusLabel: String
    let hasStarted: Bool
}

final class TodayScheduleWindowController:
    NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private static let panelWidth: CGFloat = 372

    private let titleLabel = NSTextField(labelWithString: "今天的飞书日程")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSButton(title: "", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [TodayScheduleItem] = []
    private weak var anchorWindow: NSWindow?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.panelWidth,
                height: 470
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        configurePanel(panel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showLoading(for date: Date, relativeTo anchorWindow: NSWindow) {
        self.anchorWindow = anchorWindow
        items = []
        tableView.reloadData()
        updateHeader(for: date, count: nil)
        showMessage("正在读取今天的全部日程…")
        resizeAndPosition(height: 430)
        window?.orderFrontRegardless()
    }

    func show(items: [TodayScheduleItem], for date: Date) {
        self.items = items
        tableView.reloadData()
        updateHeader(for: date, count: items.count)
        if items.isEmpty {
            showMessage("今天没有飞书日程")
            resizeAndPosition(height: 430)
        } else {
            messageLabel.isHidden = true
            scrollView.isHidden = false
            let height = min(
                560,
                max(450, 230 + CGFloat(items.count) * 55)
            )
            resizeAndPosition(height: height)
            tableView.scrollRowToVisible(0)
        }
        window?.orderFrontRegardless()
    }

    func showError(_ message: String, for date: Date) {
        items = []
        tableView.reloadData()
        updateHeader(for: date, count: nil)
        showMessage(message)
        resizeAndPosition(height: 430)
        window?.orderFrontRegardless()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("schedule-row")
        let cell: TodayScheduleCellView
        if let reusable = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? TodayScheduleCellView {
            cell = reusable
        } else {
            cell = TodayScheduleCellView()
            cell.identifier = identifier
        }
        cell.configure(with: items[row], isLast: row == items.count - 1)
        return cell
    }

    private func configurePanel(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = root

        let backing = NSView()
        backing.wantsLayer = true
        backing.layer?.backgroundColor = Self.borderGreen.cgColor
        backing.layer?.cornerRadius = 34
        backing.layer?.cornerCurve = .continuous

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Self.cardYellow.cgColor
        card.layer?.cornerRadius = 31
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(
            calibratedRed: 0.78,
            green: 0.84,
            blue: 0.57,
            alpha: 0.48
        ).cgColor

        let peekImageView = NSImageView()
        peekImageView.image = AssetLoader.frame(named: "task-break-peek.png")
        peekImageView.imageScaling = .scaleProportionallyUpOrDown
        peekImageView.imageAlignment = .alignCenter

        let fruitLabel = NSTextField(labelWithString: "🥝")
        fruitLabel.font = .systemFont(ofSize: 27)
        fruitLabel.alignment = .center

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = Self.inkColor
        subtitleLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        subtitleLabel.textColor = Self.secondaryInkColor

        countLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        countLabel.isBordered = false
        countLabel.alignment = .center
        countLabel.contentTintColor = Self.inkColor
        countLabel.imagePosition = .noImage
        countLabel.focusRingType = .none
        countLabel.wantsLayer = true
        countLabel.layer?.backgroundColor = Self.buttonGreen.cgColor
        countLabel.layer?.cornerRadius = 13
        countLabel.layer?.cornerCurve = .continuous

        let contentWell = NSView()
        contentWell.wantsLayer = true
        contentWell.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.985,
            alpha: 0.98
        ).cgColor
        contentWell.layer?.cornerRadius = 25
        contentWell.layer?.cornerCurve = .continuous

        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("schedule")
        )
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = 51
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = TodayScheduleScroller()
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentInsets = NSEdgeInsets(
            top: 8,
            left: 8,
            bottom: 8,
            right: 8
        )

        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = Self.secondaryInkColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 3

        let topButton = makePillButton(
            title: "回到顶部",
            action: #selector(scrollToTop)
        )
        let closeButton = makePillButton(
            title: "关闭",
            action: #selector(closeSchedule)
        )

        [peekImageView, backing, card].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        [fruitLabel, titleLabel, subtitleLabel, countLabel, contentWell,
         topButton, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        [scrollView, messageLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentWell.addSubview($0)
        }

        NSLayoutConstraint.activate([
            peekImageView.topAnchor.constraint(equalTo: root.topAnchor),
            peekImageView.centerXAnchor.constraint(
                equalTo: root.centerXAnchor,
                constant: 50
            ),
            peekImageView.widthAnchor.constraint(equalToConstant: 168),
            peekImageView.heightAnchor.constraint(equalToConstant: 84),

            backing.topAnchor.constraint(equalTo: root.topAnchor, constant: 54),
            backing.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            backing.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backing.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -9),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: 9),

            fruitLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 21),
            fruitLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 21),
            fruitLabel.widthAnchor.constraint(equalToConstant: 38),
            fruitLabel.heightAnchor.constraint(equalToConstant: 38),

            titleLabel.leadingAnchor.constraint(
                equalTo: fruitLabel.trailingAnchor,
                constant: 9
            ),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: countLabel.leadingAnchor,
                constant: -8
            ),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: 3
            ),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: countLabel.leadingAnchor,
                constant: -8
            ),

            countLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -21),
            countLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            countLabel.widthAnchor.constraint(equalToConstant: 72),
            countLabel.heightAnchor.constraint(equalToConstant: 27),

            contentWell.topAnchor.constraint(equalTo: card.topAnchor, constant: 78),
            contentWell.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            contentWell.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            contentWell.bottomAnchor.constraint(equalTo: topButton.topAnchor, constant: -18),

            scrollView.topAnchor.constraint(equalTo: contentWell.topAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: contentWell.leadingAnchor, constant: 5),
            scrollView.trailingAnchor.constraint(equalTo: contentWell.trailingAnchor, constant: -5),
            scrollView.bottomAnchor.constraint(equalTo: contentWell.bottomAnchor, constant: -5),

            messageLabel.centerXAnchor.constraint(equalTo: contentWell.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: contentWell.centerYAnchor),
            messageLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentWell.leadingAnchor,
                constant: 25
            ),
            messageLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: contentWell.trailingAnchor,
                constant: -25
            ),

            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            closeButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 74),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            topButton.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor,
                constant: -10
            ),
            topButton.bottomAnchor.constraint(equalTo: closeButton.bottomAnchor),
            topButton.widthAnchor.constraint(equalToConstant: 84),
            topButton.heightAnchor.constraint(equalTo: closeButton.heightAnchor)
        ])
    }

    private func makePillButton(
        title: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = Self.inkColor
        button.wantsLayer = true
        button.layer?.backgroundColor = Self.buttonGreen.cgColor
        button.layer?.cornerRadius = 14
        button.layer?.cornerCurve = .continuous
        return button
    }

    private func showMessage(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        scrollView.isHidden = true
    }

    private func updateHeader(for date: Date, count: Int?) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        subtitleLabel.stringValue = formatter.string(from: date)
        countLabel.title = count.map { "\($0) 项" } ?? "读取中"
    }

    private func resizeAndPosition(height: CGFloat) {
        guard let panel = window, let anchorWindow else { return }
        panel.setContentSize(
            NSSize(width: Self.panelWidth, height: height)
        )
        let screen = anchorWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let gap: CGFloat = 12
        let characterHalfWidth = PetView.characterSize.width / 2
        var x = anchorWindow.frame.midX + characterHalfWidth + gap
        if x + Self.panelWidth > visible.maxX - gap {
            x = anchorWindow.frame.midX
                - characterHalfWidth
                - Self.panelWidth
                - gap
        }
        x = min(
            max(x, visible.minX + gap),
            visible.maxX - Self.panelWidth - gap
        )
        let idealY = anchorWindow.frame.midY - height / 2
        let y = min(
            max(idealY, visible.minY + gap),
            visible.maxY - height - gap
        )
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func scrollToTop() {
        guard !items.isEmpty else { return }
        tableView.scrollRowToVisible(0)
    }

    @objc private func closeSchedule() {
        close()
    }

    private static let borderGreen = NSColor(
        calibratedRed: 0.76,
        green: 0.82,
        blue: 0.54,
        alpha: 1
    )
    private static let cardYellow = NSColor(
        calibratedRed: 1.00,
        green: 0.99,
        blue: 0.79,
        alpha: 1
    )
    private static let buttonGreen = NSColor(
        calibratedRed: 0.78,
        green: 0.84,
        blue: 0.58,
        alpha: 1
    )
    private static let inkColor = NSColor(
        calibratedRed: 0.25,
        green: 0.29,
        blue: 0.20,
        alpha: 1
    )
    private static let secondaryInkColor = NSColor(
        calibratedRed: 0.39,
        green: 0.44,
        blue: 0.31,
        alpha: 1
    )
}

private final class TodayScheduleScroller: NSScroller {
    override func drawKnobSlot(
        in slotRect: NSRect,
        highlight flag: Bool
    ) {}

    override func drawKnob() {
        let knobRect = rect(for: .knob).insetBy(dx: 3, dy: 1)
        guard knobRect.width > 0, knobRect.height > 0 else { return }
        NSColor(
            calibratedRed: 0.47,
            green: 0.54,
            blue: 0.34,
            alpha: 0.64
        ).setFill()
        NSBezierPath(
            roundedRect: knobRect,
            xRadius: knobRect.width / 2,
            yRadius: knobRect.width / 2
        ).fill()
    }
}

private final class TodayScheduleCellView: NSTableCellView {
    private let timeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let separator = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
        statusLabel.font = .systemFont(ofSize: 8.5, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = NSColor(
            calibratedRed: 0.25,
            green: 0.29,
            blue: 0.20,
            alpha: 1
        )
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(
            calibratedRed: 0.82,
            green: 0.85,
            blue: 0.72,
            alpha: 0.42
        ).cgColor

        [timeLabel, statusLabel, titleLabel, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            timeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            timeLabel.widthAnchor.constraint(equalToConstant: 58),

            statusLabel.leadingAnchor.constraint(equalTo: timeLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(
                equalTo: timeLabel.bottomAnchor,
                constant: 2
            ),

            titleLabel.leadingAnchor.constraint(
                equalTo: timeLabel.trailingAnchor,
                constant: 10
            ),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(with item: TodayScheduleItem, isLast: Bool) {
        timeLabel.stringValue = item.timeLabel
        titleLabel.stringValue = item.title
        statusLabel.stringValue = item.statusLabel
        separator.isHidden = isLast
        let alpha: CGFloat = item.hasStarted ? 0.58 : 1
        timeLabel.alphaValue = alpha
        titleLabel.alphaValue = alpha
        statusLabel.textColor = item.hasStarted
            ? .secondaryLabelColor
            : NSColor(
                calibratedRed: 0.40,
                green: 0.55,
                blue: 0.16,
                alpha: 1
            )
        toolTip = item.title
    }
}
