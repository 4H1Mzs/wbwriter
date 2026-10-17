import AppKit
import SwiftUI

struct FrameRate: Hashable, Identifiable {
    let numerator: Int32
    let denominator: Int32
    let label: String
    var id: String { label }

    static let all: [FrameRate] = [
        FrameRate(numerator: 24000, denominator: 1001, label: "23.976"),
        FrameRate(numerator: 24, denominator: 1, label: "24"),
        FrameRate(numerator: 25, denominator: 1, label: "25"),
        FrameRate(numerator: 30000, denominator: 1001, label: "29.97"),
        FrameRate(numerator: 30, denominator: 1, label: "30"),
        FrameRate(numerator: 50, denominator: 1, label: "50"),
        FrameRate(numerator: 60000, denominator: 1001, label: "59.94"),
        FrameRate(numerator: 60, denominator: 1, label: "60"),
    ]
}

struct Resolution: Hashable, Identifiable {
    let width: Int
    let height: Int
    let label: String
    var id: String { "\(width)x\(height)" }

    static let presets: [Resolution] = [
        Resolution(width: 1920, height: 1080, label: "1920 × 1080 (Full HD)"),
        Resolution(width: 3840, height: 2160, label: "3840 × 2160 (4K UHD)"),
        Resolution(width: 2560, height: 1440, label: "2560 × 1440 (QHD)"),
        Resolution(width: 1280, height: 720, label: "1280 × 720 (HD)"),
        Resolution(width: 1080, height: 1920, label: "1080 × 1920 (Portrait)"),
    ]
}

enum BackgroundMode: String, CaseIterable, Identifiable {
    case black, transparent
    var id: String { rawValue }
    var label: String { self == .black ? "Black" : "Transparent (alpha)" }
}

enum ClearCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum ClearGesture: String, CaseIterable, Identifiable {
    case singleTap, doubleTap, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .singleTap: return "Single tap"
        case .doubleTap: return "Double tap (safer)"
        case .none: return "None (no button)"
        }
    }
}

/// OpenBoard's largest default pen ("strong") is 8 px on a 1080p board.
let defaultPenWidth: Double = 8

/// Persistent app configuration, edited in the setup window before going live.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var outputWidth: Int { didSet { defaults.set(outputWidth, forKey: "outputWidth") } }
    @Published var outputHeight: Int { didSet { defaults.set(outputHeight, forKey: "outputHeight") } }
    @Published var frameRateLabel: String { didSet { defaults.set(frameRateLabel, forKey: "frameRate") } }
    @Published var ndiEnabled: Bool { didSet { defaults.set(ndiEnabled, forKey: "ndiEnabled") } }
    @Published var ndiName: String { didSet { defaults.set(ndiName, forKey: "ndiName") } }
    @Published var background: BackgroundMode { didSet { defaults.set(background.rawValue, forKey: "background") } }
    @Published var penColor: Color { didSet { savePenColor() } }
    /// Pen width in pixels on a 1080-line output; scaled with output height.
    @Published var penWidth: Double { didSet { defaults.set(penWidth, forKey: "penWidth") } }
    @Published var boardDisplayID: Int { didSet { defaults.set(boardDisplayID, forKey: "boardDisplay") } }
    @Published var outputDisplayID: Int { didSet { defaults.set(outputDisplayID, forKey: "outputDisplay") } }
    @Published var boardPadding: Double { didSet { defaults.set(boardPadding, forKey: "boardPadding") } }
    @Published var clearCorner: ClearCorner { didSet { defaults.set(clearCorner.rawValue, forKey: "clearCorner") } }
    @Published var clearGesture: ClearGesture { didSet { defaults.set(clearGesture.rawValue, forKey: "clearGesture") } }
    @Published var hideCursor: Bool { didSet { defaults.set(hideCursor, forKey: "hideCursor") } }
    @Published var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    /// Last go-live failure, shown in the setup window (not persisted).
    @Published var errorMessage: String?

    init() {
        Self.importSettingsFromWBWrite()
        let d = UserDefaults.standard
        d.register(defaults: [
            "outputWidth": 1920,
            "outputHeight": 1080,
            "frameRate": "30",
            "ndiEnabled": true,
            "ndiName": "WBWriter",
            "background": BackgroundMode.black.rawValue,
            "penWidth": defaultPenWidth,
            "boardDisplay": 0,
            "outputDisplay": 0,
            "boardPadding": 24.0,
            "clearCorner": ClearCorner.topRight.rawValue,
            "clearGesture": ClearGesture.singleTap.rawValue,
            "hideCursor": false,
            "checkForUpdates": true,
        ])
        outputWidth = d.integer(forKey: "outputWidth")
        outputHeight = d.integer(forKey: "outputHeight")
        frameRateLabel = d.string(forKey: "frameRate") ?? "30"
        ndiEnabled = d.bool(forKey: "ndiEnabled")
        ndiName = d.string(forKey: "ndiName") ?? "WBWriter"
        background = BackgroundMode(rawValue: d.string(forKey: "background") ?? "") ?? .black
        penWidth = d.double(forKey: "penWidth")
        boardDisplayID = d.integer(forKey: "boardDisplay")
        outputDisplayID = d.integer(forKey: "outputDisplay")
        boardPadding = d.double(forKey: "boardPadding")
        clearCorner = ClearCorner(rawValue: d.string(forKey: "clearCorner") ?? "") ?? .topRight
        clearGesture = ClearGesture(rawValue: d.string(forKey: "clearGesture") ?? "") ?? .singleTap
        hideCursor = d.bool(forKey: "hideCursor")
        checkForUpdates = d.bool(forKey: "checkForUpdates")
        if let c = d.array(forKey: "penColor") as? [Double], c.count == 3 {
            penColor = Color(.sRGB, red: c[0], green: c[1], blue: c[2])
        } else {
            penColor = .white
        }
    }

    /// One-time import of settings saved by the app under its former name (WBWrite).
    private static func importSettingsFromWBWrite() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "importedLegacySettings") else { return }
        d.set(true, forKey: "importedLegacySettings")
        guard let legacy = UserDefaults(suiteName: "com.cechacek.wbwrite") else { return }
        let keys = ["outputWidth", "outputHeight", "frameRate", "ndiEnabled", "ndiName", "background",
                    "penColor", "penWidth", "boardDisplay", "outputDisplay", "boardPadding",
                    "clearCorner", "clearGesture", "hideCursor"]
        for key in keys where d.object(forKey: key) == nil {
            guard var value = legacy.object(forKey: key) else { continue }
            if key == "ndiName", value as? String == "WBWrite" { value = "WBWriter" }
            d.set(value, forKey: key)
        }
    }

    var frameRate: FrameRate {
        FrameRate.all.first { $0.label == frameRateLabel } ?? FrameRate.all[4]
    }

    var penCGColor: CGColor {
        let c = NSColor(penColor).usingColorSpace(.sRGB) ?? .white
        return CGColor(srgbRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)
    }

    /// Pen width in output pixels.
    var effectivePenWidth: CGFloat {
        CGFloat(penWidth) * CGFloat(outputHeight) / 1080
    }

    private func savePenColor() {
        let c = NSColor(penColor).usingColorSpace(.sRGB) ?? .white
        defaults.set([Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)], forKey: "penColor")
    }
}

extension NSScreen {
    var displayID: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    static func with(displayID: Int) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    var label: String {
        let px = convertRectToBacking(frame).size
        return "\(localizedName) — \(Int(px.width))×\(Int(px.height))"
    }
}
