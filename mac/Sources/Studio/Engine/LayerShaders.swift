// Metal source for the layer renderer. Compiled together with metalShaderSource (shares lin709/enc709/catmull/upscale/samplers).
// Layer compositing happens in ENCODED (display-referred, BT.709 OETF) space like Photoshop / After Effects 8-bit comps, so
// semi-transparent layers, gradients, glows and blend modes look exactly like the designer's preview. Sources are decoded to linear for
// scaling (Lanczos / Catmull-Rom) and encoded when they are drawn; sprites (CoreGraphics art) are already encoded premultiplied.
let layerShaderSource = #"""

struct LayerU {
    float4 box;      // x, y, w, h of the unrotated box in target pixels
    float4 geom;     // cos, sin, anchorX, anchorY (target px)
    float4 pad;      // quad expansion px, target w, target h, time
    float4 uv;       // content uv rect (u0, v0, u1, v1) over the content region
    float4 lb;       // content region in box-normalised coords (x0, y0, x1, y1); outside = letterbox bars
    float4 content;  // kind, upscale sharpen, source xf flip, source quarter turns
    float4 c0;       // solid / gradient start (encoded straight rgba)
    float4 c1;       // gradient end
    float4 grad;     // dirCos, dirSin, radial cx, radial cy
    float4 mask;     // kind, radius px, feather px, invert
    float4 mask2;    // skew px, radial outer radius (fraction of half-diagonal), radial inner radius px
    float4 border;   // width px, gradient flag, dirCos, dirSin
    float4 bc0;
    float4 bc1;
    float4 anim;     // opacity, wipe fraction, wipe dirCos, wipe dirSin
    float4 adj0;     // brightness, contrast, saturation, hue (rad)
    float4 adj1;     // tint rgb (encoded), strength
    float4 key0;     // key rgb (encoded), enabled
    float4 key1;     // similarity, smoothness, spill
    float4 fx0;      // chromatic aberration px, blur px, pixelate px, scanlines
    float4 fx1;      // glitch
    float4 shd;      // mode (0 main, 1 shadow, 2 glow), radius px, intensity, overlay-blend flag
    float4 shdc;     // shadow / glow colour (encoded straight)
    float4 bars;     // letterbox bar colour (encoded premultiplied)
    float4 eff0;     // effect kind, intensity, speed, size
    float4 eff1;     // seed, thickness, angle (rad), count
    float4 ext0;     // advanced effects: local time, active | kind 9: fade px top, bottom, fade strength top, bottom
    float4 ext1;     // shine: intensity, half-width, dirCos, dirSin
    float4 ext2;     // shine colour
    float4 ext3;     // shine: phase, active, shimmer
};
struct LOut { float4 pos [[position]]; float2 lp; };

constexpr sampler zeroSamp(coord::normalized, address::clamp_to_zero, filter::linear);
constexpr sampler repSamp(coord::normalized, address::repeat, filter::linear);

inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vertex LOut vsLayer(uint vid [[vertex_id]], constant LayerU& u [[buffer(0)]]) {
    float2 c = float2(vid & 1, vid >> 1);
    float pad = u.pad.x;
    float2 lp = c * (u.box.zw + 2.0 * pad) - pad;
    float2 rel = u.box.xy + lp - u.geom.zw;
    float2 px = float2(rel.x * u.geom.x - rel.y * u.geom.y, rel.x * u.geom.y + rel.y * u.geom.x) + u.geom.zw;
    LOut o;
    o.pos = float4(px.x / u.pad.y * 2.0 - 1.0, 1.0 - px.y / u.pad.z * 2.0, 0.0, 1.0);
    o.lp = lp;
    return o;
}

