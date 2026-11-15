#include <metal_stdlib>
using namespace metal;

// Dashii's renderer: every primitive of a frame is one instance of a 4-vertex quad.
// Sprites and labels sample premultiplied textures; rounded rectangles and segments are
// signed-distance shapes with analytic antialiasing and an optional outer glow.
// Must match DashiiInstance in DashiiMetal.swift.
struct DashiiInstance {
    float4 linear;      // a, b, c, d of the local -> clip affine transform
    float4 translation; // tx, ty
    float4 quad;        // the quad in local space: x, y, width, height (grown by the glow)
    float4 shape;       // kind, radius or width, stroke width, glow radius
    float4 geometry;    // rounded rect: x, y, width, height; segment: x0, y0, x1, y1
    float4 uv;          // u0, v0, u1, v1
    float4 color;       // fill / segment / tint colour, straight alpha
    float4 stroke;      // stroke colour, straight alpha (rounded rects)
    float4 glow;        // glow colour, straight alpha
};

struct DashiiVaryings {
    float4 position [[position]];
    float2 local;
    float2 uv;
    uint instance [[flat]];
};

vertex DashiiVaryings dashii_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                    constant DashiiInstance *instances [[buffer(0)]]) {
    DashiiInstance item = instances[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = item.quad.xy + corner * item.quad.zw;
    float2 clip = float2(item.linear.x * p.x + item.linear.z * p.y + item.translation.x,
                         item.linear.y * p.x + item.linear.w * p.y + item.translation.y);
    DashiiVaryings out;
    out.position = float4(clip, 0, 1);
    out.local = p;
    out.uv = mix(item.uv.xy, item.uv.zw, corner);
    out.instance = iid;
    return out;
}

static float roundBox(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float segmentDistance(float2 p, float2 a, float2 b, bool round) {
    float2 pa = p - a, ba = b - a;
    float len2 = max(dot(ba, ba), 1e-6);
    float t = dot(pa, ba) / len2;
    if (!round && (t < 0.0 || t > 1.0)) {
        return 1e5;
    }
    return length(pa - ba * clamp(t, 0.0, 1.0));
}

// Coverage of a shape from its distance, antialiased over one pixel.
static float coverage(float d) {
    float w = max(fwidth(d), 1e-4);
    return clamp(0.5 - d / w, 0.0, 1.0);
}

// Premultiplied `top` over premultiplied `bottom`.
static float4 over(float4 top, float4 bottom) {
    return top + bottom * (1.0 - top.a);
}

static float4 premultiply(float4 c, float a) {
    return float4(c.rgb * c.a * a, c.a * a);
}

fragment float4 dashii_fragment(DashiiVaryings in [[stage_in]],
                                constant DashiiInstance *instances [[buffer(0)]],
                                texture2d<float> atlas [[texture(0)]],
                                texture2d<float> glyphs [[texture(1)]],
                                sampler linearSampler [[sampler(0)]]) {
    DashiiInstance item = instances[in.instance];
    int kind = int(item.shape.x);
    if (kind == 0) {
        // Sprite: premultiplied atlas texel, faded by the opacity in color.a.
        return atlas.sample(linearSampler, in.uv) * item.color.a;
    }
    if (kind == 3) {
        // Label: white glyph coverage tinted.
        float a = glyphs.sample(linearSampler, in.uv).a;
        return premultiply(item.color, a);
    }
    float d;
    float4 result = float4(0);
    if (kind == 1) {
        float2 center = item.geometry.xy + item.geometry.zw * 0.5;
        float2 halfSize = item.geometry.zw * 0.5;
        float radius = min(item.shape.y, min(halfSize.x, halfSize.y));
        d = roundBox(in.local - center, halfSize, radius);
        float lineWidth = item.shape.z;
        float4 fill = premultiply(item.color, coverage(d));
        result = fill;
        if (lineWidth > 0.0) {
            float edge = abs(d) - lineWidth * 0.5;
            result = over(premultiply(item.stroke, coverage(edge)), fill);
            d = min(d, edge);
        }
    } else {
        bool round = item.shape.z > 0.5;
        d = segmentDistance(in.local, item.geometry.xy, item.geometry.zw, round) - item.shape.y * 0.5;
        result = premultiply(item.color, coverage(d));
    }
    float glowRadius = item.shape.w;
    if (glowRadius > 0.0 && item.glow.a > 0.0) {
        // A soft falloff outside the shape, under it.
        float g = exp(-max(d, 0.0) * max(d, 0.0) / (glowRadius * glowRadius)) * 0.85;
        result = over(result, premultiply(item.glow, g));
    }
    return result;
}
