// "OPUS" advanced GPU effects: model types + CPU-side timing helpers. Shaders live in AdvancedShaders.swift.
// Everything is a pure function of (seed, local time), so stills, recordings and tests are deterministic.
import Foundation

/// Advanced procedural effects for `.effect` layers (EffectSpec.advanced). The layer box is the effect area.
/// Colours: `color` = core / highlight, `color2` = outer / secondary. Common fields: intensity, speed, size, thickness, angle, count, seed.
/// One-shot effects start `delay` seconds after the scene is shown (or re-taken) and re-fire every `period` s when period > 0.
enum AdvancedFX: String, Codable, CaseIterable, Sendable {
    /// Anamorphic lens flare centred in the box: hot core, horizontal streak, ghosts towards the canvas centre. `size` = core radius px.
    case lensFlare
    /// Volumetric light rays (god rays) fanning out of the box's top centre (or `angle`), slowly rotating. `count` ~ ray density.
    case godRays
    /// One-shot expanding shockwave ring from the box centre. `size` = ring thickness px; `speed` = expansion rate; lasts ~1.2 s / speed.
    case shockwave
    /// One-shot radial burst of glowing sparks from the box centre with gravity + drag. `count` particles, `size` = spark size.
    case burst
    /// Particles streaming from the box edges into its centre (logo "assembling"), one-shot over ~1.6 s / speed.
    case converge
    /// Diagonal glowing energy streaks moving along `angle`. `count` = streaks, `thickness` px.
    case energyStreaks
    /// Slow noise-based gold smoke / haze (fbm). `size` = feature scale px.
    case goldSmoke
    /// Falling, tumbling confetti (gold / white / `color2`). `count` pieces, `size` = piece size.
    case confetti
    /// One-shot bright gold light band sweeping across the box along `angle` (stinger / reveal wipe). `size` = band width px.
    case lightWipe
    /// Soft out-of-focus gold bokeh discs drifting slowly. `count`, `size` = max disc radius.
    case bokeh
    /// Twinkling 4-point star glints scattered over the box. `count`, `size` = glint length.
    case glints
    /// Luxury HUD dial: tick ring, rotating segment arcs and a progress arc (`intensity`), centred in the box.
    case hudDial
    /// Fine hexagon / carbon tech pattern with a moving highlight (background texture).
    case hexGrid
    /// Fire embers rising fast with heat shimmer colours (denser, hotter than the classic embers). Particles.
    case fireEmbers

    var title: String {
        switch self {
        case .lensFlare: "Lens flare"; case .godRays: "God rays"; case .shockwave: "Shockwave"; case .burst: "Particle burst"
        case .converge: "Converging particles"; case .energyStreaks: "Energy streaks"; case .goldSmoke: "Gold smoke"; case .confetti: "Confetti"
        case .lightWipe: "Light wipe"; case .bokeh: "Bokeh"; case .glints: "Glints"; case .hudDial: "HUD dial"; case .hexGrid: "Hex grid"; case .fireEmbers: "Fire embers"
        }
    }
    /// GPU particle program index (vsParticle `ek`), nil for full-quad fragment effects.
    var particleKind: Int? {
        switch self {
        case .burst: 4; case .converge: 5; case .confetti: 6; case .bokeh: 7; case .glints: 8; case .fireEmbers: 9
        default: nil
        }
    }
    /// Fragment effect index (effectColor `ek`), nil for particle effects.
    var fragmentKind: Int? {
        switch self {
        case .lensFlare: 30; case .godRays: 31; case .shockwave: 32; case .energyStreaks: 33; case .goldSmoke: 34
        case .lightWipe: 35; case .hudDial: 36; case .hexGrid: 37
        default: nil
        }
    }
    /// One-shot effects use the show / take clock instead of the free-running time.
    var isOneShot: Bool { self == .shockwave || self == .burst || self == .converge || self == .lightWipe }
    /// Particles are blended additively except confetti (opaque paper).
    var additive: Bool { self != .confetti }
}

/// Specular light band sweeping across a layer's own pixels (logos, gold text), optionally with a continuous metallic shimmer.
/// The band follows the layer's alpha, so only the art lights up.
struct Shine: Codable, Hashable, Sendable {
    var color = RGBA(1, 0.96, 0.82)
    var intensity = 0.9           // 0...2 band brightness
    var width = 0.12              // band half-width as a fraction of the box diagonal extent
    var angle = 20.0              // degrees the band travels (0 = left -> right)
    var duration = 0.9            // seconds one sweep takes
    var period = 4.0              // seconds between sweeps (0 = one sweep only)
    var delay = 0.6               // seconds after show / take before the first sweep
    var shimmer = 0.0             // 0...1 continuous metallic sheen ripple
    init(color: RGBA = RGBA(1, 0.96, 0.82), intensity: Double = 0.9, width: Double = 0.12, angle: Double = 20, duration: Double = 0.9,
         period: Double = 4, delay: Double = 0.6, shimmer: Double = 0) {
        self.color = color; self.intensity = intensity; self.width = width; self.angle = angle; self.duration = duration
        self.period = period; self.delay = delay; self.shimmer = shimmer
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self); let z = Shine()
        color = c.lenient(.color, z.color); intensity = c.lenient(.intensity, z.intensity); width = c.lenient(.width, z.width)
        angle = c.lenient(.angle, z.angle); duration = c.lenient(.duration, z.duration); period = c.lenient(.period, z.period)
        delay = c.lenient(.delay, z.delay); shimmer = c.lenient(.shimmer, z.shimmer)
    }
    private enum K: String, CodingKey { case color, intensity, width, angle, duration, period, delay, shimmer }

    /// Band position 0...1 across the layer at `sinceTake`, or nil when no sweep is running.
    func phase(sinceTake t: Double) -> Double? {
        OneShot.local(sinceTake: t, delay: delay, period: period).flatMap { l in l <= duration ? l / max(0.001, duration) : nil }
    }
}

enum OneShot {
    /// Seconds since a one-shot fired (re-firing every `period` when > 0), nil before the first firing.
    static func local(sinceTake t: Double, delay: Double, period: Double) -> Double? {
        let l = t - delay
        guard l >= 0 else { return nil }
        return period > 0 ? l.truncatingRemainder(dividingBy: period) : l
    }
}

enum AdvancedTiming {
    /// Seconds a one-shot effect stays visible (at speed 1).
    static func length(_ fx: AdvancedFX) -> Double {
        switch fx { case .shockwave: 1.6; case .burst: 2.6; case .converge: 1.9; case .lightWipe: 1.15; default: .infinity }
    }
    /// Local time handed to the shader, or nil when the effect draws nothing now (one-shot not fired yet / finished, or before `delay`).
    /// Continuous effects run from the show / take (plus `delay`), wrapped hourly to keep float precision.
    static func localTime(_ fx: AdvancedFX, spec: EffectSpec, sinceTake: Double) -> Double? {
        if fx.isOneShot {
            guard let l = OneShot.local(sinceTake: sinceTake, delay: spec.delay, period: spec.period) else { return nil }
            return l * max(0.01, spec.speed) <= length(fx) ? l : nil
        }
        let l = sinceTake - spec.delay
        guard l >= 0 else { return nil }
        return l.truncatingRemainder(dividingBy: 3600)
    }
}
