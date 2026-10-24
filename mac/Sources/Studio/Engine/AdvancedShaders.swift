// Metal source for the "OPUS" advanced effects (AdvancedFX). Spliced into layerShaderSource right after the LayerU struct and
// helpers, so it can use LayerU, hash21, premul, zeroSamp. Every effect is a pure function of (uniforms, local time): deterministic.
//
// LayerU extension fields used here:
//   ext0: x = local effect time (seconds since the effect fired / since show for continuous effects), y = active flag
//   ext1: shine intensity, band half-width (0...1 of extent), dirCos, dirSin
//   ext2: shine colour (encoded straight)
//   ext3: shine phase 0...1, shine active, shimmer amount, 0
let advancedShaderSource = #"""

// ---- noise helpers ---------------------------------------------------------------------------------------------
inline float advHash11(float x) { return fract(sin(x * 127.1) * 43758.5453); }
inline float advNoise1(float x) { float i = floor(x), f = fract(x); float u = f * f * (3.0 - 2.0 * f); return mix(advHash11(i), advHash11(i + 1.0), u); }
inline float advNoise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1.0, 0.0)), c = hash21(i + float2(0.0, 1.0)), d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
inline float advFbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * advNoise2(p); p = float2(p.x * 1.6 - p.y * 1.2, p.x * 1.2 + p.y * 1.6) + 17.3; a *= 0.5; }
    return v;
}
inline float advEaseOut(float x) { float u = 1.0 - clamp(x, 0.0, 1.0); return 1.0 - u * u * u; }
inline float advEaseInOut(float x) { x = clamp(x, 0.0, 1.0); return x < 0.5 ? 4.0 * x * x * x : 1.0 - pow(-2.0 * x + 2.0, 3.0) * 0.5; }
inline float4 advOut(float3 col, float a) { a = clamp(a, 0.0, 1.0); return float4(col * a, a); }

