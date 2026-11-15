import Foundation

struct QuantizeOutput {
    /// `Ink.rawValue` per pixel, row-major, top-left origin.
    var indices: [UInt8]
    /// RGBA8 preview using the chosen display colors.
    var preview: [UInt8]
    /// Fraction of pixels per ink, indexed by `Ink.rawValue`.
    var coverage: [Double]
}

/// Maps a graded sRGB float image onto the four inks (plus optional
/// pattern "halfway" tones) with the chosen dithering method.
enum Quantizer {
    private struct Candidate {
        var work: SIMD3<Float>
        var metric: SIMD3<Float>
        var inkA: UInt8
        var inkB: UInt8
        /// Share of pixels that use `inkA`. 1 = pure ink.
        var ratio: Float
        /// Distance multiplier from ink bias (<1 preferred, >1 avoided).
        var weight: Float
    }

    private struct KernelTap {
        var dx: Int
        var dy: Int
        var w: Float
    }

    private static func kernel(for algorithm: DitherAlgorithm) -> [KernelTap] {
        func taps(_ raw: [(Int, Int, Float)], _ divisor: Float) -> [KernelTap] {
            raw.map { KernelTap(dx: $0.0, dy: $0.1, w: $0.2 / divisor) }
        }
        switch algorithm {
        case .floydSteinberg:
            return taps([(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)], 16)
        case .atkinson:
            return taps([(1, 0, 1), (2, 0, 1), (-1, 1, 1), (0, 1, 1), (1, 1, 1), (0, 2, 1)], 8)
        case .jarvis:
            return taps([(1, 0, 7), (2, 0, 5), (-2, 1, 3), (-1, 1, 5), (0, 1, 7), (1, 1, 5), (2, 1, 3),
                         (-2, 2, 1), (-1, 2, 3), (0, 2, 5), (1, 2, 3), (2, 2, 1)], 48)
        case .stucki:
            return taps([(1, 0, 8), (2, 0, 4), (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2),
                         (-2, 2, 1), (-1, 2, 2), (0, 2, 4), (1, 2, 2), (2, 2, 1)], 42)
        case .burkes:
            return taps([(1, 0, 8), (2, 0, 4), (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2)], 32)
        case .sierra:
            return taps([(1, 0, 5), (2, 0, 3), (-2, 1, 2), (-1, 1, 4), (0, 1, 5), (1, 1, 4), (2, 1, 2),
                         (-1, 2, 2), (0, 2, 3), (1, 2, 2)], 32)
        case .sierraTwoRow:
            return taps([(1, 0, 4), (2, 0, 3), (-2, 1, 1), (-1, 1, 2), (0, 1, 3), (1, 1, 2), (2, 1, 1)], 16)
        case .sierraLite:
            return taps([(1, 0, 2), (-1, 1, 1), (0, 1, 1)], 4)
        default:
            return []
        }
    }

    /// Normalized Bayer threshold matrix (values in 0..<1), row-major n×n.
    static func bayer(_ n: Int) -> [Float] {
        var m: [Int] = [0, 2, 3, 1]
        var size = 2
        while size < n {
            let next = size * 2
            var out = [Int](repeating: 0, count: next * next)
            for y in 0..<next {
                for x in 0..<next {
                    let base = 4 * m[(y % size) * size + (x % size)]
                    let quadrant = (y / size) * 2 + (x / size)
                    let add = [0, 2, 3, 1][quadrant]
                    out[y * next + x] = base + add
                }
            }
            m = out
            size = next
        }
        let count = Float(size * size)
        return m.map { (Float($0) + 0.5) / count }
    }

    @inline(__always)
    private static func ign(_ x: Int, _ y: Int) -> Float {
        let v: Float = 0.06711056 * Float(x) + 0.00583715 * Float(y)
        let f1 = v - floorf(v)
        let w: Float = 52.9829189 * f1
        return w - floorf(w)
    }