inline float sdBox(float2 p, float2 hs, float r) {
    r = min(r, min(hs.x, hs.y));
    float2 q = abs(p) - (hs - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
inline float layerSDF(constant LayerU& u, float2 lp, float2 size) {
    float2 hs = size * 0.5, p = lp - hs;
    int k = int(u.mask.x + 0.5);
    if (k == 2) return (length(p / hs) - 1.0) * min(hs.x, hs.y);
    if (k == 3) {
        float2 q = abs(float2(p.x / hs.x * 1.1547, p.y / hs.y));
        float2 kk = float2(-0.866025, 0.5);
        q -= 2.0 * min(dot(kk, q), 0.0) * kk;
        q -= float2(clamp(q.x, -0.57735, 0.57735), 1.0);
        return length(q) * sign(q.y) * min(hs.y, hs.x / 1.1547);
    }
    if (k == 4) {
        float sk = u.mask2.x;
        float cx = -sk * (p.y / size.y);
        float hw = hs.x - abs(sk) * 0.5;
        float2 q = float2(abs(p.x - cx) - hw, abs(p.y) - hs.y);
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    }
    return sdBox(p, hs, u.mask.y);
}
inline float layerCov(constant LayerU& u, float2 lp, float2 size, texture2d<float> maskT) {
    int k = int(u.mask.x + 0.5);
    float cov;
    if (k == 5) {
        float m = dot(maskT.sample(zeroSamp, lp / size).rgb, float3(0.3333));
        cov = m * clamp(0.5 - sdBox(lp - size * 0.5, size * 0.5, 0.0), 0.0, 1.0);
    } else {
        float d = layerSDF(u, lp, size);
        cov = clamp(0.5 - d / max(u.mask.z, 1.0), 0.0, 1.0);
    }
    return u.mask.w > 0.5 ? 1.0 - cov : cov;
}

// ---- procedural effect content (kind 8) ---------------------------------------------------------------------------
inline float4 premul(float4 c) { return float4(c.rgb * c.a, c.a); }
\#(advancedShaderSource)
inline float4 effectColor(constant LayerU& u, float2 lp, float2 size, float2 fragPos) {
    int ek = int(u.eff0.x + 0.5);
    float inten = u.eff0.y, speed = u.eff0.z, sz = u.eff0.w;
    float t = u.pad.w * speed;
    float th = u.eff1.y;
    float4 A = u.c0, B = u.c1;
    float2 uvn = lp / size;
    if (ek >= 30) return advEffect(u, lp, size, fragPos);
    if (ek == 10) {                                   // scanlines
        float s = 0.5 + 0.5 * sin(lp.y * 6.2831853 / max(sz, 2.0));
        float a = inten * 0.35 * s * A.a;
        return float4(A.rgb * a, a);
    }
    if (ek == 11) {                                   // vignette
        float2 q = (uvn - 0.5) * float2(1.15, 1.0) * 2.0;
        float v = smoothstep(0.55, 1.45, length(q));
        float a = clamp(v * inten * A.a, 0.0, 1.0);
        return float4(A.rgb * a, a);
    }
    if (ek == 12) {                                   // film grain
        float n = hash21(fragPos + floor(u.pad.w * 24.0) * 17.0);
        float a = abs(n - 0.5) * 2.0 * inten * 0.22;
        float c = n > 0.5 ? 1.0 : 0.0;
        return float4(c * a, c * a, c * a, a);
    }
    if (ek == 13) {                                   // light sweep
        float b = (uvn.x + uvn.y * 0.35) - (fract(t * 0.35) * 2.0 - 0.35);
        float a = exp(-b * b * 45.0) * inten * 0.8 * A.a;
        return float4(A.rgb * a, a);
    }
    if (ek == 14) {                                   // pulsing glow
        float r = length((uvn - 0.5) * 2.0);
        float a = pow(max(1.0 - r, 0.0), 2.0) * inten * (0.65 + 0.35 * sin(t * 6.2831853)) * A.a;
        return float4(A.rgb * a, a);
    }
    if (ek == 15) {                                   // HUD corner brackets
        float ix = min(lp.x, size.x - lp.x), iy = min(lp.y, size.y - lp.y);
        float on = ((ix < th && iy < sz) || (iy < th && ix < sz)) ? 1.0 : 0.0;
        float a = on * (0.8 + 0.2 * sin(t * 6.2831853 * 0.5)) * inten * A.a;
        return float4(A.rgb * a, a);
    }
    if (ek == 16) {                                   // radar sweep
        float2 pc = (lp - size * 0.5) / (min(size.x, size.y) * 0.5);
        float r = length(pc);
        float ang = atan2(pc.y, pc.x) / 6.2831853;
        float sweep = pow(1.0 - fract(t * 0.25 - ang), 5.0);
        float rings = max(max(1.0 - smoothstep(0.0, 0.018, abs(r - 0.333)), 1.0 - smoothstep(0.0, 0.018, abs(r - 0.666))), 1.0 - smoothstep(0.0, 0.022, abs(r - 1.0)));
        float cross = max(1.0 - smoothstep(0.0, 0.012, abs(pc.x)), 1.0 - smoothstep(0.0, 0.012, abs(pc.y))) * 0.5;
        float inside = r < 1.0 ? 1.0 : 0.0;
        float a = clamp(max(max(sweep * 0.65 * inside, rings * 0.6), cross * inside * 0.6), 0.0, 1.0) * inten;
        float3 col = mix(A.rgb, B.rgb, clamp(sweep, 0.0, 1.0));
        return float4(col * a, a);
    }
    if (ek == 17) {                                   // animated gradient
        float2 dir = float2(cos(u.eff1.z), sin(u.eff1.z));
        float proj = dot(uvn - 0.5, dir);
        float tt = fract(proj + t * 0.1);
        float tri = smoothstep(0.0, 1.0, abs(tt * 2.0 - 1.0));
        float4 c = mix(A, B, tri);
        return float4(c.rgb * c.a, c.a);
    }
    if (ek == 18) {                                   // glitch bars
        float slot = floor(u.pad.w * speed * 10.0);
        float band = floor(lp.y / (3.0 + 14.0 * hash21(float2(floor(lp.y / 40.0), slot))));
        float r1 = hash21(float2(band, slot + u.eff1.x));
        float act = r1 > (1.0 - 0.10 * inten) ? 1.0 : 0.0;
        float x0 = hash21(float2(band + 7.0, slot)) * size.x, w = hash21(float2(band + 3.0, slot)) * size.x * 0.5 + 20.0;
        float inr = (lp.x > x0 && lp.x < x0 + w) ? 1.0 : 0.0;
        float4 c = hash21(float2(band + 11.0, slot)) > 0.5 ? A : B;
        float a = act * inr * 0.55 * c.a;
        return float4(c.rgb * a, a);
    }
    if (ek == 19) {                                   // lightning
        float s = floor(t);
        float local = fract(t);
        float gate = hash21(float2(s, u.eff1.x)) > 0.25 ? 1.0 : 0.0;
        float env = exp(-local * 9.0) * (0.75 + 0.25 * sin(local * 70.0)) * gate;
        float h = hash21(float2(s * 1.7, u.eff1.x + 5.0));
        float y = uvn.y;
        float xb = 0.5 + (h - 0.5) * 0.6 + 0.10 * sin(y * 7.0 + h * 6.0) + 0.045 * sin(y * 23.0 + h * 9.0) + 0.018 * sin(y * 61.0 + h * 3.0);
        float dist = abs(lp.x - xb * size.x);
        float core = exp(-dist * dist / (2.0 * th * th));
        float halo = 0.45 * exp(-dist / 38.0);
        float a = clamp((core + halo) * env * inten, 0.0, 1.0);
        float flash = 0.05 * env * inten;
        float3 col = mix(A.rgb, float3(1.0), core);
        return float4(col * a + A.rgb * flash, clamp(a + flash, 0.0, 1.0));
    }
    return float4(0.0);
}

// ---- content fetch (premultiplied linear) -------------------------------------------------------------------------
inline float4 fetch(constant LayerU& u, texture2d<float> tex, float2 lp, float2 size, float2 fragPos) {
    int kind = int(u.content.x + 0.5);
    float2 uvn = lp / size;
    if (kind == 2) return premul(u.c0);
    if (kind == 3) {
        float ext = abs(u.grad.x) * size.x + abs(u.grad.y) * size.y;
        float t = clamp(0.5 + dot((uvn - 0.5) * size, u.grad.xy) / max(ext, 1.0), 0.0, 1.0);
        return premul(mix(u.c0, u.c1, t));
    }
    if (kind == 4) {
        float2 ctr = u.grad.zw;
        float outer = max(u.mask2.y * length(size) * 0.5, 1.0), inner = u.mask2.z;
        float t = clamp((length((uvn - ctr) * size) - inner) / max(outer - inner, 1.0), 0.0, 1.0);
        return premul(mix(u.c0, u.c1, t));
    }
    if (kind == 8) return effectColor(u, lp, size, fragPos);
    float2 t = (uvn - u.lb.xy) / (u.lb.zw - u.lb.xy);
    if (kind == 0 || kind == 6) {
        if (any(t < 0.0) || any(t > 1.0)) return u.bars;
        float2 d = mix(u.uv.xy, u.uv.zw, t);
        if (u.content.z > 0.5) d.x = 1.0 - d.x;
        int k = int(u.content.w + 0.5);
        if (k == 1) d = float2(d.y, 1.0 - d.x);
        else if (k == 2) d = float2(1.0 - d.x, 1.0 - d.y);
        else if (k == 3) d = float2(1.0 - d.y, d.x);
        float3 rgb = kind == 6 ? upscale(tex, d, u.content.y) : tex.sample(linSamp, d).rgb;
        return float4(enc709(clamp(rgb, 0.0, 1.0)), 1.0);
    }
    if (kind == 9) {                                  // clipped sprite window (scrolling board rows), soft top / bottom edges
        if (any(t < 0.0) || any(t > 1.0)) return float4(0.0);
        float4 s = tex.sample(zeroSamp, mix(u.uv.xy, u.uv.zw, t));
        float vh = (u.lb.w - u.lb.y) * size.y, y = t.y * vh;
        float f = 1.0;
        if (u.ext0.z > 0.0) f *= mix(1.0, smoothstep(0.0, max(u.ext0.x, 1.0), y), u.ext0.z);
        if (u.ext0.w > 0.0) f *= mix(1.0, smoothstep(0.0, max(u.ext0.y, 1.0), vh - y), u.ext0.w);
        return s * f;
    }
    float2 d = mix(u.uv.xy, u.uv.zw, t);
    float4 s = kind == 7 ? tex.sample(repSamp, d) : tex.sample(zeroSamp, d);
    return s;       // kind 1/7: encoded premultiplied sprite, kind 5: group (canvas space)
}

inline float3 hueRotate(float3 c, float a) {
    float cs = cos(a), sn = sin(a);
    float3x3 m = float3x3(
        float3(0.299 + 0.701 * cs + 0.168 * sn, 0.587 - 0.587 * cs + 0.330 * sn, 0.114 - 0.114 * cs - 0.497 * sn),
        float3(0.299 - 0.299 * cs - 0.328 * sn, 0.587 + 0.413 * cs + 0.035 * sn, 0.114 - 0.114 * cs + 0.292 * sn),
        float3(0.299 - 0.300 * cs + 1.250 * sn, 0.587 - 0.588 * cs - 1.050 * sn, 0.114 + 0.886 * cs - 0.203 * sn));
    return float3(dot(m[0], c), dot(m[1], c), dot(m[2], c));
}

inline float4 shaded(constant LayerU& u, texture2d<float> tex, float2 lp, float2 size, float2 fragPos) {
    float2 p = lp;
    float gl = u.fx1.x;
    if (u.fx0.z > 0.5) p = (floor(p / u.fx0.z) + 0.5) * u.fx0.z;
    if (gl > 0.0) {
        float band = floor(p.y / max(4.0, size.y * 0.03));
        float slot = floor(u.pad.w * 15.0);
        float h = hash21(float2(band, slot));
        if (h < gl * 0.5) p.x += (hash21(float2(band + 3.0, slot)) - 0.5) * size.x * 0.12 * gl;
    }
    float4 c;
    if (u.fx0.y > 0.5) {
        float r = u.fx0.y;
        c = float4(0.0);
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) c += fetch(u, tex, p + float2(i, j) * r, size, fragPos);
        c *= (1.0 / 9.0);
    } else if (u.fx0.x > 0.01 || gl > 0.05) {
        float2 o = float2(max(u.fx0.x, gl * 6.0), 0.0);
        float4 a = fetch(u, tex, p + o, size, fragPos), g = fetch(u, tex, p, size, fragPos), b = fetch(u, tex, p - o, size, fragPos);
        c = float4(a.r, g.g, b.b, max(max(a.a, g.a), b.a));
    } else c = fetch(u, tex, p, size, fragPos);
    if (u.fx0.w > 0.0) c.rgb *= 1.0 - u.fx0.w * 0.4 * (0.5 + 0.5 * sin(lp.y * 3.14159265));
    return c;
}

fragment float4 fsLayer(LOut in [[stage_in]], constant LayerU& u [[buffer(0)]],
                        texture2d<float> tex [[texture(0)]], texture2d<float> maskT [[texture(1)]], texture2d<float> back [[texture(2)]]) {
    float2 size = u.box.zw;
    float2 lp = in.lp;
    float2 uvn = lp / size;
    int mode = int(u.shd.x + 0.5);
    float opacity = u.anim.x;
    float wipeCov = 1.0;
    if (u.anim.y < 0.999) {
        float ext = abs(u.anim.z) * size.x + abs(u.anim.w) * size.y;
        float tt = 0.5 + dot((uvn - 0.5) * size, u.anim.zw) / max(ext, 1.0);
        wipeCov = clamp((u.anim.y - tt) * ext * 0.1 + 0.5, 0.0, 1.0);
    }
    if (mode != 0) {                                   // shadow (1) / glow (2): soft silhouette of the layer
        float R = max(u.shd.y, 1.0);
        int kind = int(u.content.x + 0.5);
        float a;
        if (kind == 1 || kind == 5 || kind == 9) {
            float sum = 0.0;
            float jitter = hash21(in.pos.xy) * 6.2831853;       // per-pixel rotation turns tap banding into fine noise
            for (int i = 0; i < 20; i++) {
                float r = sqrt((float(i) + 0.5) / 20.0) * R;
                float ang = float(i) * 2.39996323 + jitter;
                sum += tex.sample(zeroSamp, (lp + r * float2(cos(ang), sin(ang))) / size).a;
            }
            a = sum / 20.0;
            if (mode == 2) a = clamp(a * 1.7, 0.0, 1.0);
        } else {
            float d = layerSDF(u, lp, size);
            a = mode == 1 ? 1.0 - smoothstep(-R, R, d) : pow(1.0 - clamp(d / R, 0.0, 1.0), 2.0) * (d < 0.0 ? 0.0 : 1.0);
        }
        a = a * u.shdc.a * opacity * wipeCov * (mode == 2 ? u.shd.z : 1.0);
        a = clamp(a, 0.0, 1.0);
        return float4(u.shdc.rgb * a, a);
    }
    float cov = layerCov(u, lp, size, maskT);
    float4 c = shaded(u, tex, lp, size, in.pos.xy);
    int kind = int(u.content.x + 0.5);
    if (u.key0.w > 0.5 && (kind == 0 || kind == 6)) {
        float3 e = c.a > 0.0 ? c.rgb / c.a : float3(0.0), k = u.key0.rgb;
        float2 ce = float2(dot(e, float3(-0.1687, -0.3313, 0.5)), dot(e, float3(0.5, -0.4187, -0.0813)));
        float2 ck = float2(dot(k, float3(-0.1687, -0.3313, 0.5)), dot(k, float3(0.5, -0.4187, -0.0813)));
        float dist = length(ce - ck);
        float sim = u.key1.x * 0.5, sm = max(u.key1.y * 0.5, 0.001);
        float a = smoothstep(sim, sim + sm, dist);
        float spill = u.key1.z * (1.0 - smoothstep(sim, sim + sm + 0.12, dist));
        e = mix(e, float3(dot(e, float3(0.2126, 0.7152, 0.0722))), clamp(spill, 0.0, 1.0));
        c = float4(e * a, a);
    }
    if (u.adj0.x != 0.0 || u.adj0.y != 0.0 || u.adj0.z != 0.0 || u.adj0.w != 0.0 || u.adj1.w > 0.0) {
        float3 e = c.a > 0.0 ? c.rgb / c.a : float3(0.0);
        e += u.adj0.x;
        e = (e - 0.5) * (1.0 + u.adj0.y) + 0.5;
        float y = dot(e, float3(0.2126, 0.7152, 0.0722));
        e = float3(y) + (e - float3(y)) * (1.0 + u.adj0.z);
        if (u.adj0.w != 0.0) e = hueRotate(e, u.adj0.w);
        e = mix(e, e * u.adj1.rgb, u.adj1.w);
        c.rgb = clamp(e, 0.0, 1.0) * c.a;
    }
    float bw = u.border.x;
    if (bw > 0.0) {
        float d = layerSDF(u, lp, size);
        float ring = clamp(d + bw + 0.5, 0.0, 1.0);
        float4 bc = u.bc0;
        if (u.border.y > 0.5) {
            float ext = abs(u.border.z) * size.x + abs(u.border.w) * size.y;
            bc = mix(u.bc0, u.bc1, clamp(0.5 + dot((uvn - 0.5) * size, u.border.zw) / max(ext, 1.0), 0.0, 1.0));
        }
        float ba = bc.a * ring;
        c = c * (1.0 - ba) + float4(bc.rgb * ba, ba);
    }
    if (u.ext3.y > 0.5 || u.ext3.z > 0.0) c = advShine(u, c, uvn, size);
    c *= cov * opacity * wipeCov;
    if (u.shd.w > 0.5) {                              // overlay blend against the backdrop copy
        float4 b = back.sample(nearSamp, in.pos.xy / u.pad.yz);
        float3 s = c.a > 0.0 ? c.rgb / c.a : float3(0.0);
        float3 bb = b.a > 0.0 ? b.rgb / b.a : float3(0.0);
        float3 ov = select(1.0 - 2.0 * (1.0 - bb) * (1.0 - s), 2.0 * bb * s, bb < 0.5);
        return float4(b.rgb * (1.0 - c.a) + ov * c.a * b.a + s * c.a * (1.0 - b.a), b.a + c.a * (1.0 - b.a));
    }
    return c;
}

// ---- particles (stateless, deterministic: every particle is a pure function of seed, index and time) ------------
inline uint pcg(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
inline float rnd(uint seed, uint i, uint k) { return float(pcg(seed * 9781u + i * 6271u + k * 1013u + 17u)) * (1.0 / 4294967296.0); }
struct POut { float4 pos [[position]]; float2 q; float4 col; float shape; };

vertex POut vsParticle(uint vid [[vertex_id]], uint iid [[instance_id]], constant LayerU& u [[buffer(0)]]) {
    int ek = int(u.eff0.x + 0.5);          // 0 fire, 1 embers, 2 smoke, 3 sparks
    float inten = u.eff0.y, speed = u.eff0.z, psize = u.eff0.w;
    uint seed = uint(u.eff1.x);
    float time = u.pad.w;
    float2 bxy = u.box.xy, bsz = u.box.zw;
    float w = bsz.x, h = bsz.y;
    float h1 = rnd(seed, iid, 1u), h2 = rnd(seed, iid, 2u), h3 = rnd(seed, iid, 3u), h4 = rnd(seed, iid, 4u), h5 = rnd(seed, iid, 5u);
    float life, age, size, alpha;
    float2 pos, vdir = float2(0.0, -1.0);
    float3 col;
    float stretch = 1.0;
    float shapeK = 0.0, flipK = 1.0;
    float4 A = u.c0, B = u.c1;
    if (ek == 0) {                                          // fire: soft body particles + small hot cores
        bool body = (iid & 1u) == 0u;
        life = 1.0 + 0.9 * h1;
        age = fract(time * speed / life + h2);
        float sx = h3 + h4 - 1.0;
        float x0 = w * 0.5 + sx * w * 0.5 * (1.0 - 0.6 * age);
        float rise = age * h * (0.75 + 0.4 * h5);
        float wob = sin(age * 7.0 + h1 * 40.0 + time * speed * 3.0) * w * 0.03 * age + sin(age * 17.0 + h2 * 30.0 - time * speed * 5.0) * w * 0.012 * age;
        size = psize * (body ? 3.0 : 1.1) * (0.55 + h5) * (1.0 - age * 0.72);
        pos = bxy + float2(x0 + wob, h - rise - size * 0.15);
        float3 core = float3(1.0, 0.92, 0.55);
        col = mix(mix(core, A.rgb, smoothstep(0.0, 0.35, age)), B.rgb, smoothstep(0.3, 0.8, age));
        alpha = pow(1.0 - age, 1.3) * smoothstep(0.0, 0.05, age) * (body ? 0.26 : 0.55) * inten;
    } else if (ek == 1) {                                   // embers
        life = 2.5 + 3.0 * h1;
        age = fract(time * speed / life + h2);
        float x0 = w * h3 + sin(time * speed * 1.3 + h4 * 40.0) * 24.0 * age;
        float rise = age * h * (0.5 + 0.9 * h5);
        size = psize * 0.1 * (0.6 + h5) * (1.0 - age * 0.4);
        pos = bxy + float2(x0, h - rise);
        float flick = 0.55 + 0.45 * sin(time * speed * (7.0 + 6.0 * h2) + h1 * 30.0);
        col = mix(A.rgb, B.rgb, age);
        alpha = flick * smoothstep(0.0, 0.08, age) * (1.0 - age) * inten;
    } else if (ek == 2) {                                   // smoke
        life = 3.0 + 3.0 * h1;
        age = fract(time * speed / life + h2);
        float x0 = w * (0.3 + 0.4 * h3) + (h4 - 0.5) * w * 0.5 * age;
        size = psize * (1.6 + age * 3.2) * (0.7 + 0.6 * h5);
        pos = bxy + float2(x0, h - age * h * (0.9 + 0.3 * h5));
        col = mix(A.rgb, B.rgb, age);
        alpha = 0.22 * smoothstep(0.0, 0.18, age) * (1.0 - age) * inten;
    } else if (ek >= 4) {
        float lt = u.ext0.x;
        float2 ctr = bxy + bsz * 0.5;
        float R = min(w, h) * 0.5;
        if (ek == 4) {                                      // burst (one-shot): radial sparks with drag + gravity
            life = 0.9 + 1.4 * h1;
            float tt = lt * speed - h2 * 0.08;
            age = tt / life;
            float ang = h3 * 6.2831853;
            float v0 = (0.25 + 0.75 * sqrt(h4)) * R * 3.2;
            float k = 2.6;
            float dist = v0 * (1.0 - exp(-k * max(tt, 0.0))) / k;
            float g = R * 0.35;
            float2 dir = float2(cos(ang), sin(ang));
            pos = ctr + dir * dist + float2(0.0, 0.5 * g * tt * tt);
            float2 vel = dir * v0 * exp(-k * max(tt, 0.0)) + float2(0.0, g * tt);
            vdir = normalize(vel + float2(1e-4));
            stretch = clamp(length(vel) * 0.02, 1.0, 7.0);
            bool big = (iid % 5u) == 0u;
            size = psize * (big ? 1.6 : 0.45) * (0.5 + h5);
            col = mix(float3(1.0, 0.97, 0.85), A.rgb, smoothstep(0.0, 0.45, age));
            col = mix(col, B.rgb, smoothstep(0.55, 1.0, age));
            alpha = (tt < 0.0 || age > 1.0) ? 0.0 : pow(1.0 - age, 1.4) * inten * (big ? 0.55 : 1.0);
            if (big) stretch = 1.0;
        } else if (ek == 5) {                               // converge (one-shot): stream from a ring into the centre
            float st = h1 * 0.55;
            float dur = 0.8 + 0.5 * h2;
            float p = clamp((lt * speed - st) / dur, 0.0, 1.0);
            float e = p * p * (3.0 - 2.0 * p);
            e = e * e;
            float ang = h3 * 6.2831853 + (1.0 - e) * 1.1;
            float rad = R * (1.1 + 1.4 * h4) * (1.0 - e);
            pos = ctr + float2(cos(ang), sin(ang)) * rad * float2(1.0, 0.75);
            vdir = normalize(-float2(cos(ang), sin(ang)) + float2(1e-4));
            stretch = 1.0 + 6.0 * (1.0 - abs(2.0 * p - 1.0));
            size = psize * 0.5 * (0.5 + h5);
            col = mix(A.rgb, float3(1.0, 0.97, 0.88), e);
            alpha = (lt * speed < st) ? 0.0 : smoothstep(0.0, 0.12, p) * (1.0 - smoothstep(0.86, 1.0, p)) * inten;
            age = p;
        } else if (ek == 6) {                               // confetti: falling, tumbling paper
            life = 3.5 + 3.0 * h1;
            float tr = lt * speed / life - h2;
            age = fract(tr);
            float sway = sin(lt * speed * (1.2 + h4) + h1 * 30.0) * w * 0.025;
            pos = bxy + float2(w * h3 + sway + (h5 - 0.5) * w * 0.15 * age, -psize * 2.0 + age * (h + psize * 4.0));
            float spin = lt * speed * (2.0 + 4.0 * h5) + h1 * 20.0;
            float flip = cos(lt * speed * (3.0 + 5.0 * h4) + h2 * 9.0);
            float th = h3 * 6.2831853 + spin * 0.35;
            vdir = float2(cos(th), sin(th));
            stretch = 1.0;
            size = psize * (0.6 + 0.6 * h4);
            float pick = rnd(seed, iid, 6u);
            float3 base = pick < 0.55 ? A.rgb : (pick < 0.8 ? float3(1.0) : B.rgb);
            col = base * (0.55 + 0.45 * abs(flip));
            alpha = (tr < 0.0 ? 0.0 : 1.0) * inten * (1.0 - smoothstep(0.92, 1.0, age));
            shapeK = 1.0; flipK = max(abs(flip), 0.15);
        } else if (ek == 7) {                               // bokeh: slow soft discs
            float tt = lt * speed;
            pos = bxy + float2(fract(h3 + sin(tt * 0.05 + h1 * 6.0) * 0.03) * w, fract(h4 - tt * 0.01 * (0.4 + h5)) * h);
            size = psize * (0.25 + 0.75 * h5 * h5);
            col = mix(A.rgb, B.rgb, h1);
            alpha = (0.05 + 0.16 * h2) * (0.7 + 0.3 * sin(tt * (0.6 + h1) + h2 * 9.0)) * inten;
            age = 0.0; shapeK = 3.0;
        } else if (ek == 8) {                               // glints: twinkling 4-point stars
            float tt = lt * speed;
            float ph = fract(tt * (0.18 + 0.3 * h1) + h2);
            float env = pow(sin(ph * 3.14159265), 10.0);
            pos = bxy + float2(w * h3, h * h4);
            size = psize * (0.4 + 0.8 * h5) * (0.3 + 0.7 * env);
            col = mix(float3(1.0, 0.98, 0.9), A.rgb, 0.35 * h1);
            alpha = env * inten;
            age = 0.0; shapeK = 2.0;
        } else {                                            // fire embers: fast hot rising sparks
            life = 1.2 + 1.8 * h1;
            float tt = lt * speed;
            age = fract(tt / life + h2);
            float turb = sin(age * 9.0 + h4 * 40.0 + tt * 2.0) * w * 0.02 + sin(age * 23.0 + h1 * 13.0) * w * 0.006;
            pos = bxy + float2(w * h3 + turb + (h5 - 0.5) * w * 0.2 * age, h - age * h * (0.6 + 0.7 * h5));
            float2 vel = float2(cos(age * 9.0 + h4 * 40.0) * 0.3, -1.0);
            vdir = normalize(vel);
            stretch = 1.8 + 1.5 * h4;
            size = psize * 0.12 * (0.5 + h5) * (1.0 - age * 0.5);
            float flick = 0.6 + 0.4 * sin(tt * (9.0 + 7.0 * h2) + h1 * 30.0);
            col = mix(float3(1.0, 0.92, 0.6), A.rgb, smoothstep(0.0, 0.4, age));
            col = mix(col, B.rgb, smoothstep(0.5, 1.0, age));
            alpha = flick * smoothstep(0.0, 0.06, age) * pow(1.0 - age, 1.2) * inten;
        }
    } else {                                                // sparks
        life = 0.55 + 0.9 * h1;
        age = fract(time * speed / life + h2);
        float ang = -1.5707963 + (h3 - 0.5) * 2.4;
        float v0 = (0.55 + 0.9 * h4) * h * 1.3;
        float g = h * 2.2;
        float tt = age * life * 1.0;
        float2 v = float2(cos(ang), sin(ang)) * v0;
        pos = bxy + float2(w * 0.5, h) + v * tt + float2(0.0, 0.5 * g * tt * tt);
        float2 vel = v + float2(0.0, g * tt);
        vdir = normalize(vel + float2(1e-4));
        stretch = clamp(length(vel) * 0.045, 1.0, 9.0);
        size = psize * 0.12 * (0.6 + h5);
        col = mix(float3(1.0, 0.95, 0.7), A.rgb, age);
        alpha = pow(1.0 - age, 1.3) * inten;
    }
    float2 c = float2(vid & 1, vid >> 1);
    float2 q = c * 2.0 - 1.0;
    float2 side = float2(-vdir.y, vdir.x);
    bool oriented = ek == 3 || ek == 4 || ek == 5 || ek == 6 || ek == 9;
    float2 off = oriented ? (vdir * q.x * size * stretch + side * q.y * size * (ek == 6 ? 0.55 * flipK : 1.0)) : q * size;
    if (ek == 8) off *= 3.0;                                 // glint arms reach past the core
    float2 px = pos + off;
    POut o;
    o.pos = float4(px.x / u.pad.y * 2.0 - 1.0, 1.0 - px.y / u.pad.z * 2.0, 0.0, 1.0);
    o.q = q;
    o.col = float4(col * alpha * u.anim.x, alpha * u.anim.x);
    o.shape = shapeK;
    return o;
}
fragment float4 fsParticle(POut in [[stage_in]]) {
    float r = length(in.q);
    int k = int(in.shape + 0.5);
    float a;
    if (k == 1) {                                            // confetti: hard-edged paper
        float m = max(abs(in.q.x), abs(in.q.y));
        a = 1.0 - smoothstep(0.82, 1.0, m);
    } else if (k == 2) {                                     // glint: 4-point star + soft core
        float2 q = abs(in.q) * 3.0;
        a = exp(-q.x * 14.0) * exp(-q.y * 1.3) + exp(-q.y * 14.0) * exp(-q.x * 1.3) + exp(-dot(q, q) * 6.0) * 0.8;
        a = min(a, 1.0) * (1.0 - smoothstep(0.85, 1.0, r));
    } else if (k == 3) {                                     // bokeh disc with a faint bright rim
        a = (1.0 - smoothstep(0.86, 1.0, r)) * (0.65 + 0.35 * smoothstep(0.55, 0.95, r));
    } else {
        a = pow(max(1.0 - r, 0.0), 2.0);
    }
    return in.col * a;
}

// ---- scene transitions ------------------------------------------------------------------------------------------
struct TransU { float4 p; float4 d; };   // p: kind, progress, dirX, dirY ; d: aspect
fragment float4 fsTransition(VOut in [[stage_in]], texture2d<float> A [[texture(0)]], texture2d<float> B [[texture(1)]], constant TransU& u [[buffer(0)]]) {
    int kind = int(u.p.x + 0.5);
    float p = u.p.y;
    float2 m = u.p.zw;
    float2 uv = in.uv;
    if (kind == 2) {                                   // slide: both scenes travel together along m
        float2 ua = uv - m * p, ub = uv - m * (p - 1.0);
        bool inB = all(ub >= 0.0) && all(ub <= 1.0);
        bool inA = all(ua >= 0.0) && all(ua <= 1.0);
        if (inB) return B.sample(linSamp, ub);
        if (inA) return A.sample(linSamp, ua);
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    if (kind == 3) {                                   // zoom
        float2 c = uv - 0.5;
        float4 a = A.sample(linSamp, c / (1.0 + 0.3 * p) + 0.5);
        float4 b = B.sample(linSamp, c / (1.15 - 0.15 * p) + 0.5);
        return mix(a, b, smoothstep(0.1, 0.9, p));
    }
    if (kind == 5) {                                   // gold light wipe: a glowing gold band carries the new scene in
        float2 asp = float2(16.0 / 9.0, 1.0);
        float2 dir = normalize(m * asp);
        float ext = abs(dir.x) * asp.x + abs(dir.y) * asp.y;
        float tt = 0.5 + dot((uv - 0.5) * asp, dir) / max(ext, 0.001);
        float e = p * 1.5 - 0.25;
        float dd = tt - e;
        float4 a = A.sample(linSamp, uv), b = B.sample(linSamp, uv);
        float4 c = dd < 0.0 ? b : a;
        float core = exp(-pow(dd / 0.012, 2.0)), band = exp(-pow(dd / 0.07, 2.0)), glow = exp(-abs(dd) / 0.18) * 0.35;
        float3 gold = float3(0.95, 0.74, 0.30), hot = float3(1.0, 0.95, 0.80);
        c.rgb = c.rgb * (1.0 - band * 0.85) + gold * (band * 0.9 + glow) + hot * core;
        return float4(c.rgb, 1.0);
    }
    if (kind == 4) {                                   // wipe: soft edge travelling along m
        float tt = 0.5 + dot(uv - 0.5, m) / max(abs(m.x) + abs(m.y), 0.001);
        float e = clamp((p * 1.12 - 0.06 - tt) * 18.0 + 0.5, 0.0, 1.0);
        return mix(A.sample(nearSamp, uv), B.sample(nearSamp, uv), e);
    }
    return mix(A.sample(nearSamp, uv), B.sample(nearSamp, uv), p);
}
"""#