// ---- fragment effects (ek 30...37) -----------------------------------------------------------------------------
inline float4 advEffect(constant LayerU& u, float2 lp, float2 size, float2 fragPos) {
    int ek = int(u.eff0.x + 0.5);
    float inten = u.eff0.y, speed = u.eff0.z, sz = max(u.eff0.w, 1.0);
    float th = max(u.eff1.y, 0.5);
    float t = u.pad.w * speed;
    float lt = u.ext0.x;                      // local (one-shot) time
    float4 A = u.c0, B = u.c1;
    float2 uvn = lp / size;
    float2 ctr = size * 0.5;
    float2 d = lp - ctr;
    float r = length(d);
    // soft box edges for localized effects (the effect never shows its rectangle)
    float2 e2 = min(uvn, 1.0 - uvn);
    float feather = smoothstep(0.0, 0.12, e2.x) * smoothstep(0.0, 0.12, e2.y);

    if (ek == 30) {                                   // lens flare
        float fl = 0.92 + 0.08 * sin(t * 13.0) * sin(t * 7.3 + 1.0);
        float core = exp(-r * r / (sz * sz)) + 0.35 * exp(-r / (sz * 2.2));
        float streak = exp(-pow(d.y / th, 2.0)) * exp(-abs(d.x) / (size.x * 0.28));
        float streak2 = 0.5 * exp(-pow(d.y / (th * 4.0), 2.0)) * exp(-abs(d.x) / (size.x * 0.12));
        float ang = atan2(d.y, d.x);
        float spikes = pow(abs(cos(ang * 3.0 + 0.4)), 60.0) * exp(-r / (sz * 3.5)) * 0.55;
        float ring = exp(-pow((r - sz * 3.4) / (sz * 0.22), 2.0)) * 0.10;
        // ghosts towards the canvas centre (box-local)
        float2 cc = u.pad.yz * 0.5 - u.box.xy;
        float2 axis = cc - ctr;
        float ghosts = 0.0;
        for (int i = 0; i < 4; i++) {
            float k = 0.55 + float(i) * 0.42;
            float gr = sz * (0.5 + 0.35 * float(i % 3));
            float gd = length(lp - (ctr + axis * k * 1.6));
            ghosts += (0.10 - 0.015 * float(i)) * smoothstep(gr, gr * 0.6, gd);
        }
        float3 col = float3(1.0) * core + mix(A.rgb, float3(1.0), 0.4) * streak + A.rgb * (streak2 + spikes) + B.rgb * (ring + ghosts);
        col *= inten * fl * feather;
        float a = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
        return float4(col, a);
    }
    if (ek == 31) {                                   // god rays from the top centre (angle tilts the fan)
        float2 o = float2(size.x * 0.5, -size.y * 0.08);
        float2 q = lp - o;
        float rr = length(q);
        float ang = atan2(q.x, q.y) - u.eff1.z;
        float dens = max(u.eff1.w, 4.0) * 0.25;
        float n = advNoise1(ang * dens + t * 0.12) * 0.6 + advNoise1(ang * dens * 2.3 - t * 0.09 + 5.0) * 0.4;
        float rays = pow(n, 3.0) * 1.6;
        float cone = exp(-pow(ang / 0.85, 2.0));
        float fall = exp(-rr / (size.y * 0.75)) * smoothstep(0.0, size.y * 0.12, rr);
        float edgeG = smoothstep(0.0, 0.22, e2.x) * smoothstep(0.0, 0.25, 1.0 - uvn.y);
        float a = rays * cone * fall * inten * A.a * edgeG;
        float3 col = mix(A.rgb, B.rgb, clamp(rr / size.y, 0.0, 1.0));
        return advOut(col, a * 0.8);
    }
    if (ek == 32) {                                   // shockwave ring (one-shot)
        float x = lt * speed;
        if (x > 1.6 || x < 0.0) return float4(0.0);
        float maxR = length(size) * 0.5;
        float R = maxR * advEaseOut(x / 1.3);
        float fade = 1.0 - clamp(x / 1.6, 0.0, 1.0);
        float w = sz * (0.6 + 1.2 * x);
        float ring = exp(-pow((r - R) / w, 2.0));
        float edge = exp(-pow((r - R - w * 0.4) / max(th, 1.0), 2.0));
        float flash = exp(-r / (maxR * 0.18)) * pow(max(0.0, 1.0 - x * 2.5), 2.0);
        float3 col = A.rgb * ring * 0.9 + float3(1.0) * edge * 0.8 + mix(float3(1.0), A.rgb, 0.3) * flash * 1.2 + B.rgb * ring * 0.3;
        col *= inten * fade * feather;
        return float4(col, clamp(max(max(col.r, col.g), col.b), 0.0, 1.0));
    }
    if (ek == 33) {                                   // diagonal energy streaks
        float ca = cos(u.eff1.z), sa = sin(u.eff1.z);
        float2 p = float2(dot(lp, float2(ca, sa)), dot(lp, float2(-sa, ca)));
        float diag = abs(ca) * size.x + abs(sa) * size.y + abs(sa) * size.x + abs(ca) * size.y;
        float n = max(u.eff1.w, 1.0);
        float spacing = diag / n;
        float lane = floor(p.y / spacing);
        float h1 = hash21(float2(lane, u.eff1.x)), h2 = hash21(float2(lane + 17.0, u.eff1.x)), h3 = hash21(float2(lane + 41.0, u.eff1.x));
        if (h1 < 0.35) return float4(0.0);
        float ly = (lane + 0.25 + 0.5 * h2) * spacing;
        float dy = p.y - ly;
        float len = diag * (0.10 + 0.22 * h3);
        float span = diag + len * 2.0;
        float head = fract(t * (0.10 + 0.18 * h2) + h3) * span - len - diag * 0.25;
        float along = head - p.x;
        if (along < 0.0 || along > len) return float4(0.0);
        float tail = pow(1.0 - along / len, 1.6);
        float w = th * (0.6 + 0.8 * h1);
        float core = exp(-pow(dy / w, 2.0)), glow = exp(-abs(dy) / (w * 5.0)) * 0.45;
        float3 base = h2 > 0.62 ? B.rgb : A.rgb;
        float3 col = mix(base, float3(1.0), core * 0.55 * smoothstep(0.7, 1.0, tail));
        return advOut(col, (core + glow) * tail * inten);
    }
    if (ek == 34) {                                   // gold smoke (domain-warped fbm)
        float2 p = lp / sz;
        float2 drift = float2(t * 0.05, -t * 0.03);
        float2 q = float2(advNoise2(p * 0.8 + drift), advNoise2(p * 0.8 + float2(5.2, 1.3) - drift));     // cheap warp
        float f = advFbm(p + q * 1.7 + float2(t * 0.02, 0.0));
        float dens = smoothstep(0.42, 0.85, f);
        float3 col = mix(B.rgb, A.rgb, smoothstep(0.5, 0.9, f));
        return advOut(col, dens * inten * A.a);
    }
    if (ek == 35) {                                   // gold light wipe band (one-shot)
        float x = lt * speed;
        if (x < 0.0 || x > 1.15) return float4(0.0);
        float2 dir = float2(cos(u.eff1.z), sin(u.eff1.z));
        float ext = abs(dir.x) * size.x + abs(dir.y) * size.y;
        float tt = dot(d, dir);                                  // px along the travel direction
        float c = mix(-0.5 * ext - sz * 2.0, 0.5 * ext + sz * 2.0, advEaseInOut(x));
        float dd = tt - c;
        float core = exp(-pow(dd / (sz * 0.12), 2.0));
        float band = exp(-pow(dd / sz, 2.0));
        float glow = exp(-abs(dd) / (sz * 2.2)) * 0.5;
        float spark = step(0.994, hash21(floor(lp / 3.0) + floor(x * 30.0))) * band * band;
        float3 col = float3(1.0) * core + A.rgb * band + B.rgb * glow + float3(1.0, 0.95, 0.8) * spark;
        float a = clamp(core + band * 0.95 + glow * 0.6, 0.0, 1.0) * inten;
        return float4(col * inten, a);
    }
    if (ek == 36) {                                   // luxury HUD dial
        float R = min(size.x, size.y) * 0.5;
        float rn = r / R;
        if (rn > 1.02) return float4(0.0);
        float ang = atan2(d.x, -d.y);                              // 0 at 12 o'clock, clockwise
        float a01 = fract(ang / 6.2831853 + 1.0);
        float px = 1.0 / R;
        float3 col = float3(0.0); float a = 0.0;
        // outer hairline ring
        float o1 = 1.0 - smoothstep(0.0, 1.5 * px, abs(rn - 0.985));
        col += A.rgb * o1 * 0.8; a = max(a, o1 * 0.8);
        // tick ring with a running highlight
        float tk = fract(a01 * 120.0);
        bool big = fract(a01 * 24.0) < (1.0 / 5.0) && tk < 0.4;
        float inner = big ? 0.86 : 0.895;
        float tickOn = (1.0 - smoothstep(0.30, 0.42, abs(tk - 0.2) * 2.0)) * step(inner, rn) * step(rn, 0.945);
        float run = pow(fract(a01 - t * 0.18), 5.0);
        float tb = 0.28 + 0.72 * run;
        col += mix(A.rgb, float3(1.0), run * 0.5) * tickOn * tb; a = max(a, tickOn * tb);
        // three rotating segment arcs
        float seg = 0.0;
        for (int i = 0; i < 3; i++) {
            float s0 = fract(a01 - t * 0.06 - float(i) / 3.0);
            seg = max(seg, step(s0, 0.16));
        }
        float band = (1.0 - smoothstep(0.0, 1.5 * px, abs(rn - 0.80) - 0.012));
        col += A.rgb * band * seg * 0.95; a = max(a, band * seg * 0.95);
        float faint = (1.0 - smoothstep(0.0, 1.5 * px, abs(rn - 0.80) - 0.002)) * 0.25;
        col += A.rgb * faint; a = max(a, faint);
        // counter-rotating red accents
        float s1 = fract(a01 + t * 0.09);
        float red = step(s1, 0.04) + step(abs(s1 - 0.5), 0.02);
        float rb = (1.0 - smoothstep(0.0, 1.5 * px, abs(rn - 0.735) - 0.006)) * min(red, 1.0);
        col += B.rgb * rb; a = max(a, rb);
        // progress arc (intensity = filled fraction) with a hot head
        float prog = clamp(u.eff1.w > 0.0 ? u.eff1.w / 100.0 : 0.0, 0.0, 1.0);
        float pb = (1.0 - smoothstep(0.0, 1.5 * px, abs(rn - 0.955) - 0.006)) * step(a01, prog);
        col += mix(A.rgb, float3(1.0), 0.25) * pb; a = max(a, pb);
        col *= inten; a *= inten;
        return float4(col, clamp(a, 0.0, 1.0));
    }
    if (ek == 37) {                                   // hex tech grid with travelling highlight
        float2 p = lp / sz;
        float2 rr = float2(1.0, 1.7320508);
        float2 h = rr * 0.5;
        float2 a1 = fmod(p, rr) - h, b1 = fmod(p - h, rr) - h;
        a1 = select(a1, a1 + rr, a1 < -h); b1 = select(b1, b1 + rr, b1 < -h);
        float2 g = dot(a1, a1) < dot(b1, b1) ? a1 : b1;
        float2 ag = abs(g);
        float hexD = max(dot(ag, normalize(float2(1.0, 1.7320508))), ag.x);
        float edge = 1.0 - smoothstep(0.0, th / sz, 0.5 - hexD);
        float hl = exp(-pow((uvn.x * 0.8 + uvn.y * 0.45 - (fract(t * 0.07) * 2.6 - 0.6)) / 0.16, 2.0));
        float a = edge * (0.08 + 0.55 * hl) * inten * A.a;
        return advOut(mix(A.rgb, float3(1.0), hl * 0.3), a);
    }
    return float4(0.0);
}

