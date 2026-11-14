import AppKit
import SwiftUI
import Testing
@testable import Dash

/// The Metal shaders compile into the app and actually paint.
@MainActor
struct EffectsTests {
    private func pixels(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    @Test func thinkingGlowPaintsTheBorderInColour() throws {
        let bitmap = try pixels(Color.clear.thinkingGlow(true, in: RoundedRectangle(cornerRadius: 12)), size: CGSize(width: 200, height: 60))
        let edge = try #require(bitmap.colorAt(x: 100, y: 0))
        #expect(edge.alphaComponent > 0.3 && edge.blueComponent > 0.5)
        // Off: nothing drawn.
        let off = try pixels(Color.clear.thinkingGlow(false, in: RoundedRectangle(cornerRadius: 12)), size: CGSize(width: 200, height: 60))
        #expect((off.colorAt(x: 100, y: 0)?.alphaComponent ?? 0) < 0.01)
    }

    @Test func auraGlowsInTheMiddleAndFadesOut() throws {
        let bitmap = try pixels(Rectangle().fill(ShaderLibrary.dashiiAura(.boundingRect, .float(1), .float(1))), size: CGSize(width: 100, height: 100))
        #expect((bitmap.colorAt(x: 50, y: 50)?.alphaComponent ?? 0) > 0.2)
        #expect((bitmap.colorAt(x: 1, y: 1)?.alphaComponent ?? 1) < 0.02)
    }
}