    static func run(srgb input: [Float], width: Int, height: Int, look: LookSettings) -> QuantizeOutput {
        let pixelCount = width * height
        let dither = look.dither
        let linearLight = dither.linearLight
        let metric = look.ink.metric
        let colors = look.ink.colors

        func metricCoords(linear lin: SIMD3<Float>, srgb: SIMD3<Float>) -> SIMD3<Float> {
            switch metric {
            case .oklab: return ColorMath.oklab(fromLinear: lin)
            case .cielab: return ColorMath.cielab(fromLinear: lin)
            case .redmean, .rgb: return srgb
            }
        }

        // Build candidate list.
        var candidates: [Candidate] = []
        var inkWeights = [Float](repeating: 1, count: 4)
        var inkLinear = [SIMD3<Float>](repeating: .zero, count: 4)
        for ink in Ink.allCases {
            let srgb = colors[ink.rawValue].simd
            let lin = ColorMath.srgbToLinear(srgb)
            inkLinear[ink.rawValue] = lin
            let bias = Float(look.ink.biasFor(ink))
            inkWeights[ink.rawValue] = powf(2, -bias)
            guard look.ink.isEnabled(ink) else { continue }
            candidates.append(Candidate(
                work: linearLight ? lin : srgb,
                metric: metricCoords(linear: lin, srgb: srgb),
                inkA: UInt8(ink.rawValue),
                inkB: UInt8(ink.rawValue),
                ratio: 1,
                weight: inkWeights[ink.rawValue]))
        }
        if candidates.isEmpty {
            // Nothing enabled: fall back to black + white.
            for ink in [Ink.black, Ink.white] {
                let srgb = colors[ink.rawValue].simd
                let lin = ColorMath.srgbToLinear(srgb)
                candidates.append(Candidate(work: linearLight ? lin : srgb,
                                            metric: metricCoords(linear: lin, srgb: srgb),
                                            inkA: UInt8(ink.rawValue), inkB: UInt8(ink.rawValue),
                                            ratio: 1, weight: 1))
            }
        }
        let pureCount = candidates.count

        if look.halftone.enabled {
            let ratios: [Float] = look.halftone.quarterTones ? [0.25, 0.5, 0.75] : [0.5]
            for mix in InkMix.all where look.halftone.mixes.contains(mix.id) {
                guard look.ink.isEnabled(mix.a), look.ink.isEnabled(mix.b) else { continue }
                let la = inkLinear[mix.a.rawValue]
                let lb = inkLinear[mix.b.rawValue]
                for r in ratios {
                    let lin = la * r + lb * (1 - r)
                    let srgb = ColorMath.linearToSrgb(lin)
                    let wa = inkWeights[mix.a.rawValue]
                    let wb = inkWeights[mix.b.rawValue]
                    candidates.append(Candidate(
                        work: linearLight ? lin : srgb,
                        metric: metricCoords(linear: lin, srgb: srgb),
                        inkA: UInt8(mix.a.rawValue),
                        inkB: UInt8(mix.b.rawValue),
                        ratio: r,
                        weight: (wa + wb) * 0.5))
                }
            }
        }

        // Working buffer.
        var buf = [Float](repeating: 0, count: pixelCount * 3)
        input.withUnsafeBufferPointer { src in
            buf.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(pixelCount * 3) {
                    let v = min(max(src[i], 0), 1)
                    dst[i] = linearLight ? ColorMath.srgbToLinear(v) : v
                }
            }
        }

        let taps = kernel(for: dither.algorithm)
        let ordered: [Float]
        let orderedSize: Int
        switch dither.algorithm {
        case .bayer2: ordered = bayer(2); orderedSize = 2
        case .bayer4: ordered = bayer(4); orderedSize = 4
        case .bayer8: ordered = bayer(8); orderedSize = 8
        default: ordered = []; orderedSize = 0
        }
        let isNoise = dither.algorithm == .noise
        let spread: Float = Float(dither.strength) * (linearLight ? 0.35 : 0.5)
        let strength = Float(dither.strength)
        let clampE = Float(max(dither.errorClamp, 0.01))
        let dead = Float(dither.deadzone)
        let snap = Float(dither.snap)
        let snapSq = snap * snap
        let bayer2: [Int] = [0, 2, 3, 1]

        var indices = [UInt8](repeating: 0, count: pixelCount)
        var counts = [Int](repeating: 0, count: 4)

