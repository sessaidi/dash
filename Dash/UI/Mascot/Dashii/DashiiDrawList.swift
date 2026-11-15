import CoreGraphics
import SwiftUI

/// A straight (not premultiplied) RGBA colour.
struct DashiiColor: Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    init(_ hex: UInt32, alpha: Double = 1) {
        red = Float((hex >> 16) & 0xff) / 255
        green = Float((hex >> 8) & 0xff) / 255
        blue = Float(hex & 0xff) / 255
        self.alpha = Float(alpha)
    }

    var simd: SIMD4<Float> { SIMD4(red, green, blue, alpha) }
    var swiftUI: Color { Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha)) }
}

/// A soft outer glow around a shape (what the web runtime did with canvas shadows).
struct DashiiGlow: Equatable, Sendable {
    var color: DashiiColor
    var radius: CGFloat
}

/// Line segments to stroke with round caps; curves are flattened into short segments.
struct DashiiStroke: Equatable, Sendable {
    var segments: [(CGPoint, CGPoint)] = []

    mutating func line(_ from: CGPoint, _ to: CGPoint) { segments.append((from, to)) }

    mutating func polyline(_ points: [CGPoint]) {
        for (a, b) in zip(points, points.dropFirst()) { line(a, b) }
    }

    mutating func quad(_ from: CGPoint, control: CGPoint, to: CGPoint, steps: Int = 8) {
        var points: [CGPoint] = []
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps), u = 1 - t
            points.append(CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                                  y: u * u * from.y + 2 * u * t * control.y + t * t * to.y))
        }
        polyline(points)
    }

    static func == (a: DashiiStroke, b: DashiiStroke) -> Bool {
        a.segments.count == b.segments.count && zip(a.segments, b.segments).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

/// One drawn thing. Geometry is in its own local space; `transform` maps it to view points.
struct DashiiPrimitive: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        /// An atlas region stretched over `rect`.
        case sprite(region: String)
        /// A rounded rectangle over `rect`, filled and/or stroked (centred on the edge).
        case roundRect(radius: CGFloat, fill: DashiiColor?, stroke: DashiiColor?, lineWidth: CGFloat)
        /// A segment with round (or butt) caps.
        case segment(from: CGPoint, to: CGPoint, width: CGFloat, color: DashiiColor, roundCaps: Bool)
        /// A short label centred in `rect`.
        case text(String, color: DashiiColor)
    }

    var shape: Shape
    var rect: CGRect
    var transform: CGAffineTransform
    var opacity: Double = 1
    var glow: DashiiGlow?
}

/// A frame of Dashii as primitives, back to front. The Metal renderer draws it on the GPU; the
/// Core Graphics replay is the fallback when no Metal device is available.
struct DashiiDrawList: Equatable, Sendable {
    private(set) var primitives: [DashiiPrimitive] = []

    /// Points a text label takes, for its quad; the glyphs come from `DashiiGlyphs`.
    static let textSize = CGSize(width: 44, height: 26)

    mutating func sprite(_ region: String, rect: CGRect, transform: CGAffineTransform, opacity: Double = 1) {
        primitives.append(DashiiPrimitive(shape: .sprite(region: region), rect: rect, transform: transform, opacity: opacity))
    }

    mutating func roundRect(_ rect: CGRect, radius: CGFloat, transform: CGAffineTransform, fill: DashiiColor? = nil,
                            stroke: DashiiColor? = nil, lineWidth: CGFloat = 0, glow: DashiiGlow? = nil) {
        primitives.append(DashiiPrimitive(shape: .roundRect(radius: radius, fill: fill, stroke: stroke, lineWidth: lineWidth),
                                          rect: rect, transform: transform, glow: glow))
    }

    mutating func stroke(_ stroke: DashiiStroke, width: CGFloat, transform: CGAffineTransform, color: DashiiColor,
                         roundCaps: Bool = true, glow: DashiiGlow? = nil) {
        func add(color: DashiiColor, glow: DashiiGlow?) {
            for (from, to) in stroke.segments {
                let bounds = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
                    .insetBy(dx: -width / 2, dy: -width / 2)
                primitives.append(DashiiPrimitive(shape: .segment(from: from, to: to, width: width, color: color, roundCaps: roundCaps),
                                                  rect: bounds, transform: transform, glow: glow))
            }
        }
        // All the glow first (each segment's glow alone, faint so overlaps don't band), then the
        // line on top, so one segment's glow never washes over its neighbour.
        if let glow {
            var faint = glow
            faint.color.alpha *= stroke.segments.count > 1 ? 0.55 : 1
            add(color: DashiiColor(0, alpha: 0), glow: faint)
        }
        add(color: color, glow: nil)
    }

    mutating func text(_ string: String, center: CGPoint, transform: CGAffineTransform, color: DashiiColor) {
        let size = Self.textSize
        primitives.append(DashiiPrimitive(shape: .text(string, color: color),
                                          rect: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                                          transform: transform))
    }

    /// Draws the list with Core Graphics (no GPU), e.g. without a Metal device.
    func replay(in context: inout GraphicsContext, assets: DashiiAssets = .shared) {
        for primitive in primitives {
            var local = context
            local.concatenate(primitive.transform)
            local.opacity = primitive.opacity
            if let glow = primitive.glow { local.addFilter(.shadow(color: glow.color.swiftUI, radius: glow.radius)) }
            switch primitive.shape {
            case .sprite(let region):
                if let image = assets.regions[region] { local.draw(Image(decorative: image, scale: 1), in: primitive.rect) }
            case .roundRect(let radius, let fill, let stroke, let lineWidth):
                let path = Path(roundedRect: primitive.rect, cornerRadius: radius)
                if let fill { local.fill(path, with: .color(fill.swiftUI)) }
                if let stroke, lineWidth > 0 { local.stroke(path, with: .color(stroke.swiftUI), lineWidth: lineWidth) }
            case .segment(let from, let to, let width, let color, let roundCaps):
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                local.stroke(path, with: .color(color.swiftUI), style: StrokeStyle(lineWidth: width, lineCap: roundCaps ? .round : .butt))
            case .text(let string, let color):
                local.draw(Text(string).font(.system(size: 20, weight: .semibold)).foregroundStyle(color.swiftUI),
                           at: CGPoint(x: primitive.rect.midX, y: primitive.rect.midY))
            }
        }
    }
}
