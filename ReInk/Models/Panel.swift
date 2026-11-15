import Foundation

/// How 2-bit pixel codes are laid out in the frame the case expects.
enum ScanOrder: String, Codable, CaseIterable, Identifiable {
    /// Columns from the right edge to the left; each column top→bottom, 4 px
    /// per byte, first pixel in the high bits. Matches the JD79665 552×768
    /// "huawei_2bpp" layout (solar2ain/ink-nfc-fmsc). Default.
    case columnsRTLTopDown
    /// Columns right→left, each column bottom→top (kur0neko/huawei-epd-pn532).
    case columnsRTLBottomUp
    /// Plain rows, left→right, first pixel in the high bits (indexed_2bpp).
    case rowsMSBFirst
    /// Rows read right→left, first pixel in the low bits (Good Display
    /// 4.2″ NFC tags, per niw's protocol notes).
    case rowsRTLLSBFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .columnsRTLTopDown: return "Columns ← · top-down"
        case .columnsRTLBottomUp: return "Columns ← · bottom-up"
        case .rowsMSBFirst: return "Rows → · MSB first"
        case .rowsRTLLSBFirst: return "Rows ← · LSB first"
        }
    }
}

struct PanelProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var width: Int
    var height: Int
    var scan: ScanOrder
    /// Wire code sent for each ink, indexed by `Ink.rawValue` (B, W, Y, R).
    var codes: [UInt8] = [0, 1, 2, 3]
    var rotate180: Bool = false
    var mirror: Bool = false

    var frameBytes: Int { width * height / 4 }
    var aspect: Double { Double(width) / Double(height) }

    func code(for ink: Ink) -> UInt8 {
        codes.indices.contains(ink.rawValue) ? codes[ink.rawValue] & 3 : UInt8(ink.rawValue)
    }

    static let talhfae528 = PanelProfile(id: "bwry-528x768", name: "4.0″ 528×768 BWRY (Talhfae / Keefrash)", width: 528, height: 768, scan: .columnsRTLTopDown)
    static let fmsc552 = PanelProfile(id: "bwry-552x768", name: "3.98″ 552×768 BWRY (FMSC / Huawei-style)", width: 552, height: 768, scan: .columnsRTLTopDown)
    static let case416 = PanelProfile(id: "bwry-240x416", name: "3.7″ 240×416 BWRY (older cases)", width: 240, height: 416, scan: .rowsMSBFirst)
    static let tag400 = PanelProfile(id: "bwry-400x300", name: "4.2″ 400×300 BWRY (NFC tag)", width: 400, height: 300, scan: .rowsRTLLSBFirst)

    static let presets: [PanelProfile] = [talhfae528, fmsc552, case416, tag400]
}

enum CompressionMode: String, Codable, CaseIterable, Identifiable {
    /// F0 D3 with real LZO1X compression (fewest packets).
    case lzo
    /// F0 D3 with literal-only LZO streams (valid, uncompressed).
    case literal
    /// F0 D2 raw upload; only fits frames up to 64,000 bytes.
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lzo: return "LZO (D3)"
        case .literal: return "LZO literal (D3)"
        case .raw: return "Raw (D2)"
        }
    }
}

enum RefreshMode: String, Codable, CaseIterable, Identifiable {
    /// The case answers D4 only after the redraw ends; keeps Core NFC's
    /// connection alive past its 20-second limit.
    case blocking
    /// D4 returns immediately; then poll DE until idle.
    case polling

    var id: String { rawValue }
    var title: String { self == .blocking ? "Wait on case (blocking)" : "Poll status" }
}

enum ReconnectPolicy: String, Codable, CaseIterable, Identifiable {
    case auto
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

struct TransferSettings: Codable, Equatable {
    var compression: CompressionMode = .lzo
    var refreshMode: RefreshMode = .blocking
    /// D4 P1 low bits: panel power-on wait in 100 ms steps.
    var powerOnDelayMs: Int = 500
    /// D4 P1 bit 7.
    var skipPanelDetection: Bool = true
    var reconnect: ReconnectPolicy = .auto
    /// With `.auto`, reconnect before refreshing if the upload took longer.
    var reconnectAfterSeconds: Double = 13
    /// Hex PIN for `00 20 00 01 Lc PIN`. Empty = never send a PIN.
    var pinHex: String = ""
    /// Wait after connecting before the first command, so the case charges.
    var prechargeMs: Int = 150
    var pollIntervalMs: Int = 500
    /// Pause between image packets (some boards need breathing room).
    var packetDelayMs: Int = 0
    /// Unlocks APDUs that rewrite the case's stored driver (DA/DB) in the console.
    var allowDriverWrites: Bool = false

    struct KnownPin: Hashable {
        var name: String
        var hex: String
    }

    static let knownPins: [KnownPin] = [
        KnownPin(name: "None", hex: ""),
        KnownPin(name: "Good Display NFC tags (4 bytes)", hex: "20091210"),
        KnownPin(name: "Huawei FMSC boards (5 bytes)", hex: "5265699919")
    ]
}

struct DeviceSettings: Codable, Equatable {
    var panel: PanelProfile = .talhfae528
    var transfer = TransferSettings()
}
