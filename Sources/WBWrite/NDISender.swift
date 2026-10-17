import Accelerate
import CNDI
import Foundation

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
/// The SDK clocks the send call, so the loop runs at exactly the chosen frame rate.
final class NDISender {
    private let canvas: Canvas
    private let instance: NDIlib_send_instance_t
    private let frameRate: FrameRate
    private let stateLock = NSLock()
    private var running = false
    private var _framesSent: UInt64 = 0
    private let finished = DispatchSemaphore(value: 0)

    init?(name: String, canvas: Canvas, frameRate: FrameRate) {
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
    }

    var connectionCount: Int {
        Int(NDIlib_send_get_no_connections(instance, 0))
    }

    /// Full network name as receivers see it, e.g. "MACHINE (WBWrite)".
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
        thread.name = "WBWrite.NDI"
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
        let size = stride * h
        let sendBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
        let staging = canvas.transparent ? UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64) : nil
        defer {
            sendBuffer.deallocate()
            staging?.deallocate()
        }

        var frame = NDIlib_video_frame_v2_t()
        frame.xres = Int32(w)
        frame.yres = Int32(h)
        frame.FourCC = canvas.transparent ? NDIlib_FourCC_video_type_BGRA : NDIlib_FourCC_video_type_BGRX
        frame.frame_rate_N = frameRate.numerator
        frame.frame_rate_D = frameRate.denominator
        frame.picture_aspect_ratio = Float(w) / Float(h)
        frame.frame_format_type = NDIlib_frame_format_type_progressive
        frame.timecode = Int64.max // NDIlib_send_timecode_synthesize
        frame.p_data = sendBuffer.assumingMemoryBound(to: UInt8.self)
        frame.line_stride_in_bytes = Int32(stride)

        var version: UInt64 = 0
        while isRunning {
            if let staging {
                if let v = canvas.copyPixels(to: staging, ifNewerThan: version) {
                    version = v
                    // CoreGraphics is premultiplied; NDI BGRA expects straight alpha (alpha-last, so RGBA routine fits).
                    var src = vImage_Buffer(data: staging, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)
                    var dst = vImage_Buffer(data: sendBuffer, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)
                    vImageUnpremultiplyData_RGBA8888(&src, &dst, vImage_Flags(kvImageNoFlags))
                }
            } else if let v = canvas.copyPixels(to: sendBuffer, ifNewerThan: version) {
                version = v
            }
            NDIlib_send_send_video_v2(instance, &frame)
            stateLock.lock()
            _framesSent &+= 1
            stateLock.unlock()
        }
    }
}
