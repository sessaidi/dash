import SwiftUI
import Testing
@testable import Dash

/// Renders Dashii turned toward a pointer on each side, so the headset can be checked by eye.
/// Set DASHII_RENDER_DIR to keep the PNGs.
@MainActor
struct DashiiRenderTests {
    @Test(arguments: [-60.0, -45.0, -30.0, -15.0, 0.0, 15.0, 30.0, 45.0, 60.0])
    func rendersTurnedHeads(yaw: Double) throws {
        let player = DashiiPlayer()
        let direction = DashiiDirection(clip: .idle, fidgets: false, yaw: yaw)
        var image: CGImage?
        // Enough frames for the smoothed gaze and turn to settle.
        for frame in 0...90 {
            let renderer = ImageRenderer(content: Canvas { context, _ in
                player.render(into: &context, time: Double(frame) / 30, direction: direction, scale: 1)
            }.frame(width: DashiiView.size(scale: 1).width, height: DashiiView.size(scale: 1).height))
            image = renderer.cgImage
        }
        let rendered = try #require(image)
        #expect(rendered.width > 0)
        if let dir = ProcessInfo.processInfo.environment["DASHII_RENDER_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("dashii_\(Int(yaw)).png")
            let rep = NSBitmapImageRep(cgImage: rendered)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
