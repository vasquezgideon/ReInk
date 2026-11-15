import Foundation

// MARK: - Framing (per image)

enum FitMode: String, Codable, CaseIterable, Identifiable {
    case fill
    case fit

    var id: String { rawValue }
    var title: String { self == .fill ? "Fill" : "Fit" }
}

/// Where the photo sits on the panel. Belongs to the image, not to a look.
struct ImageTransform: Codable, Equatable {
    var fit: FitMode = .fill
    /// 1 = exactly fill/fit; up to 5x.
    var zoom: Double = 1
    /// Fraction of panel width/height. Positive moves right/down.
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// Clockwise degrees: 0, 90, 180, 270.
    var rotation: Int = 0
    var mirror: Bool = false
    var background: Ink = .white
}

// MARK: - Look (reusable between images, savable for Simple mode)

struct ToneSettings: Codable, Equatable {
    var exposure: Double = 0        // EV, -2...2
    var brightness: Double = 0      // -0.4...0.4
    var contrast: Double = 1        // 0.5...2
    var saturation: Double = 1      // 0...2
    var vibrance: Double = 0        // -1...1
    var warmth: Double = 0          // -3000...3000 (Kelvin offset)
    var tint: Double = 0            // -100...100
    var highlights: Double = 1      // 0...1, 1 = unchanged
    var shadows: Double = 0         // -1...1, 0 = unchanged
    var gamma: Double = 1           // 0.5...2
    var blackPoint: Double = 0      // 0...0.4
    var whitePoint: Double = 1      // 0.6...1
    var sharpen: Double = 0         // 0...2
}

enum MatchMetric: String, Codable, CaseIterable, Identifiable {
    case oklab
    case cielab
    case redmean
    case rgb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oklab: return "OKLab (perceptual)"
        case .cielab: return "CIELAB"
        case .redmean: return "Weighted RGB"
        case .rgb: return "Plain RGB"
        }
    }
}

struct InkSettings: Codable, Equatable {
    var profile: InkProfile = .measured
    var custom: [RGB] = InkProfile.measured.presetColors ?? []
    /// Indexed by `Ink.rawValue`.
    var enabled: [Bool] = [true, true, true, true]
    /// -1 (avoid) ... +1 (prefer), indexed by `Ink.rawValue`.
    var bias: [Double] = [0, 0, 0, 0]
    var metric: MatchMetric = .oklab
    /// Preview with the realistic ink colors instead of pure ones.
    var previewRealInk: Bool = true

    /// Colors used for matching and preview, indexed by `Ink.rawValue`.
    var colors: [RGB] {
        if profile == .custom, custom.count == 4 { return custom }
        return profile.presetColors ?? InkProfile.measured.presetColors!
    }

    func isEnabled(_ ink: Ink) -> Bool {
        enabled.indices.contains(ink.rawValue) ? enabled[ink.rawValue] : true
    }

    func biasFor(_ ink: Ink) -> Double {
        bias.indices.contains(ink.rawValue) ? bias[ink.rawValue] : 0
    }
}

/// Pulls a hue range toward a target color before quantizing. This is how
/// colors the panel can't show (blue, green, purple) get a deliberate home
/// instead of turning into muddy dither.
struct RemapRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// HSV hue in degrees, 0...360.
    var hue: Double
    /// Full width of the hue window in degrees.
    var width: Double = 60
    /// Minimum HSV chroma (0...1) for the rule to apply; keeps greys untouched.
    var minChroma: Double = 0.12
    var target: RGB
    var strength: Double = 1
    var keepLightness: Bool = false
    var enabled: Bool = true

    static let presets: [RemapRule] = [
        RemapRule(name: "Blue → Black", hue: 225, width: 70, target: RGB(0.1, 0.1, 0.12)),
        RemapRule(name: "Green → Yellow", hue: 120, width: 80, target: RGB(0.85, 0.72, 0.1)),
        RemapRule(name: "Cyan → White", hue: 185, width: 40, target: RGB(0.85, 0.85, 0.82)),
        RemapRule(name: "Purple → Red", hue: 285, width: 60, target: RGB(0.65, 0.12, 0.12), keepLightness: true),
        RemapRule(name: "Orange → Red", hue: 25, width: 30, minChroma: 0.3, target: RGB(0.67, 0.14, 0.12), strength: 0.6)
    ]
}

