import AppKit

struct ProductionError: LocalizedError {
    let errorDescription: String?
}

/// Owns everything that exists while the show is live: board window,
/// optional HDMI output window, NDI sender and the refresh timer.
final class ProductionController {
    private let canvas: Canvas
    private let settings: AppSettings
    private let onExit: () -> Void

    private var boardWindow: ProductionWindow?
    private var boardView: BoardView?
    private var outputWindow: ProductionWindow?
    private var outputView: OutputView?
    private var sender: NDISender?
    private var timer: Timer?
    private var shownVersion: UInt64 = 0
    private var activity: NSObjectProtocol?
    private var cursorHidden = false
    private var statusLabel: StatusLabel?
    private var statusMonitor: StatusMonitor?
    private var statusTimer: Timer?
    private var clearButton: ClearButton?

    init(canvas: Canvas, settings: AppSettings, onExit: @escaping () -> Void) {
        self.canvas = canvas
        self.settings = settings
        self.onExit = onExit
    }

    func start() throws {
        let boardScreen = NSScreen.with(displayID: settings.boardDisplayID) ?? NSScreen.main ?? NSScreen.screens[0]
        let outputScreen = settings.outputDisplayID == 0 ? nil : NSScreen.with(displayID: settings.outputDisplayID)
        if settings.outputDisplayID != 0 && outputScreen == nil {
            throw ProductionError(errorDescription: "The selected HDMI output display is not connected.")
        }
        if let outputScreen, outputScreen == boardScreen {
            throw ProductionError(errorDescription: "The HDMI output display must be different from the board display.")
        }

        if settings.ndiEnabled {
            guard NDI.isAvailable else {
                throw ProductionError(errorDescription: "NDI runtime could not be initialised on this Mac.")
            }
            let name = settings.ndiName.trimmingCharacters(in: .whitespaces)
            guard let s = NDISender(name: name.isEmpty ? "WBWriter" : name, canvas: canvas, frameRate: settings.frameRate) else {
                throw ProductionError(errorDescription: "Could not create the NDI output.")
            }
            sender = s
            s.start()
        }

        canvas.penColor = settings.penCGColor
        canvas.penWidth = settings.effectivePenWidth

        // Board on the touchscreen.
        let window = ProductionWindow(screen: boardScreen)
        window.level = .statusBar
        let container = NSView(frame: NSRect(origin: .zero, size: boardScreen.frame.size))
        let board = BoardView(canvas: canvas, padding: CGFloat(settings.boardPadding))
        board.frame = container.bounds
        board.autoresizingMask = [.width, .height]
        if #available(macOS 12.0, *) { board.keepClearInsets = boardScreen.safeAreaInsets }
        container.addSubview(board)

        let button = ClearButton(requiresDoubleTap: settings.clearGesture == .doubleTap)
        button.action = { [weak self] in self?.clear() }
        let m: CGFloat = 18, s = ClearButton.size, b = container.bounds
        switch settings.clearCorner {
        case .topLeft:
            button.frame.origin = CGPoint(x: m, y: b.height - s - m)
            button.autoresizingMask = [.maxXMargin, .minYMargin]
        case .topRight:
            button.frame.origin = CGPoint(x: b.width - s - m, y: b.height - s - m)
            button.autoresizingMask = [.minXMargin, .minYMargin]
        case .bottomLeft:
            button.frame.origin = CGPoint(x: m, y: m)
            button.autoresizingMask = [.maxXMargin, .maxYMargin]
        case .bottomRight:
            button.frame.origin = CGPoint(x: b.width - s - m, y: m)
            button.autoresizingMask = [.minXMargin, .maxYMargin]
        }
        if settings.clearGesture != .none {
            container.addSubview(button)
            clearButton = button
        }

        let label = StatusLabel()
        container.addSubview(label)
        statusLabel = label
        statusMonitor = StatusMonitor(width: canvas.width, height: canvas.height, frameRate: settings.frameRate,
                                      sender: sender, ndiEnabled: settings.ndiEnabled)
        board.onLayout = { [weak self] in self?.placeStatus() }

        window.contentView = container
        window.onEscape = { [weak self] in self?.exit() }
        window.onDeleteKey = { [weak self] in self?.clear() }
        boardWindow = window
        boardView = board

        // Clean feed on the external display.
        if let outputScreen {
            let out = ProductionWindow(screen: outputScreen)
            out.level = .screenSaver
            out.ignoresMouseEvents = true
            let view = OutputView(frame: NSRect(origin: .zero, size: outputScreen.frame.size))
            out.contentView = view
            out.orderFrontRegardless()
            outputWindow = out
            outputView = view
        }

        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(board)
        NSApp.activate(ignoringOtherApps: true)

        if settings.hideCursor {
            NSCursor.hide()
            cursorHidden = true
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated, .latencyCritical],
            reason: "WBWriter is live")

        shownVersion = 0
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()

        updateStatus()
        let st = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatus() }
        RunLoop.main.add(st, forMode: .common)
        statusTimer = st
    }

    private func updateStatus() {
        guard let statusLabel, let statusMonitor else { return }
        statusLabel.attributedStringValue = statusMonitor.sample()
        placeStatus()
    }

    /// Puts the status line in a bottom corner, but only where it fits outside the board and button.
    private func placeStatus() {
        guard let label = statusLabel, let board = boardView, let container = label.superview else { return }
        label.sizeToFit()
        let size = label.frame.size
        let m: CGFloat = 12
        let bottom: CGFloat = 6
        let candidates = [
            CGRect(x: m, y: bottom, width: size.width, height: size.height),
            CGRect(x: container.bounds.width - size.width - m, y: bottom, width: size.width, height: size.height),
        ]
        let blocked = [board.framedBoardRect, clearButton?.frame].compactMap { $0 }
        if let spot = candidates.first(where: { c in blocked.allSatisfy { !$0.intersects(c.insetBy(dx: -4, dy: -4)) } }) {
            label.frame = spot
            label.isHidden = false
        } else {
            label.isHidden = true
        }
    }

    func clear() {
        canvas.clear()
        refresh()
    }

    func exit() {
        stop()
        onExit()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        statusTimer?.invalidate()
        statusTimer = nil
        statusMonitor = nil
        statusLabel = nil
        clearButton = nil
        sender?.stop()
        sender = nil
        boardWindow?.orderOut(nil)
        outputWindow?.orderOut(nil)
        boardWindow = nil
        outputWindow = nil
        boardView = nil
        outputView = nil
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        NSApp.presentationOptions = []
    }

    private func refresh() {
        let v = canvas.version
        guard v != shownVersion else { return }
        shownVersion = v
        let image = canvas.makeImage()
        boardView?.show(image)
        outputView?.show(image)
    }
}
