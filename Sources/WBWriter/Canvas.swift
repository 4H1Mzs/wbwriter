import CoreGraphics
import Foundation

/// The drawing surface at full output resolution. Strokes are rendered straight
/// into a BGRA bitmap that is shared by the on-screen board, the HDMI output
/// and the NDI sender. All access goes through `lock`.
final class Canvas {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let transparent: Bool

    var penColor: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    var penWidth: CGFloat = defaultPenWidth

    private let ctx: CGContext
    private let lock = NSLock()
    private var _version: UInt64 = 1

    private var lastPoint: CGPoint?
    private var lastMid: CGPoint?

    init?(width: Int, height: Int, transparent: Bool) {
        let bytesPerRow = width * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                  // Memory layout B,G,R,A (premultiplied) — matches NDI BGRA/BGRX.
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.transparent = transparent
        self.ctx = ctx
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        fillBackground()
    }

    var version: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _version
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        fillBackground()
        lastPoint = nil
        lastMid = nil
        _version &+= 1
    }

    // MARK: Strokes (canvas pixel coordinates, origin bottom-left)

    func beginStroke(at p: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        lastPoint = p
        lastMid = p
        let r = penWidth / 2
        ctx.setFillColor(penColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: penWidth, height: penWidth))
        _version &+= 1
    }

    func continueStroke(to p: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        guard let prev = lastPoint, let mid0 = lastMid else { return }
        if hypot(p.x - prev.x, p.y - prev.y) < 0.75 { return }
        // Quadratic smoothing through segment midpoints.
        let mid = CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2)
        ctx.beginPath()
        ctx.move(to: mid0)
        ctx.addQuadCurve(to: mid, control: prev)
        strokePath()
        lastPoint = p
        lastMid = mid
        _version &+= 1
    }

    func endStroke(at p: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        if let mid0 = lastMid {
            ctx.beginPath()
            ctx.move(to: mid0)
            ctx.addLine(to: p)
            strokePath()
            _version &+= 1
        }
        lastPoint = nil
        lastMid = nil
    }

    /// Replaces the board with an image of the same size, e.g. when resuming after a restart.
    func restore(from image: CGImage) {
        lock.lock(); defer { lock.unlock() }
        fillBackground()
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        lastPoint = nil
        lastMid = nil
        _version &+= 1
    }

    // MARK: Readout

    func makeImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return ctx.makeImage()
    }

    /// Copies the raw BGRA pixels into `dst` if the canvas changed since `version`.
    /// Returns the new version, or nil when nothing changed.
    func copyPixels(to dst: UnsafeMutableRawPointer, ifNewerThan version: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard _version != version, let src = ctx.data else { return nil }
        memcpy(dst, src, bytesPerRow * height)
        return _version
    }

    // MARK: Private

    private func strokePath() {
        ctx.setStrokeColor(penColor)
        ctx.setLineWidth(penWidth)
        ctx.strokePath()
    }

    private func fillBackground() {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if transparent {
            ctx.clear(rect)
        } else {
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(rect)
        }
    }
}
