import SwiftUI
import UIKit

/// An sRGB color stored as 0...1 doubles. Codable so it can live in looks and settings.
struct RGB: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(bytes r: Int, _ g: Int, _ b: Int) {
        self.r = Double(r) / 255.0
        self.g = Double(g) / 255.0
        self.b = Double(b) / 255.0
    }

    /// Converts any SwiftUI color into clamped sRGB components.
    init(_ color: Color) {
        let ui = UIColor(color)
        var rr: CGFloat = 0
        var gg: CGFloat = 0
        var bb: CGFloat = 0
        var aa: CGFloat = 0
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = ui.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
           let comps = converted.components, comps.count >= 3 {
            rr = comps[0]
            gg = comps[1]
            bb = comps[2]
        } else {
            ui.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        }
        self.r = min(max(Double(rr), 0), 1)
        self.g = min(max(Double(gg), 0), 1)
        self.b = min(max(Double(bb), 0), 1)
    }

    var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var simd: SIMD3<Float> {
        SIMD3<Float>(Float(r), Float(g), Float(b))
    }

    var hexString: String {
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

/// The four physical inks of a BWRY panel. Raw values are ReInk's internal
/// indices; the code actually sent to the case is set per panel profile.
enum Ink: Int, CaseIterable, Codable, Identifiable {
    case black = 0
    case white = 1
    case yellow = 2
    case red = 3

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .black: return "Black"
        case .white: return "White"
        case .yellow: return "Yellow"
        case .red: return "Red"
        }
    }

    var short: String {
        switch self {
        case .black: return "B"
        case .white: return "W"
        case .yellow: return "Y"
        case .red: return "R"
        }
    }

    /// Ideal screen color, used for UI swatches.
    var ideal: RGB {
        switch self {
        case .black: return RGB(0, 0, 0)
        case .white: return RGB(1, 1, 1)
        case .yellow: return RGB(1, 0.85, 0)
        case .red: return RGB(0.85, 0.08, 0.08)
        }
    }
}

/// How the four inks actually look. Matching against realistic ink colors is
/// what makes the color approximation honest: a panel "white" is paper grey,
/// "yellow" is mustard, "red" is brick.
enum InkProfile: String, Codable, CaseIterable, Identifiable {
    case measured
    case tuned
    case pure
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .measured: return "Typical panel"
        case .tuned: return "Deep (nfc-eink tuned)"
        case .pure: return "Pure RGB"
        case .custom: return "Custom"
        }
    }

    var detail: String {
        switch self {
        case .measured: return "Estimated look of a BWRY case panel. Best starting point."
        case .tuned: return "Darker whites and inks; punchier contrast."
        case .pure: return "Idealized colors. Brighter preview, less accurate."
        case .custom: return "Your own measured ink colors."
        }
    }

    /// Colors indexed by `Ink.rawValue`. Nil for custom.
    var presetColors: [RGB]? {
        switch self {
        case .measured:
            return [RGB(bytes: 38, 38, 42), RGB(bytes: 206, 206, 198), RGB(bytes: 216, 184, 24), RGB(bytes: 170, 36, 32)]
        case .tuned:
            return [RGB(bytes: 0, 0, 0), RGB(bytes: 160, 160, 160), RGB(bytes: 200, 128, 0), RGB(bytes: 160, 0, 0)]
        case .pure:
            return [RGB(bytes: 0, 0, 0), RGB(bytes: 255, 255, 255), RGB(bytes: 255, 255, 0), RGB(bytes: 255, 0, 0)]
        case .custom:
            return nil
        }
    }
}

/// A "halfway" tone made from two inks laid down in a fixed micro-pattern.
/// The panel only has four inks, but a regular 50% checker (or 25/75 Bayer
/// pattern) at 212 PPI reads as a flat new color with far less visible noise
/// than error-diffusion dithering.
struct InkMix: Codable, Hashable, Identifiable {
    var a: Ink
    var b: Ink

    var id: String { "\(a.rawValue)-\(b.rawValue)" }

    var name: String {
        switch (a, b) {
        case (.black, .white): return "Grey"
        case (.red, .white): return "Pink"
        case (.red, .black): return "Maroon"
        case (.red, .yellow): return "Orange"
        case (.yellow, .white): return "Cream"
        case (.yellow, .black): return "Olive"
        default: return "\(a.name)/\(b.name)"
        }
    }

    static let all: [InkMix] = [
        InkMix(a: .black, b: .white),
        InkMix(a: .red, b: .white),
        InkMix(a: .red, b: .black),
        InkMix(a: .red, b: .yellow),
        InkMix(a: .yellow, b: .white),
        InkMix(a: .yellow, b: .black)
    ]
}
