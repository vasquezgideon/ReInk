import Foundation

/// LZO1X encoder/decoder for the FMSC D3 upload.
///
/// The compressor is adapted from Yoshimasa Niwa's EPaperNFCSwift (MIT),
/// itself based on the kernel's lzo.txt. The decoder follows
/// lzo1x_decompress_safe semantics and is used to verify every block before
/// it is sent; a block that fails the round trip is sent as a literal stream.
/// Both were checked against the lzokay reference on 300+ test vectors.
enum LZO {
    enum DecodeError: Error {
        case inputOverrun
        case lookbehindOverrun
        case lengthMismatch
    }

    // MARK: Compressor

    static func compress(_ data: Data) -> Data {
        let src = [UInt8](data)
        let n = src.count
        var out = [UInt8]()
        out.reserveCapacity(n + n / 16 + 16)

        if n == 0 {
            return Data([0x11, 0x00, 0x00])
        }

        func hash3(_ i: Int) -> Int {
            let v = (UInt32(src[i]) << 16) | (UInt32(src[i + 1]) << 8) | UInt32(src[i + 2])
            return Int((v &* 2_654_435_761) >> 16) & 0xFFFF
        }

        func appendExtension(_ value: Int) {
            var v = value
            while v > 255 {
                out.append(0)
                v -= 255
            }
            out.append(UInt8(v))
        }

        func appendLE16(_ v: Int) {
            out.append(UInt8(v & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF))
        }

        // Requires state 0 before it; leaves state 4.
        func emitLongLiteral(_ start: Int, _ end: Int) {
            let len = end - start
            if len <= 18 {
                out.append(UInt8(len - 3))
            } else {
                out.append(0)
                appendExtension(len - 18)
            }
            out.append(contentsOf: src[start..<end])
        }

        func emitFirstLiteral(_ start: Int, _ end: Int) -> Int {
            let len = end - start
            if len <= 238 {
                out.append(UInt8(17 + len))
                out.append(contentsOf: src[start..<end])
                return len <= 3 ? len : 4
            }
            emitLongLiteral(start, end)
            return 4
        }

        func emitM1(distance: Int, state: Int) {
            let d = distance - 2049
            out.append(UInt8(((d & 0x3) << 2) | state))
            out.append(UInt8((d >> 2) & 0xFF))
        }

        func emitM2(length: Int, distance: Int, state: Int) {
            let d = distance - 1
            let low = (d & 0x7) << 2
            if length <= 4 {
                out.append(UInt8(0x40 | ((length - 3) << 5) | low | state))
            } else {
                out.append(UInt8(0x80 | ((length - 5) << 5) | low | state))
            }
            out.append(UInt8((d >> 3) & 0xFF))
        }

        func emitM3(length: Int, distance: Int, state: Int) {
            if length <= 33 {
                out.append(UInt8(0x20 | (length - 2)))
            } else {
                out.append(0x20)
                appendExtension(length - 33)
            }
            appendLE16(((distance - 1) << 2) | state)
        }

        func emitM4(length: Int, distance: Int, state: Int) {
            let h = distance >= 32768 ? 1 : 0
            if length <= 9 {
                out.append(UInt8(0x10 | (h << 3) | (length - 2)))
            } else {
                out.append(UInt8(0x10 | (h << 3)))
                appendExtension(length - 9)
            }
            let d = distance - 16384 - (h << 14)
            appendLE16((d << 2) | state)
        }

        func emitMatch(length: Int, distance: Int, state: Int, previousState: Int) {
            if previousState == 4 && length == 3 && distance >= 2049 && distance <= 3072 {
                emitM1(distance: distance, state: state)
            } else if length <= 8 && distance <= 2048 {
                emitM2(length: length, distance: distance, state: state)
            } else if distance <= 16384 {
                emitM3(length: length, distance: distance, state: state)
            } else {
                emitM4(length: length, distance: distance, state: state)
            }
        }

        struct Match {
            var start: Int
            var length: Int
            var distance: Int
        }

        let maxDistance = 49_151
        let maxMatch = 512
        var lastPos = [Int](repeating: -1, count: 1 << 16)
        var matches: [Match] = []
        var i = 0
        while i + 2 < n {
            let h = hash3(i)
            let cand = lastPos[h]
            lastPos[h] = i
            var bestLen = 0
            var bestDist = 0
            if cand >= 0 {
                let dist = i - cand
                if dist <= maxDistance, src[cand] == src[i], src[cand + 1] == src[i + 1], src[cand + 2] == src[i + 2] {
                    let limit = min(maxMatch, n - i)
                    var len = 3
                    while len < limit && src[cand + len] == src[i + len] {
                        len += 1
                    }
                    let minUseful = dist <= 2048 ? 3 : 4
                    if len >= minUseful {
                        bestLen = len
                        bestDist = dist
                    }
                }
            }
            if bestLen > 0 {
                matches.append(Match(start: i, length: bestLen, distance: bestDist))
                var k = 1
                while k < bestLen && i + k + 2 < n {
                    lastPos[hash3(i + k)] = i + k
                    k += 1
                }
                i += bestLen
            } else {
                i += 1
            }
        }

        if matches.isEmpty {
            _ = emitFirstLiteral(0, n)
            out.append(contentsOf: [0x11, 0x00, 0x00])
            return Data(out)
        }

        var state = emitFirstLiteral(0, matches[0].start)
        for idx in matches.indices {
            let m = matches[idx]
            let end = m.start + m.length
            let next = idx + 1 < matches.count ? matches[idx + 1].start : n
            let gap = next - end
            if gap <= 3 {
                emitMatch(length: m.length, distance: m.distance, state: gap, previousState: state)
                if gap > 0 {
                    out.append(contentsOf: src[end..<(end + gap)])
                }
                state = gap
            } else {
                emitMatch(length: m.length, distance: m.distance, state: 0, previousState: state)
                emitLongLiteral(end, next)
                state = 4
            }
        }
        out.append(contentsOf: [0x11, 0x00, 0x00])
        return Data(out)
    }

