import Foundation

/// Turns ink indices into the 2-bit frame the case's controller expects.
enum FramePacker {
    enum PackError: LocalizedError {
        case sizeMismatch(expected: Int, got: Int)
        case unalignedSize(width: Int, height: Int)

        var errorDescription: String? {
            switch self {
            case let .sizeMismatch(expected, got):
                return "Image has \(got) pixels but the panel needs \(expected)."
            case let .unalignedSize(width, height):
                return "Panel size \(width)×\(height) must be a multiple of 4 along the scan direction."
            }
        }
    }

    /// - Parameter indices: `Ink.rawValue` per pixel, row-major, top-left origin,
    ///   `panel.width × panel.height`.
    static func pack(indices: [UInt8], panel: PanelProfile) throws -> Data {
        let w = panel.width
        let h = panel.height
        guard indices.count == w * h else {
            throw PackError.sizeMismatch(expected: w * h, got: indices.count)
        }
        let codes: [UInt8] = Ink.allCases.map { panel.code(for: $0) }

        // Apply calibration transforms while looking up pixels.
        func code(_ x: Int, _ y: Int) -> UInt8 {
            var sx = panel.mirror ? (w - 1 - x) : x
            var sy = y
            if panel.rotate180 {
                sx = w - 1 - sx
                sy = h - 1 - sy
            }
            return codes[Int(indices[sy * w + sx]) & 3]
        }

        var out = [UInt8]()
        out.reserveCapacity(w * h / 4)

        switch panel.scan {
        case .columnsRTLTopDown:
            guard h % 4 == 0 else { throw PackError.unalignedSize(width: w, height: h) }
            var x = w - 1
            while x >= 0 {
                var y = 0
                while y < h {
                    let b0 = code(x, y) << 6
                    let b1 = code(x, y + 1) << 4
                    let b2 = code(x, y + 2) << 2
                    let b3 = code(x, y + 3)
                    out.append(b0 | b1 | b2 | b3)
                    y += 4
                }
                x -= 1
            }
        case .columnsRTLBottomUp:
            guard h % 4 == 0 else { throw PackError.unalignedSize(width: w, height: h) }
            var x = w - 1
            while x >= 0 {
                var y = h - 1
                while y >= 3 {
                    let b0 = code(x, y) << 6
                    let b1 = code(x, y - 1) << 4
                    let b2 = code(x, y - 2) << 2
                    let b3 = code(x, y - 3)
                    out.append(b0 | b1 | b2 | b3)
                    y -= 4
                }
                x -= 1
            }
        case .rowsMSBFirst:
            guard w % 4 == 0 else { throw PackError.unalignedSize(width: w, height: h) }
            for y in 0..<h {
                var x = 0
                while x < w {
                    let b0 = code(x, y) << 6
                    let b1 = code(x + 1, y) << 4
                    let b2 = code(x + 2, y) << 2
                    let b3 = code(x + 3, y)
                    out.append(b0 | b1 | b2 | b3)
                    x += 4
                }
            }
        case .rowsRTLLSBFirst:
            guard w % 4 == 0 else { throw PackError.unalignedSize(width: w, height: h) }
            for y in 0..<h {
                var x = w - 1
                while x >= 3 {
                    let b0 = code(x, y)
                    let b1 = code(x - 1, y) << 2
                    let b2 = code(x - 2, y) << 4
                    let b3 = code(x - 3, y) << 6
                    out.append(b0 | b1 | b2 | b3)
                    x -= 4
                }
            }
        }
        return Data(out)
    }

    /// A frame filled with one ink.
    static func solid(_ ink: Ink, panel: PanelProfile) -> Data {
        let c = panel.code(for: ink)
        let byte: UInt8 = (c << 6) | (c << 4) | (c << 2) | c
        return Data(repeating: byte, count: panel.frameBytes)
    }
}
