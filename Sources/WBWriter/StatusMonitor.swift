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
final class StatusLabel: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        textColor = NSColor(white: 1, alpha: 0.55)
        lineBreakMode = .byClipping
        maximumNumberOfLines = 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
        let dim = NSColor(white: 1, alpha: 0.55)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ color: NSColor = dim) {
            out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
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
            add("● ", dot.withAlphaComponent(0.9))
            add(state)
            add(sep + sender.sourceName)
            add(sep + "\(resolution) @ " + String(format: "%.2f fps", fps))
            add(sep + "\(receivers) rx")
            add(sep + String(format: "TX %.1f Mb/s", mbps))
        } else {
            add("● ", NSColor(white: 1, alpha: 0.3))
            add("NDI off" + sep + resolution)
        }
        if let battery = SystemStatus.batteryPercentIfOnBattery() {
            add(sep)
            add("Battery \(battery)%", battery <= 20 ? .systemRed.withAlphaComponent(0.9) : dim)
        }
        return out
    }
}
