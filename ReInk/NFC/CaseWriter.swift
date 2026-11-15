import CoreNFC
import Foundation

enum NFCJob {
    /// Upload a packed frame and refresh.
    case sendFrame(Data, label: String)
    /// Read D1/D8/DE only. Never writes.
    case probe
    /// Redraw whatever image is already stored on the case.
    case refreshStored
    /// Raw APDUs from the console.
    case console([Data])

    var needsRefresh: Bool {
        switch self {
        case .sendFrame, .refreshStored: return true
        case .probe, .console: return false
        }
    }
}

enum LogLevel: String {
    case info, tx, rx, warn, error, ok
}

struct NFCJobResult {
    var success: Bool
    var message: String
    var info: DeviceInfo?
    var seconds: Double
}

enum WriterError: LocalizedError {
    case unsupportedTag(String)
    case differentTag
    case badAPDU(String)
    case status(String, UInt16)
    case needsPin
    case pinRejected(UInt16)
    case refreshTimedOut
    case blockedCommand

    var errorDescription: String? {
        switch self {
        case let .unsupportedTag(kind):
            return "Found a \(kind) tag, not an ISO-DEP e-ink case."
        case .differentTag:
            return "A different tag answered on reconnect. Keep only the case near the phone."
        case let .badAPDU(s):
            return "Malformed APDU: \(s)"
        case let .status(step, sw):
            return "\(step) failed: SW \(String(format: "%04X", sw)) – \(FMSC.describe(sw))"
        case .needsPin:
            return "The case asked for a PIN (6985). Pick a PIN preset under Case → Transfer, then try again."
        case let .pinRejected(sw):
            return "PIN rejected: SW \(String(format: "%04X", sw)). Don't retry blindly; PINs can lock."
        case .refreshTimedOut:
            return "The case never reported the redraw finishing."
        case .blockedCommand:
            return "That APDU rewrites the case's driver or PIN. Unlock it under Case → Advanced first."
        }
    }
}

/// Wraps the two Core NFC tag kinds an FMSC board can surface as.
enum CaseTransport {
    case iso7816(any NFCISO7816Tag)
    case miFare(any NFCMiFareTag)

    var identifier: Data {
        switch self {
        case let .iso7816(t): return t.identifier
        case let .miFare(t): return t.identifier
        }
    }

    var kind: String {
        switch self {
        case let .iso7816(t): return "ISO 7816 (AID \(t.initialSelectedAID))"
        case .miFare: return "ISO-DEP via MIFARE path"
        }
    }

    func send(_ raw: Data) async throws -> APDUResponse {
        guard let apdu = NFCISO7816APDU(data: raw) else {
            throw WriterError.badAPDU(raw.spacedHex)
        }
        switch self {
        case let .iso7816(t):
            let (data, sw1, sw2) = try await t.sendCommand(apdu: apdu)
            return APDUResponse(data: data, sw: (UInt16(sw1) << 8) | UInt16(sw2))
        case let .miFare(t):
            let (data, sw1, sw2) = try await t.sendMiFareISO7816Command(apdu)
            return APDUResponse(data: data, sw: (UInt16(sw1) << 8) | UInt16(sw2))
        }
    }
}

/// Runs one NFC job against the case.
///
/// Core NFC drops a tag connection about 20 s after `connect(to:)`. Upload
/// and refresh are therefore split into two phases: if the upload ran long,
/// the session restarts polling, reconnects to the same tag and only then
/// sends the (blocking) refresh, which the case answers once the redraw ends.
final class CaseWriter: NSObject, NFCTagReaderSessionDelegate {
    typealias LogSink = @MainActor (LogLevel, String) -> Void
    typealias ProgressSink = @MainActor (Double, String) -> Void
    typealias CompletionSink = @MainActor (NFCJobResult) -> Void

    private enum Phase {
        case main
        case refresh
    }

    private let job: NFCJob
    private let settings: DeviceSettings
    private let logSink: LogSink
    private let progressSink: ProgressSink
    private let completion: CompletionSink

