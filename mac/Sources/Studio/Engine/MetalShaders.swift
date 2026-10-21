// Metal shading language source, compiled at runtime (Command Line Tools ship no offline metal compiler).
// Colour pipeline: source (YCbCr BT.601/709, video/full range, or BGRA) -> R'G'B' -> BT.709 inverse OETF -> LINEAR rgba16f
// canvas (all blending happens in linear light) -> BT.709 OETF -> BGRA8 output tagged BT.709.
let metalShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

constexpr sampler linSamp(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler nearSamp(coord::normalized, address::clamp_to_edge, filter::nearest);

inline float3 lin709(float3 v) {
    v = max(v, 0.0);
    return select(pow((v + 0.099) / 1.099, 1.0 / 0.45), v / 4.5, v < 0.081);
}
inline float3 enc709(float3 l) {
    l = clamp(l, 0.0, 1.0);
    return select(1.099 * pow(l, 0.45) - 0.099, 4.5 * l, l < 0.018);
}

// ---- conversion kernels -------------------------------------------------
struct ConvU { float4 a; float4 b; };   // a: yOff, yScale, cOff, cScale   b: Kr, Kb

kernel void convNV12(texture2d<float> yT [[texture(0)]], texture2d<float> cT [[texture(1)]],
                     texture2d<float, access::write> outT [[texture(2)]],
                     constant ConvU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outT.get_width() || gid.y >= outT.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(outT.get_width(), outT.get_height());
    float y = (yT.sample(linSamp, uv).r - u.a.x) * u.a.y;
    float2 c = (cT.sample(linSamp, uv).rg - u.a.z) * u.a.w;
    float Kr = u.b.x, Kb = u.b.y, Kg = 1.0 - Kr - Kb;
    float r = y + 2.0 * (1.0 - Kr) * c.y;
    float b = y + 2.0 * (1.0 - Kb) * c.x;
    float g = (y - Kr * r - Kb * b) / Kg;
    outT.write(float4(lin709(float3(r, g, b)), 1.0), gid);
}
kernel void convBGRA(texture2d<float> t [[texture(0)]], texture2d<float, access::write> outT [[texture(2)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outT.get_width() || gid.y >= outT.get_height()) return;
    float4 c = t.read(gid);
    outT.write(float4(lin709(c.rgb), 1.0), gid);
}

// ---- drawing -------------------------------------------------------------
struct QuadU { float4 rect; float4 uv; float4 c0; float4 c1; float4 p; float4 q; };
// p: kind(0 tex,1 solid,2 linear grad,3 radial), cornerRadius, borderWidth, opacity
// q: canvasW, canvasH, radial r0, radial r1
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vsQuad(uint vid [[vertex_id]], constant QuadU& u [[buffer(0)]]) {
    float2 c = float2(vid & 1, vid >> 1);
    float2 px = u.rect.xy + c * u.rect.zw;
    VOut o;
    o.pos = float4(px.x / u.q.x * 2.0 - 1.0, 1.0 - px.y / u.q.y * 2.0, 0.0, 1.0);
    o.uv = mix(u.uv.xy, u.uv.zw, c);
    return o;
}
vertex VOut vsFull(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 fsSlot(VOut in [[stage_in]], constant QuadU& u [[buffer(0)]],
                       texture2d<float> t [[texture(0)]]) {
    float2 pos = in.pos.xy;
    int kind = int(u.p.x);
    float3 rgb;
    if (kind == 0) rgb = clamp(t.sample(linSamp, in.uv).rgb, 0.0, 1.0);
    else if (kind == 1) rgb = lin709(u.c0.rgb);
    else if (kind == 2) {
        float tt = clamp((pos.x * u.q.x + pos.y * u.q.y) / (u.q.x * u.q.x + u.q.y * u.q.y), 0.0, 1.0);
        rgb = lin709(mix(u.c0.rgb, u.c1.rgb, tt));
    } else {
        float2 ctr = u.rect.xy + u.rect.zw * 0.5;
        float tt = clamp((length(pos - ctr) - u.q.z) / (u.q.w - u.q.z), 0.0, 1.0);
        rgb = lin709(mix(u.c0.rgb, u.c1.rgb, tt));
    }
    float cov = 1.0;
    if (u.p.y > 0.0) {
        float2 half2 = u.rect.zw * 0.5;
        float2 pp = pos - (u.rect.xy + half2);
        float2 qd = abs(pp) - (half2 - u.p.y);
        float d = length(max(qd, 0.0)) + min(max(qd.x, qd.y), 0.0) - u.p.y;   // <0 inside
        cov = clamp(0.5 - d, 0.0, 1.0);
        if (u.p.z > 0.0) {
            float ring = clamp(d + u.p.z + 0.5, 0.0, 1.0) * 0.55;
            rgb = mix(rgb, lin709(float3(45.0, 212.0, 196.0) / 255.0), ring);
        }
    }
    float a = cov * u.p.w;
    return float4(rgb * a, a);
}

fragment float4 fsSprite(VOut in [[stage_in]], constant QuadU& u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
    float4 c = t.sample(linSamp, in.uv);          // premultiplied, BT.709-encoded
    float3 rgb = c.a > 0.0 ? c.rgb / c.a : float3(0.0);
    float a = c.a * u.p.w;
    return float4(lin709(rgb) * a, a);
}

fragment float4 fsMix(VOut in [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                      constant float& t [[buffer(0)]]) {
    return mix(a.sample(nearSamp, in.uv), b.sample(nearSamp, in.uv), t);
}
fragment float4 fsOut(VOut in [[stage_in]], texture2d<float> c [[texture(0)]]) {
    float3 l = c.sample(linSamp, in.uv).rgb;
    // 1/255 triangular-free ordered dither to hide banding in dark gradients
    float n = fract(52.9829189 * fract(dot(in.pos.xy, float2(0.06711056, 0.00583715)))) - 0.5;
    return float4(clamp(enc709(l) + n / 255.0, 0.0, 1.0), 1.0);
}
"""#