    /// Valid LZO1X stream that stores the data uncompressed.
    static func literal(_ data: Data) -> Data {
        var out = [UInt8]()
        let len = data.count
        if len <= 238 {
            out.append(UInt8(17 + len))
        } else {
            out.append(0)
            var rest = len - 18
            while rest > 255 {
                out.append(0)
                rest -= 255
            }
            out.append(UInt8(rest))
        }
        out.append(contentsOf: data)
        out.append(contentsOf: [0x11, 0x00, 0x00])
        return Data(out)
    }

    // MARK: Decompressor

    static func decompress(_ data: Data, expectedLength: Int) throws -> Data {
        let inp = [UInt8](data)
        let n = inp.count
        var out = [UInt8]()
        out.reserveCapacity(expectedLength)
        var ip = 0

        func need(_ k: Int) throws {
            if ip + k > n { throw DecodeError.inputOverrun }
        }

        func readExtension(_ base: Int) throws -> Int {
            var t = 0
            while true {
                try need(1)
                let b = Int(inp[ip])
                ip += 1
                if b == 0 {
                    t += 255
                    continue
                }
                return base + t + b
            }
        }

        func copyLiteral(_ k: Int) throws {
            try need(k)
            out.append(contentsOf: inp[ip..<(ip + k)])
            ip += k
        }

        func copyMatch(distance: Int, length: Int) throws {
            if distance <= 0 || distance > out.count { throw DecodeError.lookbehindOverrun }
            let start = out.count - distance
            for j in 0..<length {
                out.append(out[start + j])
            }
        }

        try need(1)
        var state = 0
        var t = Int(inp[ip])
        if t > 17 {
            ip += 1
            t -= 17
            try copyLiteral(t)
            state = t >= 4 ? 4 : t
        }

        while true {
            try need(1)
            t = Int(inp[ip])
            ip += 1
            var trailing = 0
            if t >= 64 {
                let length = (t >> 5) + 1
                try need(1)
                let distance = ((Int(inp[ip]) << 3) | ((t >> 2) & 7)) + 1
                ip += 1
                try copyMatch(distance: distance, length: length)
                trailing = t & 3
            } else if t >= 32 {
                var length = t & 31
                length = try (length == 0 ? readExtension(31) + 2 : length + 2)
                try need(2)
                let v = Int(inp[ip]) | (Int(inp[ip + 1]) << 8)
                ip += 2
                try copyMatch(distance: (v >> 2) + 1, length: length)
                trailing = v & 3
            } else if t >= 16 {
                var length = t & 7
                length = try (length == 0 ? readExtension(7) + 2 : length + 2)
                try need(2)
                let v = Int(inp[ip]) | (Int(inp[ip + 1]) << 8)
                ip += 2
                let distance = 16384 + ((t & 8) << 11) + (v >> 2)
                if distance == 16384 { break }
                try copyMatch(distance: distance, length: length)
                trailing = v & 3
            } else {
                if state == 0 {
                    let length = try (t == 0 ? readExtension(15) + 3 : t + 3)
                    try copyLiteral(length)
                    state = 4
                    continue
                } else if state == 4 {
                    try need(1)
                    let distance = (t >> 2) + (Int(inp[ip]) << 2) + 2049
                    ip += 1
                    try copyMatch(distance: distance, length: 3)
                } else {
                    try need(1)
                    let distance = (t >> 2) + (Int(inp[ip]) << 2) + 1
                    ip += 1
                    try copyMatch(distance: distance, length: 2)
                }
                trailing = t & 3
            }
            try copyLiteral(trailing)
            state = trailing
        }
        guard out.count == expectedLength else { throw DecodeError.lengthMismatch }
        return Data(out)
    }
}
