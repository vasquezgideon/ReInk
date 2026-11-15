import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

struct RenderResult {
    let width: Int
    let height: Int
    /// `Ink.rawValue` per pixel.
    let indices: [UInt8]
    /// Dithered preview in display ink colors.
    let preview: CGImage
    /// Graded, framed image before quantizing (for before/after compare).
    let graded: CGImage
    let coverage: [Double]
}

enum RenderEngine {
    static let srgb: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static let ciContext: CIContext = {
        var options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let linear = CGColorSpace(name: CGColorSpace.linearSRGB) {
            options[.workingColorSpace] = linear
        }
        return CIContext(options: options)
    }()

    /// Full pipeline: frame → grade → levels/remap → quantize.
    static func render(source: CGImage, settings: RenderSettings, panel: PanelProfile) -> RenderResult? {
        let w = panel.width
        let h = panel.height
        let look = settings.look
        let bgColor = look.ink.colors[settings.transform.background.rawValue]
        guard let framed = composite(source, transform: settings.transform, width: w, height: h, background: bgColor),
              let graded = grade(framed, tone: look.tone) else { return nil }
        let rgba = rgbaBytes(graded, width: w, height: h)
        let srgbFloats = Preprocess.apply(rgba: rgba, width: w, height: h, tone: look.tone, rules: look.remap)
        let q = Quantizer.run(srgb: srgbFloats, width: w, height: h, look: look)
        guard let preview = makeImage(rgba: q.preview, width: w, height: h) else { return nil }
        return RenderResult(width: w, height: h, indices: q.indices, preview: preview, graded: graded, coverage: q.coverage)
    }

    /// Places the source on a panel-sized canvas.
    static func composite(_ source: CGImage, transform t: ImageTransform, width: Int, height: Int, background: RGB) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: CGFloat(background.r), green: CGFloat(background.g), blue: CGFloat(background.b), alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        let W = CGFloat(width)
        let H = CGFloat(height)
        let quarterTurn = (t.rotation / 90) % 2 == 1
        let iw = CGFloat(quarterTurn ? source.height : source.width)
        let ih = CGFloat(quarterTurn ? source.width : source.height)
        guard iw > 0, ih > 0 else { return nil }
        let base: CGFloat = t.fit == .fill ? max(W / iw, H / ih) : min(W / iw, H / ih)
        let scale = base * CGFloat(t.zoom)

        // CG is y-up: positive offsetY (down on screen) means subtracting.
        ctx.translateBy(x: W / 2 + CGFloat(t.offsetX) * W, y: H / 2 - CGFloat(t.offsetY) * H)
        ctx.rotate(by: -CGFloat(t.rotation) * .pi / 180)
        if t.mirror { ctx.scaleBy(x: -1, y: 1) }
        ctx.scaleBy(x: scale, y: scale)
        let dw = CGFloat(source.width)
        let dh = CGFloat(source.height)
        ctx.draw(source, in: CGRect(x: -dw / 2, y: -dh / 2, width: dw, height: dh))
        return ctx.makeImage()
    }

    /// Core Image grading. Levels, gamma and remap happen later in `Preprocess`.
    static func grade(_ image: CGImage, tone: ToneSettings) -> CGImage? {
        var ci = CIImage(cgImage: image)
        let extent = ci.extent

        if tone.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = ci
            f.ev = Float(tone.exposure)
            if let o = f.outputImage { ci = o }
        }
        if tone.warmth != 0 || tone.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = ci
            f.neutral = CIVector(x: 6500 + CGFloat(tone.warmth), y: CGFloat(tone.tint))
            f.targetNeutral = CIVector(x: 6500, y: 0)
            if let o = f.outputImage { ci = o }
        }
        if tone.highlights != 1 || tone.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = ci
            f.highlightAmount = Float(tone.highlights)
            f.shadowAmount = Float(tone.shadows)
            f.radius = 8
            if let o = f.outputImage { ci = o }
        }
        if tone.brightness != 0 || tone.contrast != 1 || tone.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = ci
            f.brightness = Float(tone.brightness)
            f.contrast = Float(tone.contrast)
            f.saturation = Float(tone.saturation)
            if let o = f.outputImage { ci = o }
        }
        if tone.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = ci
            f.amount = Float(tone.vibrance)
            if let o = f.outputImage { ci = o }
        }
        if tone.gamma != 1 {
            let f = CIFilter.gammaAdjust()
            f.inputImage = ci
            f.power = Float(tone.gamma)
            if let o = f.outputImage { ci = o }
        }
        if tone.sharpen > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = ci
            f.radius = 1.5
            f.intensity = Float(tone.sharpen)
            if let o = f.outputImage { ci = o }
        }
        ci = ci.cropped(to: extent)
        return ciContext.createCGImage(ci, from: extent, format: .RGBA8, colorSpace: srgb)
    }

    /// Draws a CGImage into a tightly packed RGBX8 sRGB buffer (top row first).
    static func rgbaBytes(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    static func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Image from ink indices, using the given display colors.
    static func image(indices: [UInt8], width: Int, height: Int, colors: [RGB]) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for p in 0..<(width * height) {
            let c = colors[Int(indices[p]) & 3]
            rgba[p * 4] = UInt8(max(0, min(255, (c.r * 255).rounded())))
            rgba[p * 4 + 1] = UInt8(max(0, min(255, (c.g * 255).rounded())))
            rgba[p * 4 + 2] = UInt8(max(0, min(255, (c.b * 255).rounded())))
        }
        return makeImage(rgba: rgba, width: width, height: height)
    }

    /// Loads image data, applies EXIF orientation and caps the long edge.
    static func loadSource(data: Data, maxDimension: CGFloat = 2400) -> CGImage? {
        guard let ui = UIImage(data: data) else { return nil }
        let size = ui.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let normalized = renderer.image { _ in
            ui.draw(in: CGRect(origin: .zero, size: target))
        }
        return normalized.cgImage
    }
}

