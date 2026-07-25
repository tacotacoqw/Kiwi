import AppKit
import QuartzCore

final class FeedingDesktopWindow: NSPanel {
    private let itemView: FeedingDesktopItemView

    var onClick: (() -> Void)? {
        didSet { itemView.onClick = onClick }
    }
    var onDrop: ((NSRect) -> Void)? {
        didSet {
            itemView.onDrop = { [weak self] in
                guard let self else { return }
                self.onDrop?(self.frame)
            }
        }
    }

    init(
        frame: NSRect,
        image: NSImage,
        draggable: Bool,
        accessibilityLabel: String
    ) {
        itemView = FeedingDesktopItemView(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        isReleasedWhenClosed = false
        animationBehavior = .none
        itemView.image = image
        itemView.imageAlignment = .alignCenter
        itemView.imageScaling = .scaleProportionallyUpOrDown
        itemView.imageFrameStyle = .none
        itemView.wantsLayer = true
        itemView.layer?.masksToBounds = false
        itemView.isDraggable = draggable
        itemView.setAccessibilityElement(true)
        itemView.setAccessibilityRole(.image)
        itemView.setAccessibilityLabel(accessibilityLabel)
        contentView = itemView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(
        image: NSImage,
        draggable: Bool,
        accessibilityLabel: String
    ) {
        itemView.image = image
        itemView.isDraggable = draggable
        itemView.isInteractionEnabled = draggable
        itemView.setAccessibilityLabel(accessibilityLabel)
        itemView.needsDisplay = true
    }

    func setInteractionEnabled(_ enabled: Bool) {
        itemView.isInteractionEnabled = enabled
    }

    func animateIn(reduceMotion: Bool) {
        alphaValue = 1
        guard !reduceMotion, let contentLayer = itemView.layer else { return }
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(
            caTransform3D: CATransform3DMakeScale(0.88, 0.88, 1)
        )
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.duration = 0.22
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        contentLayer.add(scale, forKey: "feedingWindowAppear")

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.18
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
        contentLayer.add(opacity, forKey: "feedingWindowOpacity")
    }

    func fadeOut(
        duration: TimeInterval,
        reduceMotion: Bool,
        completion: @escaping () -> Void
    ) {
        guard !reduceMotion, duration > 0 else {
            alphaValue = 0
            close()
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.close()
            completion()
        }
    }

    func animateToward(
        screenPoint: NSPoint,
        duration: TimeInterval,
        reduceMotion: Bool,
        completion: @escaping () -> Void
    ) {
        let destination = NSPoint(
            x: screenPoint.x - frame.width / 2,
            y: screenPoint.y - frame.height / 2
        )
        guard !reduceMotion, duration > 0 else {
            setFrameOrigin(destination)
            alphaValue = 0
            close()
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrameOrigin(destination)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.close()
            completion()
        }
    }
}

private final class FeedingDesktopItemView: NSImageView {
    var isDraggable = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var isInteractionEnabled = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onClick: (() -> Void)?
    var onDrop: (() -> Void)?

    private var mouseDownLocation: NSPoint?
    private var windowOriginOnMouseDown: NSPoint?
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        if !isInteractionEnabled {
            cursor = .arrow
        } else {
            cursor = isDraggable ? .openHand : .pointingHand
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginOnMouseDown = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractionEnabled,
              isDraggable,
              let window,
              let mouseDownLocation,
              let windowOriginOnMouseDown else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(
            x: current.x - mouseDownLocation.x,
            y: current.y - mouseDownLocation.y
        )
        if !didDrag, hypot(delta.x, delta.y) > 3 {
            didDrag = true
            NSCursor.closedHand.set()
        }
        guard didDrag else { return }

        let proposed = NSPoint(
            x: windowOriginOnMouseDown.x + delta.x,
            y: windowOriginOnMouseDown.y + delta.y
        )
        let screen = NSScreen.screens.first {
            $0.frame.contains(current)
        } ?? window.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.setFrameOrigin(proposed)
            return
        }
        window.setFrameOrigin(
            NSPoint(
                x: min(
                    max(proposed.x, visibleFrame.minX),
                    visibleFrame.maxX - window.frame.width
                ),
                y: min(
                    max(proposed.y, visibleFrame.minY),
                    visibleFrame.maxY - window.frame.height
                )
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        if didDrag {
            NSCursor.openHand.set()
            onDrop?()
        } else {
            onClick?()
        }
        mouseDownLocation = nil
        windowOriginOnMouseDown = nil
        didDrag = false
    }
}
