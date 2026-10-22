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

inline float3 linSRGB(float3 v) {
    v = max(v, 0.0);
    return select(pow((v + 0.055) / 1.055, 2.4), v / 12.92, v <= 0.04045);
}

// ---- conversion kernels -------------------------------------------------
struct ConvU { float4 a; float4 b; float4 m0; float4 m1; float4 m2; };   // a: yOff, yScale, cOff, cScale   b: Kr, Kb, transfer(0 BT.709, 1 sRGB, 2 gamma 2.2)   m: linear 3x3 gamut matrix (rows) to BT.709 primaries

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
    float3 e = float3(r, g, b);
    float3 l = u.b.z < 0.5 ? lin709(e) : (u.b.z < 1.5 ? linSRGB(e) : pow(max(e, 0.0), 2.2));
    l = float3(dot(u.m0.xyz, l), dot(u.m1.xyz, l), dot(u.m2.xyz, l));
    outT.write(float4(l, 1.0), gid);
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
    float2 d = mix(u.uv.xy, u.uv.zw, c);          // display-space coordinate
    if (u.p.x < 0.5 || u.p.x > 3.5) {             // textured quads: flip + quarter-turn (c1.z flip, c1.w turns clockwise)
        if (u.c1.z > 0.5) d.x = 1.0 - d.x;
        int k = int(u.c1.w + 0.5);
        if (k == 1) d = float2(d.y, 1.0 - d.x);
        else if (k == 2) d = float2(1.0 - d.x, 1.0 - d.y);
        else if (k == 3) d = float2(1.0 - d.y, d.x);
    }
    o.uv = d;
    return o;
}
vertex VOut vsFull(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Catmull-Rom bicubic via 9 bilinear taps.
inline float3 catmull(texture2d<float> t, float2 uv) {
    float2 sz = float2(t.get_width(), t.get_height());
    float2 pos = uv * sz;
    float2 c = floor(pos - 0.5) + 0.5;
    float2 f = pos - c;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 p0 = (c - 1.0) / sz, p3 = (c + 2.0) / sz, p12 = (c + w2 / w12) / sz;
    float3 r = t.sample(linSamp, float2(p0.x, p0.y)).rgb * (w0.x * w0.y)
             + t.sample(linSamp, float2(p12.x, p0.y)).rgb * (w12.x * w0.y)
             + t.sample(linSamp, float2(p3.x, p0.y)).rgb * (w3.x * w0.y)
             + t.sample(linSamp, float2(p0.x, p12.y)).rgb * (w0.x * w12.y)
             + t.sample(linSamp, float2(p12.x, p12.y)).rgb * (w12.x * w12.y)
             + t.sample(linSamp, float2(p3.x, p12.y)).rgb * (w3.x * w12.y)
             + t.sample(linSamp, float2(p0.x, p3.y)).rgb * (w0.x * w3.y)
             + t.sample(linSamp, float2(p12.x, p3.y)).rgb * (w12.x * w3.y)
             + t.sample(linSamp, float2(p3.x, p3.y)).rgb * (w3.x * w3.y);
    return r;
}
// Upscale: Catmull-Rom + unsharp whose radius is ONE OUTPUT PIXEL and which is clamped to the local min/max (limited halo).
inline float3 upscale(texture2d<float> t, float2 uv, float amount) {
    float3 c = max(catmull(t, uv), 0.0);
    if (amount <= 0.0) return c;
    float2 dx = dfdx(uv), dy = dfdy(uv);
    float3 a = t.sample(linSamp, uv + dx).rgb, b = t.sample(linSamp, uv - dx).rgb;
    float3 d = t.sample(linSamp, uv + dy).rgb, e = t.sample(linSamp, uv - dy).rgb;
    float3 blur = (a + b + d + e) * 0.25;
    float3 lo = min(min(min(a, b), min(d, e)), c), hi = max(max(max(a, b), max(d, e)), c);
    return clamp(c + amount * (c - blur), lo, hi);
}

fragment float4 fsSlot(VOut in [[stage_in]], constant QuadU& u [[buffer(0)]],
                       texture2d<float> t [[texture(0)]]) {
    float2 pos = in.pos.xy;
    int kind = int(u.p.x);
    float3 rgb;
    if (kind == 0) rgb = clamp(t.sample(linSamp, in.uv).rgb, 0.0, 1.0);
    else if (kind == 4) rgb = clamp(upscale(t, in.uv, u.c0.x), 0.0, 1.0);
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
struct VividU { float4 v; };   // v: saturation, contrast, sharpen, on
fragment float4 fsOut(VOut in [[stage_in]], texture2d<float> c [[texture(0)]], constant VividU& vu [[buffer(0)]]) {
    float3 l = c.sample(linSamp, in.uv).rgb;
    if (vu.v.z > 0.0) {                              // adaptive sharpen: 1 px unsharp, clamped to the 5-tap neighbourhood
        float2 px = 1.0 / float2(c.get_width(), c.get_height());
        float3 a = c.sample(nearSamp, in.uv + float2(px.x, 0)).rgb, b = c.sample(nearSamp, in.uv - float2(px.x, 0)).rgb;
        float3 d = c.sample(nearSamp, in.uv + float2(0, px.y)).rgb, e = c.sample(nearSamp, in.uv - float2(0, px.y)).rgb;
        float3 blur = (a + b + d + e) * 0.25;
        float3 lo = min(min(min(a, b), min(d, e)), l), hi = max(max(max(a, b), max(d, e)), l);
        l = clamp(l + vu.v.z * (l - blur), lo, hi);
    }
    float3 e = enc709(l);
    if (vu.v.w > 0.5) {
        float y = dot(e, float3(0.2126, 0.7152, 0.0722));
        e = clamp(float3(y) + (e - float3(y)) * vu.v.x, 0.0, 1.0);          // saturation around luma (encoded domain)
        float3 s = e * e * (3.0 - 2.0 * e);                                  // smoothstep S-curve keeps 0 and 1 fixed
        e = mix(e, s, vu.v.y);
    }
    // 1/255 ordered dither to hide banding in dark gradients
    float n = fract(52.9829189 * fract(dot(in.pos.xy, float2(0.06711056, 0.00583715)))) - 0.5;
    return float4(clamp(e + n / 255.0, 0.0, 1.0), 1.0);
}
"""#
