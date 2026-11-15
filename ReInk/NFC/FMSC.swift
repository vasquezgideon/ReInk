import Foundation

/// The FMSC (Fudan FM1280-family) passive e-paper command set, as documented
/// by Good Display and reverse engineered by niw, alt-core, solar2ain,
/// kur0neko and CompassSecurity. ISO 14443-4 / ISO 7816 APDUs.
enum FMSC {
    static let readInfo = Data([0x00, 0xD1, 0x00, 0x00, 0x00])
    /// Reads a user-area prefix; answers 6985 when a PIN is required.
    static let checkAccess = Data([0xF0, 0xD8, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x0E])
    /// Busy flag: data byte 01 = refreshing, 00 = idle.
    static let readStatus = Data([0xF0, 0xDE, 0x00, 0x00, 0x01])

    static let blockSize = 2000
    static let packetSize = 250

    static func verifyPin(_ pin: Data) -> Data {
        var d = Data([0x00, 0x20, 0x00, 0x01, UInt8(pin.count)])
        d.append(pin)
        return d
    }

    /// `F0 D4 P1 P2 00`. P1 bit 7 skips panel detection, low 7 bits are the
    /// power-on wait in 100 ms units. P2 00 blocks until the redraw ends,
    /// P2 80 returns at once.
    static func refresh(powerOnDelayMs: Int, skipDetection: Bool, blocking: Bool) -> Data {
        let steps = UInt8(min(max(powerOnDelayMs / 100, 0), 0x7F))
        let p1: UInt8 = (skipDetection ? 0x80 : 0x00) | steps
        let p2: UInt8 = blocking ? 0x00 : 0x80
        return Data([0xF0, 0xD4, p1, p2, 0x00])
    }

    enum PacketError: LocalizedError {
        case tooLargeForRaw(Int)
        case tooManyBlocks(Int)

        var errorDescription: String? {
            switch self {
            case let .tooLargeForRaw(n):
                return "Raw (D2) upload holds at most 64,000 bytes; this frame is \(n). Use LZO."
            case let .tooManyBlocks(n):
                return "Frame needs \(n) blocks; the protocol allows 256."
            }
        }
    }

    struct UploadPlan {
        var packets: [Data]
        var rawBytes: Int
        var wireBytes: Int
        var literalFallbackBlocks: Int
    }

    /// Splits a packed frame into upload APDUs.
    static func uploadPlan(frame: Data, mode: CompressionMode, slot: UInt8 = 0) throws -> UploadPlan {
        let bytes = [UInt8](frame)
        var packets: [Data] = []
        var wire = 0
        var fallbacks = 0

        switch mode {
        case .raw:
            guard bytes.count <= 256 * packetSize else { throw PacketError.tooLargeForRaw(bytes.count) }
            var offset = 0
            var index = 0
            while offset < bytes.count {
                let end = min(offset + packetSize, bytes.count)
                var p = Data([0xF0, 0xD2, slot, UInt8(index), UInt8(end - offset)])
                p.append(contentsOf: bytes[offset..<end])
                packets.append(p)
                wire += end - offset
                offset = end
                index += 1
            }
        case .lzo, .literal:
            let blockCount = (bytes.count + blockSize - 1) / blockSize
            guard blockCount <= 256 else { throw PacketError.tooManyBlocks(blockCount) }
            for block in 0..<blockCount {
                let start = block * blockSize
                let end = min(start + blockSize, bytes.count)
                let raw = Data(bytes[start..<end])
                var stream: Data
                if mode == .lzo {
                    stream = LZO.compress(raw)
                    let roundTrip = try? LZO.decompress(stream, expectedLength: raw.count)
                    if roundTrip != raw {
                        stream = LZO.literal(raw)
                        fallbacks += 1
                    }
                } else {
                    stream = LZO.literal(raw)
                }
                let s = [UInt8](stream)
                var sub = 0
                var o = 0
                while o < s.count {
                    let e = min(o + packetSize, s.count)
                    let last: UInt8 = e == s.count ? 1 : 0
                    var p = Data([0xF0, 0xD3, slot, last, UInt8(e - o + 2), UInt8(block), UInt8(sub)])
                    p.append(contentsOf: s[o..<e])
                    packets.append(p)
                    o = e
                    sub += 1
                }
                wire += s.count
            }
        }
        return UploadPlan(packets: packets, rawBytes: bytes.count, wireBytes: wire, literalFallbackBlocks: fallbacks)
    }