    private var session: NFCTagReaderSession?
    private var phase: Phase = .main
    private var tagID: Data?
    private var finished = false
    private var connectedAt = Date()
    private let startedAt = Date()
    private var info: DeviceInfo?
    private var plan: FMSC.UploadPlan?
    private var busy = false

    init(job: NFCJob,
         settings: DeviceSettings,
         log: @escaping LogSink,
         progress: @escaping ProgressSink,
         completion: @escaping CompletionSink) {
        self.job = job
        self.settings = settings
        self.logSink = log
        self.progressSink = progress
        self.completion = completion
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        guard NFCTagReaderSession.readingAvailable else {
            finish(success: false, message: "NFC tag reading isn't available. The build needs the NFC Tag Reading entitlement, and the phone must support NFC.")
            return
        }
        if case let .sendFrame(frame, label) = job {
            do {
                let p = try FMSC.uploadPlan(frame: frame, mode: settings.transfer.compression)
                plan = p
                log(.info, "\(label): \(p.rawBytes) B frame → \(p.wireBytes) B on the wire in \(p.packets.count) packets (\(settings.transfer.compression.title))")
                if p.literalFallbackBlocks > 0 {
                    log(.warn, "\(p.literalFallbackBlocks) block(s) failed the LZO self-check and were sent as literals")
                }
            } catch {
                finish(success: false, message: error.localizedDescription)
                return
            }
        }
        guard let s = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil) else {
            finish(success: false, message: "Couldn't start an NFC session.")
            return
        }
        session = s
        s.alertMessage = "Keep the case on your iPhone…"
        s.begin()
        log(.info, "NFC session started")
    }

    func cancel() {
        session?.invalidate(errorMessage: "Cancelled")
    }

    // MARK: NFCTagReaderSessionDelegate

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if finished { return }
        let code = (error as? NFCReaderError)?.code
        if code == .readerSessionInvalidationErrorUserCanceled {
            finish(success: false, message: "Cancelled.")
        } else if code == .readerSessionInvalidationErrorSessionTimeout {
            finish(success: false, message: "NFC session timed out.")
        } else {
            finish(success: false, message: error.localizedDescription)
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task {
            await self.handle(session: session, tags: tags)
        }
    }

    // MARK: Flow

    private func handle(session: NFCTagReaderSession, tags: [NFCTag]) async {
        guard !finished, !busy else { return }
        busy = true
        defer { busy = false }

        guard let tag = tags.first else {
            session.restartPolling()
            return
        }
        if tags.count > 1 {
            session.alertMessage = "More than one tag found. Remove other cards."
            session.restartPolling()
            return
        }

        let transport: CaseTransport
        switch tag {
        case let .iso7816(t):
            transport = .iso7816(t)
        case let .miFare(t):
            transport = .miFare(t)
        case .feliCa:
            fail(session, WriterError.unsupportedTag("FeliCa"))
            return
        case .iso15693:
            fail(session, WriterError.unsupportedTag("ISO 15693"))
            return
        @unknown default:
            fail(session, WriterError.unsupportedTag("unknown"))
            return
        }

        if let tagID, tagID != transport.identifier {
            fail(session, WriterError.differentTag)
            return
        }
        tagID = transport.identifier

        do {
            try await session.connect(to: tag)
            connectedAt = Date()
            log(.info, "Connected: \(transport.kind), UID \(transport.identifier.hex)")
            try await sleep(ms: settings.transfer.prechargeMs)
            switch phase {
            case .main:
                try await runMain(session: session, transport: transport)
            case .refresh:
                try await runRefresh(session: session, transport: transport)
            }
        } catch {
            fail(session, error)
        }
    }

    private func runMain(session: NFCTagReaderSession, transport: CaseTransport) async throws {
        // 1. Identify.
        let d1 = try await exchange(transport, FMSC.readInfo, "D1 info")
        if d1.ok {
            let parsed = DeviceInfo.parse(d1.data)
            info = parsed
            log(.ok, "Case: \(parsed.summary)")
            if let preset = parsed.matchingPreset(), preset.width != settings.panel.width || preset.height != settings.panel.height {
                log(.warn, "Case reports \(preset.width)×\(preset.height) but the selected profile is \(settings.panel.width)×\(settings.panel.height)")
            }
        } else {
            log(.warn, "D1 not supported (\(d1.swHex)); continuing")
        }

        // 2. Access / PIN.
        let d8 = try await exchange(transport, FMSC.checkAccess, "D8 access")
        if d8.sw == 0x6985 {
            let pinHex = settings.transfer.pinHex
            guard !pinHex.isEmpty, let pin = Data(hexString: pinHex) else {
                if case .probe = job {
                    log(.warn, "Case answers 6985: writing will need a PIN")
                    succeed(session, "Read case info (PIN required to write).")
                    return
                }
                throw WriterError.needsPin
            }
            let auth = try await exchange(transport, FMSC.verifyPin(pin), "PIN")
            guard auth.ok else { throw WriterError.pinRejected(auth.sw) }
            let again = try await exchange(transport, FMSC.checkAccess, "D8 access")
            if !again.ok { log(.warn, "D8 still answers \(again.swHex) after PIN") }
        } else if !d8.ok {
            log(.warn, "D8 answered \(d8.swHex) (\(FMSC.describe(d8.sw))); continuing")
        }

        // 3. Job.
        switch job {
        case .probe:
            let de = try await exchange(transport, FMSC.readStatus, "DE status")
            if de.ok, let b = de.data.first {
                log(.info, "Panel is \(b == 0 ? "idle" : "busy (\(b))")")
            }
            succeed(session, "Read case info.")
            return
        case let .console(commands):
            for (i, cmd) in commands.enumerated() {
                if FMSC.isDangerous(cmd) && !settings.transfer.allowDriverWrites {
                    throw WriterError.blockedCommand
                }
                _ = try await exchange(transport, cmd, "Console \(i + 1)", verbose: true)
            }
            succeed(session, "Sent \(commands.count) APDU(s).")
            return
        case .refreshStored:
            break
        case .sendFrame:
            try await upload(session: session, transport: transport)
        }

        // 4. Refresh, maybe after reconnecting.
        let elapsed = Date().timeIntervalSince(connectedAt)
        let policy = settings.transfer.reconnect
        let reconnect = policy == .always || (policy == .auto && elapsed > settings.transfer.reconnectAfterSeconds)
        if reconnect {
            log(.info, String(format: "Upload took %.1f s; reconnecting before refresh", elapsed))
            phase = .refresh
            session.alertMessage = "Image sent. Reconnecting to refresh…"
            progress(0.98, "Reconnecting…")
            session.restartPolling()
            return
        }
        try await runRefresh(session: session, transport: transport)
    }

    private func upload(session: NFCTagReaderSession, transport: CaseTransport) async throws {
        guard let plan else { return }
        let total = plan.packets.count
        var lastShown = -1
        for (i, packet) in plan.packets.enumerated() {
            let r = try await exchange(transport, packet, "Packet \(i + 1)/\(total)", quiet: true)
            if !r.ok {
                log(.error, "Packet \(i + 1)/\(total) → \(r.swHex) \(FMSC.describe(r.sw))")
                throw WriterError.status("Image upload", r.sw)
            }
            let pct = Int(Double(i + 1) / Double(total) * 100)
            if pct != lastShown && (pct % 5 == 0 || i + 1 == total) {
                lastShown = pct
                session.alertMessage = "Sending image… \(pct)%"
                progress(Double(i + 1) / Double(total) * 0.85, "Sending \(pct)%")
            }
            if settings.transfer.packetDelayMs > 0 {
                try await sleep(ms: settings.transfer.packetDelayMs)
            }
        }
        log(.ok, String(format: "Uploaded %d packets in %.1f s", total, Date().timeIntervalSince(connectedAt)))
    }

    private func runRefresh(session: NFCTagReaderSession, transport: CaseTransport) async throws {
        let t = settings.transfer
        let blocking = t.refreshMode == .blocking
        session.alertMessage = "Redrawing the case… keep still"
        progress(0.9, "Redrawing…")
        let cmd = FMSC.refresh(powerOnDelayMs: t.powerOnDelayMs, skipDetection: t.skipPanelDetection, blocking: blocking)
        var r = try await exchange(transport, cmd, "D4 refresh")
        if r.sw == 0x68C6 {
            log(.warn, "68C6 (panel reset failed); retrying once")
            r = try await exchange(transport, cmd, "D4 refresh")
        }
        switch r.sw {
        case 0x9000:
            break
        case 0x68CA, 0x698A:
            log(.warn, "Case reported low voltage during refresh; check the result")
        default:
            throw WriterError.status("Refresh", r.sw)
        }

        if !blocking {
            try await pollUntilIdle(transport: transport)
        }
        succeed(session, "Case updated.")
    }

    private func pollUntilIdle(transport: CaseTransport) async throws {
        let t = settings.transfer
        let deadline = Date().addingTimeInterval(45)
        var seenBusy = false
        var idleCount = 0
        let started = Date()
        while Date() < deadline {
            try await sleep(ms: max(100, t.pollIntervalMs))
            let r = try await exchange(transport, FMSC.readStatus, "DE status", quiet: true)
            guard r.ok, let b = r.data.first else {
                log(.warn, "DE → \(r.swHex)")
                continue
            }
            if b != 0 {
                seenBusy = true
                idleCount = 0
            } else {
                idleCount += 1
                if seenBusy && idleCount >= 2 { return }
                if !seenBusy && idleCount >= 4 && Date().timeIntervalSince(started) > 3 {
                    log(.warn, "Never saw BUSY; the redraw may not have started. Check the case.")
                    return
                }
            }
        }
        throw WriterError.refreshTimedOut
    }

    // MARK: Helpers

    private func exchange(_ transport: CaseTransport, _ apdu: Data, _ label: String, quiet: Bool = false, verbose: Bool = false) async throws -> APDUResponse {
        if !quiet {
            log(.tx, "\(label) → \(Self.short(apdu))")
        }
        let r = try await transport.send(apdu)
        if !quiet || !r.ok {
            let body = r.data.isEmpty ? "" : " " + (verbose ? r.data.spacedHex : Self.short(r.data))
            log(r.ok ? .rx : .warn, "\(label) ← \(r.swHex)\(body)")
        }
        return r
    }

    private static func short(_ d: Data) -> String {
        if d.count <= 24 { return d.spacedHex }
        return d.prefix(16).spacedHex + " … (\(d.count) B)"
    }

    private func sleep(ms: Int) async throws {
        guard ms > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    private func log(_ level: LogLevel, _ text: String) {
        let sink = logSink
        DispatchQueue.main.async { MainActor.assumeIsolated { sink(level, text) } }
    }

    private func progress(_ value: Double, _ text: String) {
        let sink = progressSink
        DispatchQueue.main.async { MainActor.assumeIsolated { sink(value, text) } }
    }

    private func succeed(_ session: NFCTagReaderSession, _ message: String) {
        session.alertMessage = message
        progress(1, message)
        finish(success: true, message: message)
        session.invalidate()
    }

    private func fail(_ session: NFCTagReaderSession, _ error: Error) {
        let message: String
        if let nfc = error as? NFCReaderError {
            switch nfc.code {
            case .readerTransceiveErrorTagConnectionLost:
                message = "Lost the case mid-transfer. Keep the phone still and try again."
            case .readerTransceiveErrorTagResponseError:
                message = "The case returned a malformed response."
            default:
                message = nfc.localizedDescription
            }
        } else {
            message = error.localizedDescription
        }
        log(.error, message)
        finish(success: false, message: message)
        session.invalidate(errorMessage: message)
    }

    private func finish(success: Bool, message: String) {
        guard !finished else { return }
        finished = true
        if success { log(.ok, message) }
        let result = NFCJobResult(success: success, message: message, info: info, seconds: Date().timeIntervalSince(startedAt))
        let done = completion
        DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
    }
}
