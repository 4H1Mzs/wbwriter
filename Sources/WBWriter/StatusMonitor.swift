import AppKit
import IOKit.ps

/// Samples machine state for the on-board status line.
enum SystemStatus {
    /// Battery percentage when running on battery power, nil on AC.
    static func batteryPercentIfOnBattery() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?,
              type == kIOPSBatteryPowerValue,
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return current * 100 / max
        }
        return nil
    }

    /// Total bytes sent on Ethernet/Wi-Fi interfaces (en*). 32-bit counters, wraps.
    static func networkBytesOut() -> UInt32 {
        var total: UInt32 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return 0 }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            let entry = ifa.pointee
            if entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               String(cString: entry.ifa_name).hasPrefix("en"),
               let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) {
                total &+= data.pointee.ifi_obytes
            }
            cursor = entry.ifa_next
        }
        return total
    }
}

/// Small, non-interactive status text shown around the board (never sent to outputs).
class StatusLabel: NSTextField {
    convenience init() {
        self.init(wrappingLabelWithString: "")
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        textColor = NSColor(white: 1, alpha: 0.4)
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        isSelectable = false
    }

    /// Size of the text when wrapped to at most `maxWidth` points.
    func wrappedSize(maxWidth: CGFloat) -> NSSize {
        preferredMaxLayoutWidth = maxWidth
        let size = cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth, height: .greatestFiniteMagnitude)) ?? .zero
        return NSSize(width: ceil(min(size.width, maxWidth)), height: ceil(size.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A remote message for the performer, shown in the hatched area. Never sent to the outputs.
final class MessageLabel: StatusLabel {
    convenience init(text: String) {
        self.init()
        font = .systemFont(ofSize: 28, weight: .semibold)
        textColor = NSColor(srgbRed: 1, green: 0.83, blue: 0.35, alpha: 1)
        stringValue = text
    }
}

/// Builds the status line once per second.
final class StatusMonitor {
    private let resolution: String
    private let targetFPS: Double
    private weak var sender: NDISender?
    private let ndiEnabled: Bool
    private var lastFrames: UInt64 = 0
    private var lastBytes = SystemStatus.networkBytesOut()
    private var lastTime = CACurrentMediaTime()

    init(width: Int, height: Int, frameRate: FrameRate, sender: NDISender?, ndiEnabled: Bool) {
        resolution = "\(width)×\(height)"
        targetFPS = Double(frameRate.numerator) / Double(frameRate.denominator)
        self.sender = sender
        self.ndiEnabled = ndiEnabled
        lastFrames = sender?.framesSent ?? 0
    }

    func sample() -> NSAttributedString {
        let now = CACurrentMediaTime()
        let dt = max(now - lastTime, 0.001)
        lastTime = now
        let bytes = SystemStatus.networkBytesOut()
        let mbps = Double(bytes &- lastBytes) * 8 / dt / 1_000_000
        lastBytes = bytes

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let dim = NSColor(white: 1, alpha: 0.4)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ color: NSColor = dim) {
            out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }
        /// An item that never breaks across lines.
        func item(_ s: String, _ color: NSColor = dim) {
            add(s.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "-", with: "-\u{2060}"), color)
        }
        let sep = "  ·  "

        if ndiEnabled, let sender {
            let frames = sender.framesSent
            let fps = Double(frames &- lastFrames) / dt
            lastFrames = frames
            let receivers = sender.connectionCount
            let healthy = fps >= targetFPS * 0.9
            let (dot, state): (NSColor, String) =
                !healthy ? (.systemRed, "NDI DROPPING")
                : receivers > 0 ? (.systemGreen, "NDI OK")
                : (.systemYellow, "NDI waiting")
            item("● ", dot.withAlphaComponent(0.9))
            item(state)
            add(sep); item(sender.sourceName)
            add(sep); item("\(resolution) @ " + String(format: "%.2f fps", fps))
            add(sep); item("\(receivers) rx")
            add(sep); item(String(format: "TX %.1f Mb/s", mbps))
        } else {
            item("● ", NSColor(white: 1, alpha: 0.3))
            item("NDI off")
            add(sep); item(resolution)
        }
        if let battery = SystemStatus.batteryPercentIfOnBattery() {
            add(sep)
            item("Battery \(battery)%", battery <= 20 ? .systemRed.withAlphaComponent(0.9) : dim)
        }
        return out
    }
}
