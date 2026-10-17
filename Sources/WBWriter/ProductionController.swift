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
    private var cornerLogo: CornerLogoView?
    private var messageLabel: MessageLabel?
    private var messageTimer: Timer?
    /// The remote message currently on the touchscreen, if any.
    private(set) var message: String?

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

        if let image = settings.cornerLogoImage {
            let logo = CornerLogoView(image: image)
            container.addSubview(logo)
            cornerLogo = logo
        }

        let label = StatusLabel()
        container.addSubview(label)
        statusLabel = label
        statusMonitor = StatusMonitor(width: canvas.width, height: canvas.height, frameRate: settings.frameRate,
                                      sender: sender, ndiEnabled: settings.ndiEnabled)
        board.onLayout = { [weak self] in self?.layoutOverlays() }

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

    /// The latest status line as plain text, for the web control page.
    var statusText: String? {
        statusLabel?.stringValue.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func layoutOverlays() {
        placeCornerLogo()
        if let messageLabel { place(messageLabel, avoiding: []) }
        placeStatus()
    }

    // MARK: Remote message

    /// Shows a message for the performer in the hatched area until it's removed,
    /// or for `seconds` when given.
    func showMessage(_ text: String, seconds: Double?) {
        clearMessage()
        guard let container = boardView?.superview else { return }
        let label = MessageLabel(text: text)
        container.addSubview(label)
        messageLabel = label
        message = text
        layoutOverlays()
        if let seconds {
            let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.clearMessage() }
            RunLoop.main.add(t, forMode: .common)
            messageTimer = t
        }
    }

    func clearMessage() {
        messageTimer?.invalidate()
        messageTimer = nil
        messageLabel?.removeFromSuperview()
        messageLabel = nil
        message = nil
        placeStatus()
    }

    /// Bottom-right corner of the screen. When the clear button sits there, the logo goes just above
    /// it, or beside it if the board leaves no room above. Shrinks to stay off the board and the
    /// button, and hides when even a small logo wouldn't fit.
    private func placeCornerLogo() {
        guard let logo = cornerLogo, let board = boardView, let container = logo.superview else { return }
        let b = container.bounds, r = board.framedBoardRect
        let m: CGFloat = 18, gap: CGFloat = 12
        let button = settings.clearCorner == .bottomRight ? clearButton?.frame : nil
        let blocked = [r, button].compactMap { $0 }

        for side in stride(from: CornerLogoView.maxSize, through: 24, by: -4) {
            let size = logo.fittedSize(side: side)
            var spots = [CGRect(x: b.maxX - m - size.width, y: b.minY + m, width: size.width, height: size.height)]
            if let button {
                spots = [
                    CGRect(x: button.maxX - size.width, y: button.maxY + gap, width: size.width, height: size.height),
                    CGRect(x: button.minX - gap - size.width, y: b.minY + m, width: size.width, height: size.height),
                ]
            }
            if let spot = spots.first(where: { spot in
                b.contains(spot) && blocked.allSatisfy { !$0.intersects(spot.insetBy(dx: -4, dy: -4)) }
            }) {
                logo.frame = spot.integral
                logo.isHidden = false
                return
            }
        }
        logo.isHidden = true
    }

    private func placeStatus() {
        guard let label = statusLabel else { return }
        let message = messageLabel.flatMap { $0.isHidden ? nil : $0.frame }
        place(label, avoiding: [message].compactMap { $0 })
    }

    /// Keeps a label visible outside the board: below it on one line if it fits, otherwise
    /// wrapped onto more lines in the free margin beside the board. As a last resort it sits at
    /// the bottom of the screen even if it touches the board edge.
    private func place(_ label: StatusLabel, avoiding extra: [CGRect]) {
        guard let board = boardView, let container = label.superview else { return }
        let b = container.bounds
        let r = board.framedBoardRect
        let logoFrame = cornerLogo.flatMap { $0.isHidden ? nil : $0.frame }
        let blocked = [r, clearButton?.frame, logoFrame].compactMap { $0 } + extra
        let mx: CGFloat = 12, my: CGFloat = 6

        func fits(_ spot: CGRect) -> Bool {
            b.contains(spot) && blocked.allSatisfy { !$0.intersects(spot.insetBy(dx: -4, dy: -4)) }
        }
        func show(_ spot: CGRect) {
            label.frame = spot.integral
            label.isHidden = false
        }

        // Free areas around the board, bottom-anchored: below it, then the left and right margins.
        let regions = [
            CGRect(x: b.minX, y: b.minY, width: b.width, height: r.minY - b.minY),
            CGRect(x: b.minX, y: b.minY, width: r.minX - b.minX, height: b.height),
            CGRect(x: r.maxX, y: b.minY, width: b.maxX - r.maxX, height: b.height),
        ]
        for region in regions {
            let area = region.insetBy(dx: mx, dy: my)
            guard area.width >= 140, area.height >= 14 else { continue }
            let size = label.wrappedSize(maxWidth: area.width)
            guard size.height <= area.height else { continue }
            // Try the bottom of the area first, then move up past anything already placed there.
            var y = area.minY
            while y + size.height <= area.maxY {
                let left = CGRect(x: area.minX, y: y, width: size.width, height: size.height)
                let right = CGRect(x: area.maxX - size.width, y: y, width: size.width, height: size.height)
                if let spot = [left, right].first(where: fits) { return show(spot) }
                y += 8
            }
        }

        let size = label.wrappedSize(maxWidth: b.width - 2 * mx)
        show(CGRect(x: b.minX + mx, y: b.minY + my, width: size.width, height: size.height))
    }

    /// Renders the board screen (board, button, status line) to a PNG, for testing without a display.
    func saveBoardSnapshot(to url: URL) {
        guard let view = boardWindow?.contentView, let layer = view.layer else { return }
        let scale = boardWindow?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
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
        cornerLogo = nil
        messageTimer?.invalidate()
        messageTimer = nil
        messageLabel = nil
        message = nil
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
