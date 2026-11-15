import SwiftUI
import Testing
@testable import Dash

/// Renders Dashii with Metal and with the Core Graphics fallback. Set DASHII_RENDER_DIR to keep the PNGs.
@MainActor
struct DashiiRenderTests {
    /// Settles the smoothed gaze and turn, then returns the frame's draw list.
    func settled(_ direction: DashiiDirection) -> DashiiDrawList {
        let player = DashiiPlayer()
        var list = DashiiDrawList()
        for frame in 0...90 { list = player.frame(time: Double(frame) / 30, direction: direction, scale: 1) }
        return list
    }

    /// Fraction of pixels with some alpha, and the alpha at a point (in view points).
    func coverage(_ image: CGImage) -> (filled: Double, alphaAt: (CGPoint) -> UInt8) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let filled = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 8 }.count
        let scale = Double(width) / DashiiView.size(scale: 1).width
        let copy = bytes
        return (Double(filled) / Double(width * height), { point in
            let x = Int(point.x * scale), y = Int(point.y * scale)
            return copy[(y * width + x) * 4 + 3]
        })
    }

    func save(_ image: CGImage, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["DASHII_RENDER_DIR"] else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    @Test(arguments: [-60.0, -30.0, 0.0, 30.0, 60.0])
    func metalMatchesCoreGraphics(yaw: Double) throws {
        let gpu = try #require(DashiiGPU.shared)
        let size = DashiiView.size(scale: 1)
        let list = settled(DashiiDirection(clip: .idle, fidgets: false, yaw: yaw))
        let metal = try #require(gpu.image(list, size: size))
        let renderer = ImageRenderer(content: Canvas { context, _ in list.replay(in: &context) }.frame(width: size.width, height: size.height))
        renderer.scale = 2
        let canvas = try #require(renderer.cgImage)
        try save(metal, "dashii_metal_\(Int(yaw))")
        try save(canvas, "dashii_cg_\(Int(yaw))")
        let gpuCoverage = coverage(metal), cgCoverage = coverage(canvas)
        // Same silhouette: Dashii covers a similar share of the frame either way.
        #expect(gpuCoverage.filled > 0.1)
        #expect(abs(gpuCoverage.filled - cgCoverage.filled) < 0.03)
        // The head is opaque where the root's head sits (68 points above the root).
        let root = DashiiView.root(scale: 1)
        #expect(gpuCoverage.alphaAt(CGPoint(x: root.x, y: root.y - 68)) > 200)
        // Corners stay transparent.
        #expect(gpuCoverage.alphaAt(CGPoint(x: 2, y: 2)) == 0)
    }

    @Test func propsAndExpressionsDraw() throws {
        let gpu = try #require(DashiiGPU.shared)
        for clip in [DashiiClip.working, .asking, .delegating, .success, .error] {
            let list = settled(DashiiDirection(clip: clip, fidgets: false))
            #expect(list.primitives.contains { if case .roundRect = $0.shape { true } else { false } }, "\(clip) has its prop")
            let image = try #require(gpu.image(list, size: DashiiView.size(scale: 1)))
            try save(image, "dashii_metal_\(clip.rawValue)")
            #expect(coverage(image).filled > 0.1)
        }
    }
}