        buf.withUnsafeMutableBufferPointer { b in
            candidates.withUnsafeBufferPointer { cands in
                for y in 0..<height {
                    let rtl = dither.serpentine && dither.algorithm.isDiffusion && (y & 1) == 1
                    let dir = rtl ? -1 : 1
                    for step in 0..<width {
                        let x = rtl ? (width - 1 - step) : step
                        let p = y * width + x
                        let o = p * 3
                        var cw = SIMD3<Float>(b[o], b[o + 1], b[o + 2])
                        cw = clamp01(cw)

                        var probe = cw
                        if orderedSize > 0 {
                            let t = ordered[(y % orderedSize) * orderedSize + (x % orderedSize)] - 0.5
                            probe = clamp01(cw + SIMD3<Float>(repeating: t * spread))
                        } else if isNoise {
                            let t = ign(x, y) - 0.5
                            probe = clamp01(cw + SIMD3<Float>(repeating: t * spread))
                        }

                        let lin = linearLight ? probe : ColorMath.srgbToLinear(probe)
                        let srgbP: SIMD3<Float>
                        if metric == .rgb || metric == .redmean {
                            srgbP = linearLight ? ColorMath.linearToSrgb(probe) : probe
                        } else {
                            srgbP = probe
                        }
                        let pm = metricCoords(linear: lin, srgb: srgbP)

                        var best = 0
                        var bestD = Float.greatestFiniteMagnitude
                        var bestPure = 0
                        var bestPureRaw = Float.greatestFiniteMagnitude
                        for k in 0..<cands.count {
                            let c = cands[k]
                            let diff = pm - c.metric
                            var d: Float
                            if metric == .redmean {
                                let rm = (pm.x + c.metric.x) * 0.5
                                let d0 = (2 + rm) * diff.x * diff.x
                                let d1 = 4 * diff.y * diff.y
                                let d2 = (3 - rm) * diff.z * diff.z
                                d = (d0 + d1 + d2) / 9
                            } else {
                                d = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z
                            }
                            if k < pureCount && d < bestPureRaw {
                                bestPureRaw = d
                                bestPure = k
                            }
                            d *= c.weight
                            if d < bestD {
                                bestD = d
                                best = k
                            }
                        }

                        var chosen = best
                        var carryError = taps.isEmpty == false
                        if snapSq > 0 && bestPureRaw < snapSq {
                            chosen = bestPure
                            carryError = false
                        }

                        let c = cands[chosen]
                        let ink: UInt8
                        if c.ratio >= 1 {
                            ink = c.inkA
                        } else {
                            let th = (Float(bayer2[(y & 1) * 2 + (x & 1)]) + 0.5) / 4
                            ink = th < c.ratio ? c.inkA : c.inkB
                        }
                        indices[p] = ink
                        counts[Int(ink)] += 1

                        if carryError {
                            var err = (cw - c.work) * strength
                            err = pointwiseMax(pointwiseMin(err, SIMD3<Float>(repeating: clampE)), SIMD3<Float>(repeating: -clampE))
                            if dead > 0 {
                                if abs(err.x) < dead { err.x = 0 }
                                if abs(err.y) < dead { err.y = 0 }
                                if abs(err.z) < dead { err.z = 0 }
                            }
                            if err.x != 0 || err.y != 0 || err.z != 0 {
                                for tap in taps {
                                    let nx = x + tap.dx * dir
                                    let ny = y + tap.dy
                                    if nx < 0 || nx >= width || ny >= height { continue }
                                    let q = (ny * width + nx) * 3
                                    b[q] += err.x * tap.w
                                    b[q + 1] += err.y * tap.w
                                    b[q + 2] += err.z * tap.w
                                }
                            }
                        }
                    }
                }
            }
        }

        // Preview.
        let display: [RGB] = look.ink.previewRealInk ? colors : (InkProfile.pure.presetColors ?? colors)
        var lut = [UInt8](repeating: 255, count: 16)
        for ink in Ink.allCases {
            let c = display[ink.rawValue]
            lut[ink.rawValue * 4] = UInt8(max(0, min(255, (c.r * 255).rounded())))
            lut[ink.rawValue * 4 + 1] = UInt8(max(0, min(255, (c.g * 255).rounded())))
            lut[ink.rawValue * 4 + 2] = UInt8(max(0, min(255, (c.b * 255).rounded())))
            lut[ink.rawValue * 4 + 3] = 255
        }
        var preview = [UInt8](repeating: 255, count: pixelCount * 4)
        preview.withUnsafeMutableBufferPointer { out in
            for p in 0..<pixelCount {
                let base = Int(indices[p]) * 4
                let o = p * 4
                out[o] = lut[base]
                out[o + 1] = lut[base + 1]
                out[o + 2] = lut[base + 2]
                out[o + 3] = 255
            }
        }

        let total = Double(max(pixelCount, 1))
        return QuantizeOutput(indices: indices, preview: preview, coverage: counts.map { Double($0) / total })
    }

    /// Exact nearest-ink mapping with no dithering, for test patterns and solid fills.
    static func nearestPure(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        let pure = Ink.allCases.map { $0.ideal.simd }
        var out = [UInt8](repeating: 1, count: width * height)
        for p in 0..<(width * height) {
            let c = SIMD3<Float>(Float(rgba[p * 4]) / 255, Float(rgba[p * 4 + 1]) / 255, Float(rgba[p * 4 + 2]) / 255)
            var best = 0
            var bestD = Float.greatestFiniteMagnitude
            for (k, q) in pure.enumerated() {
                let d = c - q
                let dist = d.x * d.x + d.y * d.y + d.z * d.z
                if dist < bestD {
                    bestD = dist
                    best = k
                }
            }
            out[p] = UInt8(best)
        }
        return out
    }
}

@inline(__always)
func clamp01(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1))
}