enum DitherAlgorithm: String, Codable, CaseIterable, Identifiable {
    case floydSteinberg
    case atkinson
    case jarvis
    case stucki
    case burkes
    case sierra
    case sierraTwoRow
    case sierraLite
    case bayer2
    case bayer4
    case bayer8
    case noise
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floydSteinberg: return "Floyd–Steinberg"
        case .atkinson: return "Atkinson"
        case .jarvis: return "Jarvis–Judice–Ninke"
        case .stucki: return "Stucki"
        case .burkes: return "Burkes"
        case .sierra: return "Sierra"
        case .sierraTwoRow: return "Sierra 2-row"
        case .sierraLite: return "Sierra Lite"
        case .bayer2: return "Bayer 2×2"
        case .bayer4: return "Bayer 4×4"
        case .bayer8: return "Bayer 8×8"
        case .noise: return "Blue-ish noise"
        case .none: return "None (posterize)"
        }
    }

    var isOrdered: Bool {
        switch self {
        case .bayer2, .bayer4, .bayer8, .noise: return true
        default: return false
        }
    }

    var isDiffusion: Bool { !isOrdered && self != .none }
}

struct DitherSettings: Codable, Equatable {
    var algorithm: DitherAlgorithm = .floydSteinberg
    /// Fraction of the quantization error carried forward (or ordered spread).
    var strength: Double = 0.85
    var serpentine: Bool = true
    /// Diffuse error in linear light (physically correct averaging).
    var linearLight: Bool = true
    /// Max per-channel error carried, 0.05...1.
    var errorClamp: Double = 0.6
    /// Errors smaller than this are dropped, which cleans up flat areas.
    var deadzone: Double = 0
    /// If a pixel is this close (OKLab-ish units) to a pure ink, snap to it
    /// with no error. 0 = off.
    var snap: Double = 0
}

struct HalftoneSettings: Codable, Equatable {
    var enabled: Bool = false
    /// Mix ids (`InkMix.id`) that may be used.
    var mixes: [String] = InkMix.all.map(\.id)
    /// Also allow 25% / 75% patterns, not just 50% checkers. Fills the gap
    /// between pure inks and 50% tones, which otherwise causes "worms".
    var quarterTones: Bool = true
}

struct LookSettings: Codable, Equatable {
    /// Turns halfway tones on/off the way Simple mode does: tones pair best
    /// with ordered dithering, so switch away from error diffusion with them.
    mutating func setHalfwayTones(_ on: Bool) {
        halftone.enabled = on
        if on {
            halftone.quarterTones = true
            if dither.algorithm.isDiffusion || dither.algorithm == .none {
                dither.algorithm = .bayer8
                dither.strength = min(dither.strength, 0.6)
            }
        } else if dither.algorithm.isOrdered {
            dither.algorithm = .floydSteinberg
            dither.strength = 0.85
        }
    }

    var tone = ToneSettings()
    var ink = InkSettings()
    var remap: [RemapRule] = []
    var dither = DitherSettings()
    var halftone = HalftoneSettings()
}

struct RenderSettings: Codable, Equatable {
    var transform = ImageTransform()
    var look = LookSettings()
}

// MARK: - Saved looks (Advanced → Simple)

struct Look: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var symbol: String = "wand.and.stars"
    var settings: LookSettings
    var builtIn: Bool = false

    static let builtIns: [Look] = {
        var natural = LookSettings()
        natural.remap = [RemapRule.presets[0]]

        var vivid = LookSettings()
        vivid.tone.saturation = 1.35
        vivid.tone.contrast = 1.15
        vivid.tone.vibrance = 0.3
        vivid.dither.algorithm = .atkinson
        vivid.remap = [RemapRule.presets[0], RemapRule.presets[1]]

        var clean = LookSettings()
        clean.tone.contrast = 1.1
        clean.dither.algorithm = .bayer8
        clean.dither.strength = 0.6
        clean.halftone.enabled = true
        clean.halftone.quarterTones = true
        clean.remap = [RemapRule.presets[0]]

        var poster = LookSettings()
        poster.tone.contrast = 1.3
        poster.tone.saturation = 1.5
        poster.dither.algorithm = .none
        poster.remap = [RemapRule.presets[0], RemapRule.presets[1], RemapRule.presets[3]]

        var mono = LookSettings()
        mono.tone.saturation = 0
        mono.tone.contrast = 1.1
        mono.ink.enabled = [true, true, false, false]
        mono.dither.algorithm = .atkinson

        var halftone = LookSettings()
        halftone.dither.algorithm = .bayer4
        halftone.dither.strength = 0.6
        halftone.halftone.enabled = true
        halftone.halftone.quarterTones = true
        halftone.remap = [RemapRule.presets[0]]

        return [
            Look(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Natural", symbol: "photo", settings: natural, builtIn: true),
            Look(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Vivid", symbol: "sparkles", settings: vivid, builtIn: true),
            Look(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Clean", symbol: "square.grid.2x2", settings: clean, builtIn: true),
            Look(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Poster", symbol: "paintpalette", settings: poster, builtIn: true),
            Look(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "Ink", symbol: "pencil.and.scribble", settings: mono, builtIn: true),
            Look(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, name: "Halftone", symbol: "circle.grid.3x3", settings: halftone, builtIn: true)
        ]
    }()
}
