import Accelerate
import CNDI
import Foundation
import QuartzCore

enum NDI {
    /// Must be called once before any sender is created.
    static let isAvailable: Bool = NDIlib_initialize()

    /// Touches the network briefly at launch so macOS shows its Local Network
    /// prompt over the setup window, not hidden behind the live board.
    static func requestNetworkAccess() {
        guard isAvailable, let finder = NDIlib_find_create_v2(nil) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            NDIlib_find_destroy(finder)
        }
    }
}

/// Streams the canvas as an NDI video source on a dedicated thread.
/// The SDK clocks the send call, so in Full mode the loop runs at exactly the chosen frame rate.
/// Saving modes send only when the board changes (capped while writing, one frame a second
/// while idle) and can send a scaled-down picture to cut network traffic.
final class NDISender {
    private let canvas: Canvas
    private let instance: NDIlib_send_instance_t
    private let frameRate: FrameRate
    let bandwidth: NDIBandwidth
    private let stateLock = NSLock()
    private var running = false
    private var _framesSent: UInt64 = 0
    private let finished = DispatchSemaphore(value: 0)

    init?(name: String, canvas: Canvas, frameRate: FrameRate, bandwidth: NDIBandwidth = .full) {
        guard NDI.isAvailable else { return nil }
        let inst: NDIlib_send_instance_t? = name.withCString { cName in
            var desc = NDIlib_send_create_t()
            desc.p_ndi_name = cName
            desc.p_groups = nil
            desc.clock_video = true
            desc.clock_audio = false
            return NDIlib_send_create(&desc)
        }
        guard let inst else { return nil }
        self.instance = inst
        self.canvas = canvas
        self.frameRate = frameRate
        self.bandwidth = bandwidth
    }

    /// Size of the picture sent over NDI.
    var outputSize: (width: Int, height: Int) {
        let s = bandwidth.scale
        return (max(16, Int((Double(canvas.width) * s).rounded())), max(16, Int((Double(canvas.height) * s).rounded())))
    }

    var connectionCount: Int {
        Int(NDIlib_send_get_no_connections(instance, 0))
    }

    /// Full network name as receivers see it, e.g. "MACHINE (WBWriter)".
    var sourceName: String {
        guard let source = NDIlib_send_get_source_name(instance), let name = source.pointee.p_ndi_name else { return "" }
        return String(cString: name)
    }

    var framesSent: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return _framesSent
    }

    func start() {
        stateLock.lock()
        running = true
        stateLock.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "WBWriter.NDI"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()
        if wasRunning { finished.wait() }
        NDIlib_send_destroy(instance)
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func run() {
        defer { finished.signal() }
        let w = canvas.width, h = canvas.height, stride = canvas.bytesPerRow
        let (ow, oh) = outputSize
        let outStride = ow * 4
        let scaled = ow != w || oh != h

        // canvas copy -> optional scale -> optional unpremultiply -> the buffer handed to NDI
        let raw = UnsafeMutableRawPointer.allocate(byteCount: stride * h, alignment: 64)
        let small = scaled ? UnsafeMutableRawPointer.allocate(byteCount: outStride * oh, alignment: 64) : nil
        let straight = canvas.transparent ? UnsafeMutableRawPointer.allocate(byteCount: outStride * oh, alignment: 64) : nil
        defer {
            raw.deallocate()
            small?.deallocate()
            straight?.deallocate()
        }
        let output = straight ?? small ?? raw

        func prepare() {
            var src = vImage_Buffer(data: raw, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)
            if let small {
                var dst = vImage_Buffer(data: small, height: vImagePixelCount(oh), width: vImagePixelCount(ow), rowBytes: outStride)
                vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
                src = dst
            }
            if let straight {
                // CoreGraphics is premultiplied; NDI BGRA expects straight alpha (alpha-last, so RGBA routine fits).
                var dst = vImage_Buffer(data: straight, height: vImagePixelCount(oh), width: vImagePixelCount(ow), rowBytes: outStride)
                vImageUnpremultiplyData_RGBA8888(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
        }

        var frame = NDIlib_video_frame_v2_t()
        frame.xres = Int32(ow)
        frame.yres = Int32(oh)
        frame.FourCC = canvas.transparent ? NDIlib_FourCC_video_type_BGRA : NDIlib_FourCC_video_type_BGRX
        frame.frame_rate_N = frameRate.numerator
        frame.frame_rate_D = frameRate.denominator
        frame.picture_aspect_ratio = Float(w) / Float(h)
        frame.frame_format_type = NDIlib_frame_format_type_progressive
        frame.timecode = Int64.max // NDIlib_send_timecode_synthesize
        frame.p_data = output.assumingMemoryBound(to: UInt8.self)
        frame.line_stride_in_bytes = Int32(outStride)

        let frameInterval = Double(frameRate.denominator) / Double(frameRate.numerator)
        let minGap = bandwidth.maxFPS.map { max(1 / $0, frameInterval) } ?? frameInterval
        let idleGap = 1.0
        var version: UInt64 = 0
        var pending = true
        var lastSend = -Double.infinity
        var lastReceivers = 0

        while isRunning {
            if let v = canvas.copyPixels(to: raw, ifNewerThan: version) {
                version = v
                pending = true
            }
            if bandwidth.onlyChanges || bandwidth.maxFPS != nil {
                let now = CACurrentMediaTime()
                let receivers = connectionCount
                let newReceiver = receivers > lastReceivers
                lastReceivers = receivers
                let due: Bool
                if bandwidth.onlyChanges {
                    due = (pending && now - lastSend >= minGap) || now - lastSend >= idleGap || newReceiver
                } else {
                    due = now - lastSend >= minGap || newReceiver
                }
                guard due else {
                    Thread.sleep(forTimeInterval: min(frameInterval, 0.02))
                    continue
                }
                lastSend = now
            }
            if pending {
                prepare()
                pending = false
            }
            NDIlib_send_send_video_v2(instance, &frame)
            stateLock.lock()
            _framesSent &+= 1
            stateLock.unlock()
        }
    }
}
