import AppKit
import QuartzCore

/// Largest rect of `size`'s aspect ratio centred in `container`.
func aspectFit(_ size: CGSize, in container: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return .zero }
    let scale = min(container.width / size.width, container.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: container.midX - w / 2, y: container.midY - h / 2, width: w, height: h)
}

/// Borderless full-screen window used for both the board and the HDMI output.
final class ProductionWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onDeleteKey: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: NSRect(origin: .zero, size: screen.frame.size),
                   styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?() // Esc
        case 51, 117: onDeleteKey?() // Backspace, Forward Delete
        default: super.keyDown(with: event)
        }
    }
}

/// The writing surface shown on the touchscreen: a bordered, aspect-locked board.
final class BoardView: NSView {
    private let canvas: Canvas
    private let padding: CGFloat
    /// Screen areas to keep clear, e.g. the MacBook camera notch.
    var keepClearInsets = NSEdgeInsetsZero { didSet { needsLayout = true } }
    private let frameLayer = CALayer()
    private let contentLayer = CALayer()
    /// Board area including its border, in view coordinates.
    var framedBoardRect: CGRect { boardRect.insetBy(dx: -borderWidth, dy: -borderWidth) }
    var onLayout: (() -> Void)?
    private var boardRect: CGRect = .zero
    private var drawing = false
    private let borderWidth: CGFloat = 3

    init(canvas: Canvas, padding: CGFloat) {
        self.canvas = canvas
        self.padding = padding
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.hatchPattern().cgColor

        frameLayer.backgroundColor = NSColor.black.cgColor
        frameLayer.borderColor = NSColor(white: 1, alpha: 0.6).cgColor
        frameLayer.borderWidth = borderWidth
        contentLayer.contentsGravity = .resize
        contentLayer.magnificationFilter = .linear
        contentLayer.minificationFilter = .trilinear
        frameLayer.addSublayer(contentLayer)
        layer?.addSublayer(frameLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Dark diagonal hatching that marks the area outside the board as not drawable.
    private static func hatchPattern() -> NSColor {
        let tile: CGFloat = 32
        let image = NSImage(size: NSSize(width: tile, height: tile), flipped: false) { rect in
            NSColor(white: 0.06, alpha: 1).setFill()
            rect.fill()
            let path = NSBezierPath()
            // Two segments so the stripes join seamlessly across tiles.
            let o: CGFloat = 8 // overdraw so wide stripes join seamlessly across tiles
            path.move(to: NSPoint(x: -o, y: o)); path.line(to: NSPoint(x: o, y: -o))
            path.move(to: NSPoint(x: -o, y: tile + o)); path.line(to: NSPoint(x: tile + o, y: -o))
            path.move(to: NSPoint(x: tile - o, y: tile + o)); path.line(to: NSPoint(x: tile + o, y: tile - o))
            path.lineWidth = 9
            NSColor(white: 1, alpha: 0.03).setStroke()
            path.stroke()
            return true
        }
        return NSColor(patternImage: image)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let safe = NSRect(x: bounds.minX + keepClearInsets.left, y: bounds.minY + keepClearInsets.bottom,
                          width: bounds.width - keepClearInsets.left - keepClearInsets.right,
                          height: bounds.height - keepClearInsets.top - keepClearInsets.bottom)
        boardRect = aspectFit(CGSize(width: canvas.width, height: canvas.height),
                              in: safe.insetBy(dx: padding + borderWidth, dy: padding + borderWidth))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = boardRect.insetBy(dx: -borderWidth, dy: -borderWidth)
        contentLayer.frame = CGRect(x: borderWidth, y: borderWidth, width: boardRect.width, height: boardRect.height)
        CATransaction.commit()
        onLayout?()
    }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = image
        CATransaction.commit()
    }

    // MARK: Input

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (p.x - boardRect.minX) * CGFloat(canvas.width) / boardRect.width,
                       y: (p.y - boardRect.minY) * CGFloat(canvas.height) / boardRect.height)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard boardRect.contains(p) else { drawing = false; return }
        drawing = true
        canvas.beginStroke(at: canvasPoint(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawing else { return }
        canvas.continueStroke(to: canvasPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard drawing else { return }
        drawing = false
        canvas.endStroke(at: canvasPoint(event))
    }
}

/// Clean program feed for the HDMI display: canvas only, letterboxed in black.
final class OutputView: NSView {
    private let contentLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        contentLayer.contentsGravity = .resizeAspect
        contentLayer.magnificationFilter = .linear
        contentLayer.minificationFilter = .trilinear
        layer?.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        CATransaction.commit()
    }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = image
        CATransaction.commit()
    }
}

/// Subtle, touch-sized clear button placed in a screen corner.
final class ClearButton: NSView {
    static let size: CGFloat = 76

    var action: (() -> Void)?
    private let requiresDoubleTap: Bool
    private var pressed = false { didSet { needsDisplay = true } }
    private var armed = false { didSet { needsDisplay = true } }
    private var disarmWork: DispatchWorkItem?
    /// Where the current press started; nil once the finger has moved too far to count as a tap.
    private var pressOrigin: NSPoint?
    private static let tapSlop: CGFloat = 10
    private let icon: NSImage?

    init(requiresDoubleTap: Bool) {
        self.requiresDoubleTap = requiresDoubleTap
        let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        icon = (NSImage(systemSymbolName: "eraser", accessibilityDescription: "Clear")
            ?? NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear"))?
            .withSymbolConfiguration(config)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let level: CGFloat = pressed ? 1 : (armed ? 0.95 : 0.85)
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSColor(white: 1, alpha: 0.2 * level + (armed ? 0.12 : 0)).setFill()
        circle.fill()
        (armed ? NSColor.systemRed.withAlphaComponent(0.9) : NSColor(white: 1, alpha: 0.8 * level)).setStroke()
        circle.lineWidth = armed ? 3 : 2
        circle.stroke()
        if let icon {
            let s = icon.size
            let r = NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height)
            icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: min(1, 0.8 * level + 0.2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        pressOrigin = convert(event.locationInWindow, from: nil)
    }

    // A swipe across the button is not a tap: cancel once the finger moves.
    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - origin.x, p.y - origin.y) > Self.tapSlop {
            pressOrigin = nil
            pressed = false
        }
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        defer { pressOrigin = nil }
        guard pressOrigin != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if !requiresDoubleTap || armed {
            disarm()
            action?()
        } else {
            armed = true
            let work = DispatchWorkItem { [weak self] in self?.disarm() }
            disarmWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
    }

    private func disarm() {
        disarmWork?.cancel()
        disarmWork = nil
        armed = false
    }
}

/// A small, faint logo that lives in a corner of the touchscreen. It ignores touches and never reaches the outputs.
final class CornerLogoView: NSImageView {
    static let maxSize: CGFloat = 56

    convenience init(image: NSImage) {
        self.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        alphaValue = 0.2
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Size that fits the image's aspect ratio inside a square of `side` points.
    func fittedSize(side: CGFloat) -> NSSize {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let scale = side / max(size.width, size.height)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }
}
