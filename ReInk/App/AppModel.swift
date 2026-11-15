import Foundation
import Observation
import SwiftUI
import UIKit

enum EditorMode: String, Codable, CaseIterable, Identifiable {
    case simple
    case advanced

    var id: String { rawValue }
    var title: String { self == .simple ? "Simple" : "Advanced" }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let text: String
}

@MainActor
@Observable
final class AppModel {
    // MARK: Editor

    private(set) var sourceImage: CGImage? = nil
    var settings: RenderSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleRender()
            persist(settings, key: Keys.settings)
        }
    }
    var mode: EditorMode {
        didSet { persist(mode, key: Keys.mode) }
    }
    /// The look last applied from the chips, to show "modified" state.
    var selectedLookID: UUID? {
        didSet { persist(selectedLookID, key: Keys.selectedLook) }
    }
    private(set) var render: RenderResult? = nil
    private(set) var isRendering = false
    /// Library item being edited (nil for a fresh photo).
    var currentItemID: UUID? = nil

    // MARK: Looks

    var customLooks: [Look] {
        didSet { persist(customLooks, key: Keys.looks) }
    }

    var allLooks: [Look] { Look.builtIns + customLooks }

    var selectedLook: Look? {
        allLooks.first { $0.id == selectedLookID }
    }

    var lookIsModified: Bool {
        guard let look = selectedLook else { return true }
        return look.settings != settings.look
    }

    // MARK: Device

    var device: DeviceSettings {
        didSet {
            guard device != oldValue else { return }
            persist(device, key: Keys.device)
            if device.panel.width != oldValue.panel.width || device.panel.height != oldValue.panel.height {
                scheduleRender()
            }
        }
    }
    private(set) var lastInfo: DeviceInfo? = nil

    // MARK: NFC state

    private(set) var nfcBusy = false
    private(set) var nfcProgress: Double = 0
    private(set) var nfcStatus = ""
    private(set) var lastResult: NFCJobResult? = nil
    private(set) var log: [LogEntry] = []
    @ObservationIgnored private var writer: CaseWriter? = nil

    let library = LibraryStore()

    // MARK: Render scheduling

    @ObservationIgnored private var renderInFlight = false
    @ObservationIgnored private var renderDirty = false

    private enum Keys {
        static let settings = "reink.settings"
        static let mode = "reink.mode"
        static let looks = "reink.looks"
        static let device = "reink.device"
        static let selectedLook = "reink.selectedLook"
    }

    init() {
        settings = Self.restore(RenderSettings.self, key: Keys.settings) ?? RenderSettings(look: Look.builtIns[0].settings)
        mode = Self.restore(EditorMode.self, key: Keys.mode) ?? .simple
        customLooks = Self.restore([Look].self, key: Keys.looks) ?? []
        device = Self.restore(DeviceSettings.self, key: Keys.device) ?? DeviceSettings()
        selectedLookID = Self.restore(UUID.self, key: Keys.selectedLook) ?? Look.builtIns[0].id
    }

    // MARK: Persistence

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func restore<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Images

    func loadImage(data: Data) async {
        let image = await Background.run {
            RenderEngine.loadSource(data: data)
        }
        guard let image else {
            appendLog(.error, "Couldn't read that image.")
            return
        }
        sourceImage = image
        currentItemID = nil
        var s = settings
        s.transform = ImageTransform()
        settings = s
        scheduleRender()
    }

    func open(_ item: LibraryItem) {
        guard let image = library.loadSource(item.id) else {
            appendLog(.error, "The source photo for “\(item.name)” is missing.")
            return
        }
        sourceImage = image
        currentItemID = item.id
        settings = item.settings
        selectedLookID = nil
        scheduleRender()
    }

    func scheduleRender() {
        guard sourceImage != nil else {
            render = nil
            return
        }
        renderDirty = true
        if !renderInFlight { startRender() }
    }

    private func startRender() {
        guard let source = sourceImage else { return }
        renderDirty = false
        renderInFlight = true
        isRendering = true
        let s = settings
        let panel = device.panel
        let src = UncheckedBox(value: source)
        Task {
            let result = await Background.run {
                RenderEngine.render(source: src.value, settings: s, panel: panel)
            }
            if let result { self.render = result }
            self.renderInFlight = false
            if self.renderDirty {
                self.startRender()
            } else {
                self.isRendering = false
            }
        }
    }

    // MARK: Looks

    func apply(_ look: Look) {
        var s = settings
        s.look = look.settings
        settings = s
        selectedLookID = look.id
    }

    func saveCurrentAsLook(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let look = Look(name: trimmed.isEmpty ? "My look" : trimmed, symbol: "slider.horizontal.3", settings: settings.look)
        customLooks.append(look)
        selectedLookID = look.id
    }

    func updateSelectedLook() {
        guard let id = selectedLookID, let i = customLooks.firstIndex(where: { $0.id == id }) else { return }
        customLooks[i].settings = settings.look
    }

    func overwriteLook(_ look: Look) {
        guard let i = customLooks.firstIndex(where: { $0.id == look.id }) else { return }
        customLooks[i].settings = settings.look
        selectedLookID = look.id
    }

    func deleteLook(_ look: Look) {
        customLooks.removeAll { $0.id == look.id }
        if selectedLookID == look.id { selectedLookID = nil }
    }

    func renameLook(_ look: Look, to name: String) {
        guard let i = customLooks.firstIndex(where: { $0.id == look.id }), !name.isEmpty else { return }
        customLooks[i].name = name
    }

    func revertToLook() {
        guard let look = selectedLook else { return }
        apply(look)
    }

    // MARK: Library

    func saveToLibrary(name: String?) {
        guard let render, let source = sourceImage else { return }
        currentItemID = library.upsert(id: currentItemID, name: name, settings: settings, panelID: device.panel.id,
                                       source: source, preview: render.preview, markSent: false, markSaved: true)
    }

    var currentIsSaved: Bool {
        library.item(currentItemID)?.isSaved ?? false
    }

    // MARK: NFC jobs

    func sendCurrent() {
        guard let render else { return }
        guard render.width == device.panel.width, render.height == device.panel.height else {
            scheduleRender()
            return
        }
        do {
            let frame = try FramePacker.pack(indices: render.indices, panel: device.panel)
            let preview = render.preview
            let source = sourceImage
            let s = settings
            run(.sendFrame(frame, label: "Image")) { [weak self] result in
                guard let self, result.success else { return }
                self.currentItemID = self.library.upsert(id: self.currentItemID, name: nil, settings: s,
                                                         panelID: self.device.panel.id, source: source,
                                                         preview: preview, markSent: true, markSaved: false)
            }
        } catch {
            appendLog(.error, error.localizedDescription)
        }
    }

    func send(item: LibraryItem) {
        guard let source = library.loadSource(item.id) else {
            appendLog(.error, "The source photo for “\(item.name)” is missing.")
            return
        }
        let panel = device.panel
        let s = item.settings
        nfcStatus = "Preparing…"
        let src = UncheckedBox(value: source)
        Task {
            let result = await Background.run {
                RenderEngine.render(source: src.value, settings: s, panel: panel)
            }
            guard let result, let frame = try? FramePacker.pack(indices: result.indices, panel: panel) else {
                self.appendLog(.error, "Couldn't render “\(item.name)”.")
                return
            }
            self.run(.sendFrame(frame, label: item.name)) { [weak self] r in
                guard let self, r.success else { return }
                self.library.upsert(id: item.id, name: nil, settings: s, panelID: panel.id, source: nil,
                                    preview: result.preview, markSent: true, markSaved: false)
            }
        }
    }

    func sendTestPattern() {
        let panel = device.panel
        Task {
            let indices = await Background.run {
                TestPattern.indices(width: panel.width, height: panel.height)
            }
            do {
                let frame = try FramePacker.pack(indices: indices, panel: panel)
                self.run(.sendFrame(frame, label: "Test pattern"))
            } catch {
                self.appendLog(.error, error.localizedDescription)
            }
        }
    }

    func sendSolid(_ ink: Ink) {
        run(.sendFrame(FramePacker.solid(ink, panel: device.panel), label: "Solid \(ink.name.lowercased())"))
    }

    func probe() {
        run(.probe) { [weak self] result in
            guard let self, let info = result.info else { return }
            self.lastInfo = info
        }
    }

    func refreshStored() {
        run(.refreshStored)
    }

    func sendConsole(_ text: String) {
        var commands: [Data] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }
            guard let d = Data(hexString: trimmed), d.count >= 4 else {
                appendLog(.error, "Not a valid APDU: \(trimmed)")
                return
            }
            commands.append(d)
        }
        guard !commands.isEmpty else { return }
        run(.console(commands))
    }

    func cancelNFC() {
        writer?.cancel()
    }

    private func run(_ job: NFCJob, onFinish: ((NFCJobResult) -> Void)? = nil) {
        guard !nfcBusy else { return }
        nfcBusy = true
        nfcProgress = 0
        nfcStatus = "Hold the case to your iPhone…"
        let w = CaseWriter(
            job: job,
            settings: device,
            log: { [weak self] level, text in
                self?.appendLog(level, text)
            },
            progress: { [weak self] value, text in
                self?.nfcProgress = value
                self?.nfcStatus = text
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.nfcBusy = false
                self.lastResult = result
                self.nfcStatus = result.message
                self.nfcProgress = result.success ? 1 : 0
                if let info = result.info { self.lastInfo = info }
                self.writer = nil
                onFinish?(result)
            })
        writer = w
        w.start()
    }

    func appendLog(_ level: LogLevel, _ text: String) {
        log.append(LogEntry(date: Date(), level: level, text: text))
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    func clearLog() {
        log.removeAll()
    }

    var logText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        var lines = ["ReInk log · panel \(device.panel.name) · scan \(device.panel.scan.rawValue)"]
        if let info = lastInfo {
            lines.append("D1: " + info.fields.map { String(format: "%02X", $0.tag) + "=" + $0.value.hex }.joined(separator: " "))
        }
        for e in log {
            lines.append("\(f.string(from: e.date)) [\(e.level.rawValue)] \(e.text)")
        }
        return lines.joined(separator: "\n")
    }
}
