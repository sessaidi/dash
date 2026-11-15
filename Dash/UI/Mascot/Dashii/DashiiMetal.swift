import AppKit
import Metal
import MetalKit
import SwiftUI

/// One primitive for the GPU. Must match `DashiiInstance` in Dashii.metal (nine float4s).
struct DashiiInstance {
    var linear: SIMD4<Float>
    var translation: SIMD4<Float>
    var quad: SIMD4<Float>
    var shape: SIMD4<Float>
    var geometry: SIMD4<Float>
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
    var stroke: SIMD4<Float>
    var glow: SIMD4<Float>

    enum Kind: Float { case sprite = 0, roundRect = 1, segment = 2, text = 3 }
}

/// The GPU side shared by every Dashii view: device, pipeline, the atlas as a premultiplied,
/// mipmapped texture, and the prop labels rendered once into a glyph texture.
@MainActor
final class DashiiGPU {
    static let shared = DashiiGPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let atlas: MTLTexture?
    let atlasSize: CGSize
    let glyphs: MTLTexture?
    /// Normalized texture rect of each label.
    let glyphRects: [String: CGRect]
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    static let labels = ["</>", "?", "···", "✓", "!"]

    private init?(assets: DashiiAssets = .shared) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "dashii_vertex"), let fragment = library.makeFunction(name: "dashii_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = Self.pixelFormat
        // Everything is premultiplied: source over.
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        let atlasImage = assets.atlasImage
        atlas = atlasImage.flatMap { Self.texture($0, device: device, queue: queue) }
        atlasSize = atlasImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        (glyphs, glyphRects) = Self.glyphTexture(device: device, queue: queue)
    }

    /// A premultiplied RGBA texture with mipmaps (sprites are drawn at about half their pixel size).
    static func texture(_ image: CGImage, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return upload(context, width: width, height: height, device: device, queue: queue)
    }

    private static func upload(_ context: CGContext, width: Int, height: Int, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: context.bytesPerRow)
        if let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
        }
        return texture
    }

    /// The prop labels in white at 2x, one cell each.
    private static func glyphTexture(device: MTLDevice, queue: MTLCommandQueue) -> (MTLTexture?, [String: CGRect]) {
        let cell = CGSize(width: DashiiDrawList.textSize.width * 2, height: DashiiDrawList.textSize.height * 2)
        let width = Int(cell.width) * labels.count, height = Int(cell.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return (nil, [:]) }
        // Rows go top-down in the texture: flip so text isn't upside down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor.white]
        var rects: [String: CGRect] = [:]
        for (index, label) in labels.enumerated() {
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            let origin = CGPoint(x: CGFloat(index) * cell.width + (cell.width - size.width) / 2, y: (cell.height - size.height) / 2)
            text.draw(at: origin)
            rects[label] = CGRect(x: CGFloat(index) / CGFloat(labels.count), y: 0, width: 1 / CGFloat(labels.count), height: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return (upload(context, width: width, height: height, device: device, queue: queue), rects)
    }

    /// The GPU instances for a draw list in a view of `size` points.
    func instances(_ list: DashiiDrawList, size: CGSize, regions: [String: DashiiAtlas.Region]) -> [DashiiInstance] {
        guard size.width > 0, size.height > 0 else { return [] }
        let toClip = CGAffineTransform(a: 2 / size.width, b: 0, c: 0, d: -2 / size.height, tx: -1, ty: 1)
        var result: [DashiiInstance] = []
        result.reserveCapacity(list.primitives.count)
        for primitive in list.primitives {
            let m = primitive.transform.concatenating(toClip)
            var item = DashiiInstance(linear: SIMD4(Float(m.a), Float(m.b), Float(m.c), Float(m.d)), translation: SIMD4(Float(m.tx), Float(m.ty), 0, 0),
                                      quad: .zero, shape: .zero, geometry: .zero, uv: .zero, color: .zero, stroke: .zero, glow: .zero)
            let glowRadius = primitive.glow?.radius ?? 0
            item.glow = primitive.glow?.color.simd ?? .zero
            func quad(_ rect: CGRect) -> SIMD4<Float> { SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)) }
            switch primitive.shape {
            case .sprite(let name):
                guard let region = regions[name], atlasSize.width > 0 else { continue }
                item.shape.x = DashiiInstance.Kind.sprite.rawValue
                item.quad = quad(primitive.rect)
                item.uv = SIMD4(Float(region.x / atlasSize.width), Float(region.y / atlasSize.height),
                                Float((region.x + region.width) / atlasSize.width), Float((region.y + region.height) / atlasSize.height))
                item.color = SIMD4(1, 1, 1, Float(primitive.opacity))
            case .roundRect(let radius, let fill, let stroke, let lineWidth):
                item.shape = SIMD4(DashiiInstance.Kind.roundRect.rawValue, Float(radius), Float(stroke == nil ? 0 : lineWidth), Float(glowRadius))
                item.geometry = quad(primitive.rect)
                item.quad = quad(primitive.rect.insetBy(dx: -(lineWidth / 2 + glowRadius * 3 + 1), dy: -(lineWidth / 2 + glowRadius * 3 + 1)))
                item.color = fill?.simd ?? .zero
                item.stroke = stroke?.simd ?? .zero
            case .segment(let from, let to, let width, let color, let roundCaps):
                item.shape = SIMD4(DashiiInstance.Kind.segment.rawValue, Float(width), roundCaps ? 1 : 0, Float(glowRadius))
                item.geometry = SIMD4(Float(from.x), Float(from.y), Float(to.x), Float(to.y))
                item.quad = quad(primitive.rect.insetBy(dx: -(glowRadius * 3 + 1), dy: -(glowRadius * 3 + 1)))
                item.color = color.simd
            case .text(let string, let color):
                guard let cell = glyphRects[string] else { continue }
                item.shape.x = DashiiInstance.Kind.text.rawValue
                item.quad = quad(primitive.rect)
                item.uv = SIMD4(Float(cell.minX), Float(cell.minY), Float(cell.maxX), Float(cell.maxY))
                item.color = color.simd
            }
            result.append(item)
        }
        return result
    }

    /// Renders a draw list offscreen at `pixelScale`, for tests and snapshots.
    func image(_ list: DashiiDrawList, size: CGSize, pixelScale: CGFloat = 2) -> CGImage? {
        let width = Int(size.width * pixelScale), height = Int(size.height * pixelScale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let instances = instances(list, size: size, regions: DashiiAssets.shared.atlas?.regions ?? [:])
        guard let target = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer(),
              let buffer = device.makeBuffer(length: max(1, instances.count) * MemoryLayout<DashiiInstance>.stride, options: .storageModeShared)
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(instances, buffer: buffer, into: encoder)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Encodes a draw list into a render pass.
    func encode(_ instances: [DashiiInstance], buffer: MTLBuffer, into encoder: MTLRenderCommandEncoder) {
        guard !instances.isEmpty, let atlas else { return }
        instances.withUnsafeBytes { bytes in buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.setFragmentTexture(glyphs ?? atlas, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }
}

/// Draws Dashii every display frame: the player builds the frame's draw list, the GPU draws it in
/// one instanced call. Three instance buffers rotate so the CPU never writes one the GPU reads.
@MainActor
final class DashiiMetalRenderer: NSObject, MTKViewDelegate {
    var direction = DashiiDirection()
    var scale: CGFloat = 0.55
    private let player = DashiiPlayer()
    private let gpu: DashiiGPU
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)

    init(gpu: DashiiGPU) {
        self.gpu = gpu
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let time = Date().timeIntervalSince(player.epoch)
        let list = player.frame(time: time, direction: direction, scale: scale)
        let instances = gpu.instances(list, size: view.bounds.size, regions: DashiiAssets.shared.atlas?.regions ?? [:])
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = gpu.queue.makeCommandBuffer(), let buffer = nextBuffer(length: instances.count * MemoryLayout<DashiiInstance>.stride),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        gpu.encode(instances, buffer: buffer, into: encoder)
        encoder.endEncoding()
        commands.present(drawable)
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.commit()
    }

    /// The next of three instance buffers, grown when a frame has more primitives.
    private func nextBuffer(length: Int) -> MTLBuffer? {
        inFlight.wait()
        let needed = max(length, MemoryLayout<DashiiInstance>.stride * 64)
        if buffers.count < 3 || buffers[bufferIndex].length < needed {
            guard let buffer = gpu.device.makeBuffer(length: needed * 2, options: .storageModeShared) else { inFlight.signal(); return nil }
            if buffers.count < 3 { buffers.append(buffer) } else { buffers[bufferIndex] = buffer }
            bufferIndex = buffers.count - 1 < bufferIndex ? 0 : bufferIndex
        }
        let buffer = buffers[min(bufferIndex, buffers.count - 1)]
        bufferIndex = (bufferIndex + 1) % 3
        return buffer
    }
}

/// An MTKView that stops drawing while its window can't be seen (occluded, minimized, other Space).
final class DashiiMTKView: MTKView {
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { isPaused = true; return }
        update(window)
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, let window = self.window { self.update(window) } }
        }
    }

    private func update(_ window: NSWindow) {
        isPaused = !window.occlusionState.contains(.visible)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Dashii in SwiftUI through Metal; falls back to Core Graphics without a Metal device.
struct DashiiMetalView: NSViewRepresentable {
    var direction: DashiiDirection
    var scale: CGFloat

    func makeCoordinator() -> DashiiMetalRenderer? {
        DashiiGPU.shared.map(DashiiMetalRenderer.init)
    }

    func makeNSView(context: Context) -> NSView {
        guard let renderer = context.coordinator, let gpu = DashiiGPU.shared else {
            return NSHostingView(rootView: DashiiCanvasFallback(direction: direction, scale: scale))
        }
        let view = DashiiMTKView(frame: .zero, device: gpu.device)
        view.colorPixelFormat = DashiiGPU.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        renderer.direction = direction
        renderer.scale = scale
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let renderer = context.coordinator {
            renderer.direction = direction
            renderer.scale = scale
        } else if let hosting = view as? NSHostingView<DashiiCanvasFallback> {
            hosting.rootView = DashiiCanvasFallback(direction: direction, scale: scale)
        }
    }
}

/// The same draw list through Core Graphics, for Macs without a Metal device.
struct DashiiCanvasFallback: View {
    var direction: DashiiDirection
    var scale: CGFloat
    @State private var player = DashiiPlayer()

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSince(player.epoch)
            Canvas { context, _ in
                player.frame(time: time, direction: direction, scale: scale).replay(in: &context)
            }
        }
    }
}