// ---- shine: specular band + metallic shimmer over a layer's own pixels (premultiplied in, premultiplied out) -----
inline float4 advShine(constant LayerU& u, float4 c, float2 uvn, float2 size) {
    if (c.a <= 0.0) return c;
    float2 dir = u.ext1.zw;
    float ext = abs(dir.x) * size.x + abs(dir.y) * size.y;
    float tt = 0.5 + dot((uvn - 0.5) * size, dir) / max(ext, 1.0);
    float3 add = float3(0.0);
    if (u.ext3.y > 0.5) {
        float ctr = mix(-0.35, 1.35, u.ext3.x);
        float w = max(u.ext1.y, 0.01);
        float dd = (tt - ctr) / w;
        float band = exp(-dd * dd) + 0.25 * exp(-dd * dd / 9.0);
        add += u.ext2.rgb * band * u.ext1.x;
    }
    if (u.ext3.z > 0.0) {
        float s = sin(tt * 11.0 - u.pad.w * 1.3) * 0.5 + 0.5;
        float s2 = sin(tt * 27.0 + uvn.y * 6.0 + u.pad.w * 0.7) * 0.5 + 0.5;
        float k = pow(s, 6.0) * 0.6 + pow(s2, 10.0) * 0.25;
        add += float3(1.0, 0.95, 0.8) * k * u.ext3.z;
    }
    c.rgb = min(c.rgb + add * c.a, float3(c.a));
    return c;
}
"""#