/// Levels and hue remapping on the sRGB float image (after Core Image).
enum Preprocess {
    static func apply(rgba: [UInt8], width: Int, height: Int, tone: ToneSettings, rules: [RemapRule]) -> [Float] {
        let count = width * height
        var out = [Float](repeating: 0, count: count * 3)
        let bp = Float(tone.blackPoint)
        let wp = Float(max(tone.whitePoint, tone.blackPoint + 0.02))
        let span = wp - bp
        let applyLevels = bp != 0 || wp != 1

        struct PreparedRule {
            var hue: Float
            var half: Float
            var feather: Float
            var minChroma: Float
            var target: SIMD3<Float>
            var strength: Float
            var keepLightness: Bool
        }
        let prepared: [PreparedRule] = rules.filter { $0.enabled && $0.strength > 0 }.map { r in
            let half = Float(max(r.width, 2)) / 2
            let lin = ColorMath.srgbToLinear(r.target.simd)
            return PreparedRule(hue: Float(r.hue), half: half, feather: max(half * 0.4, 1),
                                minChroma: Float(r.minChroma), target: ColorMath.oklab(fromLinear: lin),
                                strength: Float(min(max(r.strength, 0), 1)), keepLightness: r.keepLightness)
        }

        out.withUnsafeMutableBufferPointer { dst in
            rgba.withUnsafeBufferPointer { src in
                for p in 0..<count {
                    var c = SIMD3<Float>(Float(src[p * 4]) / 255, Float(src[p * 4 + 1]) / 255, Float(src[p * 4 + 2]) / 255)
                    if applyLevels {
                        c = clamp01((c - SIMD3<Float>(repeating: bp)) / span)
                    }
                    if !prepared.isEmpty {
                        let hc = ColorMath.hueChroma(srgb: c)
                        var lab: SIMD3<Float>? = nil
                        for rule in prepared {
                            var d = abs(hc.hue - rule.hue)
                            if d > 180 { d = 360 - d }
                            let wHue: Float
                            if d <= rule.half - rule.feather {
                                wHue = 1
                            } else if d >= rule.half {
                                wHue = 0
                            } else {
                                wHue = (rule.half - d) / rule.feather
                            }
                            if wHue <= 0 { continue }
                            let wChroma = min(max((hc.chroma - rule.minChroma) / 0.08, 0), 1)
                            let k = wHue * wChroma * rule.strength
                            if k <= 0 { continue }
                            var current = lab ?? ColorMath.oklab(fromLinear: ColorMath.srgbToLinear(c))
                            var target = rule.target
                            if rule.keepLightness { target.x = current.x }
                            current = current + (target - current) * k
                            lab = current
                        }
                        if let lab {
                            c = clamp01(ColorMath.linearToSrgb(ColorMath.linear(fromOklab: lab)))
                        }
                    }
                    dst[p * 3] = c.x
                    dst[p * 3 + 1] = c.y
                    dst[p * 3 + 2] = c.z
                }
            }
        }
        return out
    }
}
