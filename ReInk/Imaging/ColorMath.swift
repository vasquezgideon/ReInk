import Foundation

/// Color-space helpers. Expressions are split into small typed steps on
/// purpose: long float literal chains are slow for the Swift type checker.
enum ColorMath {
    /// sRGB byte → linear light.
    static let byteToLinear: [Float] = (0..<256).map { (i: Int) -> Float in
        let v: Float = Float(i) / 255.0
        return ColorMath.srgbToLinear(v)
    }

    @inline(__always)
    static func srgbToLinear(_ c: Float) -> Float {
        if c <= 0.04045 { return c / 12.92 }
        let base: Float = (c + 0.055) / 1.055
        return powf(base, 2.4)
    }

    @inline(__always)
    static func linearToSrgb(_ c: Float) -> Float {
        let v = min(max(c, 0), 1)
        if v <= 0.0031308 { return v * 12.92 }
        let p: Float = powf(v, 1.0 / 2.4)
        return 1.055 * p - 0.055
    }

    @inline(__always)
    static func srgbToLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z))
    }

    @inline(__always)
    static func linearToSrgb(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(linearToSrgb(c.x), linearToSrgb(c.y), linearToSrgb(c.z))
    }

    // MARK: OKLab (Björn Ottosson), from linear sRGB.

    @inline(__always)
    static func oklab(fromLinear c: SIMD3<Float>) -> SIMD3<Float> {
        var l: Float = 0.4122214708 * c.x
        l += 0.5363325363 * c.y
        l += 0.0514459929 * c.z
        var m: Float = 0.2119034982 * c.x
        m += 0.6806995451 * c.y
        m += 0.1073969566 * c.z
        var s: Float = 0.0883024619 * c.x
        s += 0.2817188376 * c.y
        s += 0.6299787005 * c.z
        let l3: Float = cbrtf(l)
        let m3: Float = cbrtf(m)
        let s3: Float = cbrtf(s)
        var L: Float = 0.2104542553 * l3
        L += 0.7936177850 * m3
        L -= 0.0040720468 * s3
        var a: Float = 1.9779984951 * l3
        a -= 2.4285922050 * m3
        a += 0.4505937099 * s3
        var b: Float = 0.0259040371 * l3
        b += 0.7827717662 * m3
        b -= 0.8086757660 * s3
        return SIMD3<Float>(L, a, b)
    }

    @inline(__always)
    static func linear(fromOklab lab: SIMD3<Float>) -> SIMD3<Float> {
        var l3: Float = lab.x + 0.3963377774 * lab.y
        l3 += 0.2158037573 * lab.z
        var m3: Float = lab.x - 0.1055613458 * lab.y
        m3 -= 0.0638541728 * lab.z
        var s3: Float = lab.x - 0.0894841775 * lab.y
        s3 -= 1.2914855480 * lab.z
        let l: Float = l3 * l3 * l3
        let m: Float = m3 * m3 * m3
        let s: Float = s3 * s3 * s3
        var r: Float = 4.0767416621 * l
        r -= 3.3077115913 * m
        r += 0.2309699292 * s
        var g: Float = -1.2684380046 * l
        g += 2.6097574011 * m
        g -= 0.3413193965 * s
        var bb: Float = -0.0041960863 * l
        bb -= 0.7034186147 * m
        bb += 1.7076147010 * s
        return SIMD3<Float>(r, g, bb)
    }

    // MARK: CIELAB (D65), from linear sRGB. Scaled by 1/100 so distances
    // are on a similar scale to OKLab.

    @inline(__always)
    private static func labF(_ t: Float) -> Float {
        if t > 0.008856 { return cbrtf(t) }
        return 7.787 * t + 16.0 / 116.0
    }

    @inline(__always)
    static func cielab(fromLinear c: SIMD3<Float>) -> SIMD3<Float> {
        var x: Float = 0.4124564 * c.x
        x += 0.3575761 * c.y
        x += 0.1804375 * c.z
        var y: Float = 0.2126729 * c.x
        y += 0.7151522 * c.y
        y += 0.0721750 * c.z
        var z: Float = 0.0193339 * c.x
        z += 0.1191920 * c.y
        z += 0.9503041 * c.z
        let fx = labF(x / 0.95047)
        let fy = labF(y)
        let fz = labF(z / 1.08883)
        let L: Float = (116 * fy - 16) / 100
        let a: Float = 5 * (fx - fy)
        let b: Float = 2 * (fy - fz)
        return SIMD3<Float>(L, a, b)
    }

    /// HSV hue (degrees) and chroma (max - min) of an sRGB color.
    @inline(__always)
    static func hueChroma(srgb c: SIMD3<Float>) -> (hue: Float, chroma: Float) {
        let mx = max(c.x, max(c.y, c.z))
        let mn = min(c.x, min(c.y, c.z))
        let d = mx - mn
        if d <= 0.00001 { return (0, 0) }
        var h: Float
        if mx == c.x {
            h = (c.y - c.z) / d
            if h < 0 { h += 6 }
        } else if mx == c.y {
            h = (c.z - c.x) / d + 2
        } else {
            h = (c.x - c.y) / d + 4
        }
        return (h * 60, d)
    }

    @inline(__always)
    static func luminance(linear c: SIMD3<Float>) -> Float {
        var y: Float = 0.2126 * c.x
        y += 0.7152 * c.y
        y += 0.0722 * c.z
        return y
    }
}
