import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings()
    private var setupWindow: NSWindow?
    private var production: ProductionController?
    private var canvas: Canvas?
    private var aboutWindow: NSWindow?
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NDI.requestNetworkAccess()
        buildMenu()
        showSetup()
        updater.canPresent = { [weak self] in self?.production == nil }
        let selfTest = CommandLine.arguments.contains("--selftest")
        if selfTest { runSelfTest() }
        if CommandLine.arguments.contains("--about") { showAbout() }
        if settings.checkForUpdates && !selfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.updater.check(userInitiated: false)
            }
        }
    }

    @objc func checkForUpdates() {
        updater.check(userInitiated: true)
    }

    /// Goes live and draws a test stroke; used to verify NDI/HDMI output without touch input.
    private func runSelfTest() {
        goLive()
        guard let canvas else { return }
        let w = CGFloat(canvas.width), h = CGFloat(canvas.height)
        canvas.beginStroke(at: CGPoint(x: w * 0.1, y: h * 0.5))
        for i in 1...200 {
            let t = CGFloat(i) / 200
            canvas.continueStroke(to: CGPoint(x: w * (0.1 + 0.8 * t), y: h * (0.5 + 0.3 * sin(t * .pi * 4))))
        }
        canvas.endStroke(at: CGPoint(x: w * 0.9, y: h * 0.5))

        // WBWRITER_SNAPSHOT=/path/board.png saves the live board screen once the status line has updated.
        if let path = ProcessInfo.processInfo.environment["WBWRITER_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.production?.saveBoardSnapshot(to: URL(fileURLWithPath: path))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        production == nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        production?.stop()
    }

    // MARK: Setup / live switching

    private func showSetup() {
        if setupWindow == nil {
            let host = NSHostingController(rootView: SetupView(settings: settings,
                                                               goLive: { [weak self] in self?.goLive() },
                                                               showAbout: { [weak self] in self?.showAbout() },
                                                               checkForUpdates: { [weak self] in self?.checkForUpdates() }))
            let window = NSWindow(contentViewController: host)
            window.title = "WBWriter"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 820))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("SetupWindow")
            setupWindow = window
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updater.presentIfPending()
    }

    private func goLive() {
        guard production == nil else { return }
        settings.errorMessage = nil
        let w = settings.outputWidth, h = settings.outputHeight
        guard (16...8192).contains(w), (16...8192).contains(h) else {
            settings.errorMessage = "Resolution must be between 16 and 8192 pixels per side."
            return
        }
        let transparent = settings.background == .transparent
        if canvas == nil || canvas!.width != w || canvas!.height != h || canvas!.transparent != transparent {
            canvas = Canvas(width: w, height: h, transparent: transparent)
        }
        guard let canvas else {
            settings.errorMessage = "Could not allocate a \(w)×\(h) canvas."
            return
        }
        let controller = ProductionController(canvas: canvas, settings: settings) { [weak self] in
            self?.production = nil
            self?.showSetup()
        }
        do {
            try controller.start()
        } catch {
            controller.stop()
            settings.errorMessage = error.localizedDescription
            return
        }
        production = controller
        setupWindow?.orderOut(nil)
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.title = "About WBWriter"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About WBWriter", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WBWriter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WBWriter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
