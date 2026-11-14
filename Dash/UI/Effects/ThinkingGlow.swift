import SwiftUI

/// A coloured ring that flows around `shape` while `active` (Claude is working), drawn by the
/// `thinkingGlow` Metal shader: a sharp line plus a blurred copy for the glow.
struct ThinkingGlow<S: InsettableShape>: ViewModifier {
    var active: Bool
    var shape: S

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    TimelineView(.animation) { timeline in
                        let style = ShaderLibrary.thinkingGlow(.boundingRect, .float(Effects.time(timeline.date)))
                        ZStack {
                            shape.strokeBorder(style, lineWidth: 6).blur(radius: 9).opacity(0.75)
                            shape.strokeBorder(style, lineWidth: 1.5)
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.45), value: active)
    }
}

/// Dashii's halo while thinking or working, from the `dashiiAura` Metal shader.
struct DashiiAura: View {
    var active: Bool
    @State private var strength = 0.0

    var body: some View {
        TimelineView(.animation(paused: strength == 0 && !active)) { timeline in
            Rectangle().fill(ShaderLibrary.dashiiAura(.boundingRect, .float(Effects.time(timeline.date)), .float(strength)))
        }
        .allowsHitTesting(false)
        .onAppear { strength = active ? 1 : 0 }
        .onChange(of: active) { withAnimation(.smooth(duration: 0.6)) { strength = active ? 1 : 0 } }
    }
}

enum Effects {
    /// Seconds for shaders, kept small so Float stays precise.
    static func time(_ date: Date) -> Float {
        Float(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
    }
}

extension View {
    func thinkingGlow(_ active: Bool, in shape: some InsettableShape) -> some View {
        modifier(ThinkingGlow(active: active, shape: shape))
    }
}
