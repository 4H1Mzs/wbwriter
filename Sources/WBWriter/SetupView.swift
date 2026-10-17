import AppKit
import SwiftUI

/// Keeps the display list current when monitors are plugged in or removed.
final class ScreenList: ObservableObject {
    @Published var screens: [NSScreen] = NSScreen.screens
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screens = NSScreen.screens }
    }
}

struct SetupView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var screens = ScreenList()
    @State private var customResolution = false
    var goLive: () -> Void
    var showAbout: () -> Void

    private var resolutionTag: Binding<String> {
        Binding(
            get: {
                let tag = "\(settings.outputWidth)x\(settings.outputHeight)"
                if customResolution || !Resolution.presets.contains(where: { $0.id == tag }) { return "custom" }
                return tag
            },
            set: { tag in
                if tag == "custom" {
                    customResolution = true
                } else if let r = Resolution.presets.first(where: { $0.id == tag }) {
                    customResolution = false
                    settings.outputWidth = r.width
                    settings.outputHeight = r.height
                }
            }
        )
    }

    private var aspectLabel: String {
        let w = settings.outputWidth, h = settings.outputHeight
        guard w > 0, h > 0 else { return "" }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(w, h)
        return "\(w / g):\(h / g)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("Output") {
                    Picker("Resolution", selection: resolutionTag) {
                        ForEach(Resolution.presets) { Text($0.label).tag($0.id) }
                        Text("Custom…").tag("custom")
                    }
                    if resolutionTag.wrappedValue == "custom" {
                        HStack {
                            TextField("Width", value: $settings.outputWidth, format: .number.grouping(.never))
                                .frame(width: 90)
                            Text("×")
                            TextField("Height", value: $settings.outputHeight, format: .number.grouping(.never))
                                .frame(width: 90)
                            Text("px").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Aspect") { Text(aspectLabel).foregroundStyle(.secondary) }
                    Picker("Frame rate", selection: $settings.frameRateLabel) {
                        ForEach(FrameRate.all) { Text("\($0.label) fps").tag($0.label) }
                    }
                    Picker("Background", selection: $settings.background) {
                        ForEach(BackgroundMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("Send NDI®", isOn: $settings.ndiEnabled)
                    TextField("NDI source name", text: $settings.ndiName)
                        .disabled(!settings.ndiEnabled)
                } header: {
                    Text("NDI")
                } footer: {
                    Text("Receivers will see “\(Host.current().localizedName ?? "MAC") (\(settings.ndiName))”. Only the inside of the board is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Pen") {
                    ColorPicker("Color", selection: $settings.penColor, supportsOpacity: false)
                    HStack {
                        Slider(value: $settings.penWidth, in: 2...40, step: 1) { Text("Width") }
                        Text("\(Int(settings.penWidth))").monospacedDigit().frame(width: 28, alignment: .trailing)
                        Button("Default") { settings.penWidth = defaultPenWidth }
                            .disabled(settings.penWidth == defaultPenWidth)
                    }
                    Text("Width is in pixels at 1080p and scales with the output resolution. Default 8 = OpenBoard’s thickest pen.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Board (touchscreen)") {
                    Picker("Display", selection: $settings.boardDisplayID) {
                        Text("Main display").tag(0)
                        ForEach(screens.screens, id: \.displayID) { Text($0.label).tag($0.displayID) }
                    }
                    HStack {
                        Slider(value: $settings.boardPadding, in: 0...120, step: 2) { Text("Margin") }
                        Text("\(Int(settings.boardPadding)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    Picker("Clear gesture", selection: $settings.clearGesture) {
                        ForEach(ClearGesture.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Clear button", selection: $settings.clearCorner) {
                        ForEach(ClearCorner.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(settings.clearGesture == .none)
                    Toggle("Hide mouse cursor while live", isOn: $settings.hideCursor)
                }

                Section {
                    Picker("Display", selection: $settings.outputDisplayID) {
                        Text("None").tag(0)
                        ForEach(screens.screens, id: \.displayID) { Text($0.label).tag($0.displayID) }
                    }
                } header: {
                    Text("HDMI output")
                } footer: {
                    Text("Full-screen clean feed of the board content on an external display. Leave on “None” for NDI only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 640, idealHeight: 820)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("WBWriter").font(.system(size: 22, weight: .bold))
                Text("Live whiteboard for stage → NDI / HDMI").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if !NDI.isAvailable {
                Label("NDI unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let errorMessage = settings.errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            Button(action: goLive) {
                Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.36, green: 0.13, blue: 0.6))
            .keyboardShortcut(.defaultAction)
            Text("Press Esc to leave live mode · Backspace also clears the board")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Made by 4H1M, z.s.")
                Text("·")
                Button("About & support", action: showAbout)
                    .buttonStyle(.link)
                Text("·")
                Text("NDI® is a registered trademark of Vizrt NDI AB.")
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