    static let statusWords: [UInt16: String] = [
        0x9000: "OK",
        0x6401: "Execution incomplete / card not ready",
        0x6449: "Config EEPROM error",
        0x6450: "Panel init data error",
        0x6451: "Panel init contains a bad tag",
        0x6452: "Panel init content error",
        0x6453: "Panel init sequence incomplete",
        0x6454: "Panel refresh failed",
        0x6455: "Panel reset failed",
        0x646A: "Too many TLVs",
        0x6501: "NVM write interrupted",
        0x6502: "Low voltage stopped NVM write",
        0x6503: "Invalid NVM address",
        0x6506: "NVM permission error",
        0x6508: "NVM length error",
        0x6509: "Bad command parameter",
        0x650A: "Execution conflict",
        0x650F: "No execution permission",
        0x6700: "Wrong length (Lc/Le)",
        0x6781: "Packet total length error",
        0x68C6: "Panel reset failed or no panel",
        0x68CA: "Low voltage warning",
        0x68CB: "Refresh timeout warning",
        0x6982: "Security status not satisfied",
        0x6985: "Conditions not satisfied (PIN needed?)",
        0x6986: "Panel reset failed / not seated",
        0x698A: "Low voltage warning",
        0x6991: "Compression not initialized",
        0x6992: "Decompression failed",
        0x6993: "Decompressed length wrong",
        0x6994: "Compressed length wrong",
        0x6995: "Image packet index mismatch",
        0x6A80: "Bad data parameter",
        0x6A82: "File / application not found",
        0x6A86: "Bad P1/P2",
        0x6A96: "Image slot / format mismatch",
        0x6D00: "Instruction not supported",
        0x6E00: "Class not supported"
    ]

    static func describe(_ sw: UInt16) -> String {
        statusWords[sw] ?? "Unknown status"
    }

    /// Console guard: instructions that overwrite the stored panel driver or PIN.
    static func isDangerous(_ apdu: Data) -> Bool {
        guard apdu.count >= 2 else { return false }
        let b = [UInt8](apdu.prefix(2))
        if b[0] == 0xF0 && (b[1] == 0xDA || b[1] == 0xDB) { return true }
        if b[1] == 0x24 || b[1] == 0x2C { return true }
        return false
    }
}

struct APDUResponse {
    var data: Data
    var sw: UInt16

    var ok: Bool { sw == 0x9000 }
    var swHex: String { String(format: "%04X", sw) }
}

/// Parsed `00 D1` reply. Every field is kept raw; derived values are best-effort.
struct DeviceInfo: Equatable {
    struct Field: Equatable, Identifiable {
        var tag: UInt8
        var value: Data
        var id: UInt8 { tag }
    }

    var fields: [Field]

    static func parse(_ data: Data) -> DeviceInfo {
        let b = [UInt8](data)
        var fields: [Field] = []
        var i = 0
        while i + 2 <= b.count {
            let tag = b[i]
            let len = Int(b[i + 1])
            i += 2
            guard i + len <= b.count else { break }
            fields.append(Field(tag: tag, value: Data(b[i..<(i + len)])))
            i += len
        }
        return DeviceInfo(fields: fields)
    }

    func value(_ tag: UInt8) -> Data? {
        fields.first(where: { $0.tag == tag })?.value
    }

    /// (height, width) words from A0, raw.
    var rawGeometry: (height: Int, width: Int)? {
        guard let a0 = value(0xA0), a0.count >= 7 else { return nil }
        let b = [UInt8](a0)
        let h = (Int(b[3]) << 8) | Int(b[4])
        let w = (Int(b[5]) << 8) | Int(b[6])
        return (h, w)
    }

    var colors: Int? {
        if let b1 = value(0xB1), let c = b1.first { return Int(c) }
        if let a0 = value(0xA0), a0.count >= 2 {
            let code = [UInt8](a0)[1]
            return code == 0x07 ? 4 : 2
        }
        return nil
    }

    var firmware: Int? {
        value(0xB2)?.first.map { Int($0) }
    }

    var uid: Data? { value(0xC1) }

    var supportsCompression: Bool? {
        guard let c0 = value(0xC0), c0.count == 4 else { return nil }
        return [UInt8](c0)[3] != 0
    }

    var name: String? {
        guard let c0 = value(0xC0), c0.count > 4 else { return nil }
        let s = String(decoding: c0, as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        return s.isEmpty ? nil : s
    }

    /// Panel preset whose size matches the reported geometry, trying the
    /// common encodings (height in bits for 2bpp, swapped axes).
    func matchingPreset(_ presets: [PanelProfile] = PanelProfile.presets) -> PanelProfile? {
        guard let g = rawGeometry else { return nil }
        var candidates: [(Int, Int)] = [(g.width, g.height), (g.height, g.width)]
        if g.height % 2 == 0 {
            candidates.append((g.width, g.height / 2))
            candidates.append((g.height / 2, g.width))
        }
        for (w, h) in candidates {
            if let p = presets.first(where: { $0.width == w && $0.height == h }) { return p }
        }
        return nil
    }

    var summary: String {
        var parts: [String] = []
        if let g = rawGeometry { parts.append("A0 geometry \(g.width)×\(g.height)") }
        if let c = colors { parts.append("\(c) colors") }
        if let f = firmware { parts.append("fw \(f)") }
        if let c = supportsCompression { parts.append(c ? "LZO ok" : "no LZO") }
        if let u = uid { parts.append("UID \(u.hex)") }
        return parts.isEmpty ? "No recognizable fields" : parts.joined(separator: " · ")
    }
}

extension Data {
    var hex: String {
        map { String(format: "%02X", $0) }.joined()
    }

    var spacedHex: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Parses hex with optional spaces/colons. Nil on odd length or bad digits.
    init?(hexString: String) {
        let clean = hexString.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard clean.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let v = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(v)
            index = next
        }
        self.init(bytes)
    }
}
