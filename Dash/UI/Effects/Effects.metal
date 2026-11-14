#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Indigo, violet and cyan flowing around a shape's centre: the "Claude is working" ring.
/// Used as a shape style, so `position` is in the shape's bounding rect.
[[ stitchable ]] half4 thinkingGlow(float2 position, float4 bounds, float time) {
    float2 size = max(bounds.zw, float2(1.0));
    // Angle around the centre, corrected for the aspect ratio so the colours travel evenly
    // along long capsules too.
    float2 p = (position - size * 0.5) / size;
    float angle = atan2(p.y, p.x);
    float s = fract(angle / (2.0 * M_PI_F) + 0.5 + time * 0.22);
    half3 indigo = half3(0.36, 0.42, 1.0);
    half3 violet = half3(0.78, 0.36, 1.0);
    half3 cyan = half3(0.25, 0.86, 1.0);
    half3 colour = s < 1.0 / 3.0 ? mix(indigo, violet, half(s * 3.0))
                 : s < 2.0 / 3.0 ? mix(violet, cyan, half(s * 3.0 - 1.0))
                 : mix(cyan, indigo, half(s * 3.0 - 2.0));
    half pulse = half(0.82 + 0.18 * sin(time * 3.0 + angle * 2.0));
    return half4(colour * pulse, 1.0);
}

/// A soft, rippling halo behind Dashii. `strength` 0…1 fades it in and out.
/// Premultiplied output, transparent at the edges.
[[ stitchable ]] half4 dashiiAura(float2 position, float4 bounds, float time, float strength) {
    float2 size = max(bounds.zw, float2(1.0));
    float2 p = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    float r = length(p);
    float a = atan2(p.y, p.x);
    float wobble = 0.07 * sin(a * 5.0 + time * 2.4) + 0.04 * sin(a * 3.0 - time * 1.7);
    float glow = smoothstep(1.0, 0.2, r + wobble);
    half3 colour = mix(half3(0.30, 0.85, 1.0), half3(0.66, 0.40, 1.0), half(0.5 + 0.5 * sin(time * 1.3 + a)));
    half alpha = half(glow * glow * strength * 0.5);
    return half4(colour * alpha, alpha);
}
