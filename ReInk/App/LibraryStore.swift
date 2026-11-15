import Foundation
import Observation
import UIKit

struct LibraryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    var lastSent: Date?
    var sendCount: Int = 0
    var settings: RenderSettings
    var panelID: String
    var isSaved: Bool = false
    var isRecent: Bool = false
}

/// Recents (everything you've sent) and Saved (designs you starred).
/// Each item keeps its source photo and settings so it reopens fully editable.
@MainActor
@Observable
final class LibraryStore {
    private(set) var items: [LibraryItem] = []
    static let recentLimit = 30

    private let root: URL
    private let thumbCache = NSCache<NSString, UIImage>()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent("ReInk/Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    var recents: [LibraryItem] {
        items.filter(\.isRecent).sorted { ($0.lastSent ?? $0.created) > ($1.lastSent ?? $1.created) }
    }

    var saved: [LibraryItem] {
        items.filter(\.isSaved).sorted { $0.created > $1.created }
    }

    func item(_ id: UUID?) -> LibraryItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: Files

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func sourceURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("source.jpg") }
    func previewURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("preview.png") }

    func thumbnail(_ id: UUID) -> UIImage? {
        let key = id.uuidString as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let img = UIImage(contentsOfFile: previewURL(id).path) else { return nil }
        thumbCache.setObject(img, forKey: key)
        return img
    }

    func loadSource(_ id: UUID) -> CGImage? {
        guard let data = try? Data(contentsOf: sourceURL(id)) else { return nil }
        return RenderEngine.loadSource(data: data)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func writeFiles(id: UUID, source: CGImage?, preview: CGImage?) {
        let dir = folder(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let source, let jpg = UIImage(cgImage: source).jpegData(compressionQuality: 0.9) {
            try? jpg.write(to: sourceURL(id), options: .atomic)
        }
        if let preview, let png = UIImage(cgImage: preview).pngData() {
            try? png.write(to: previewURL(id), options: .atomic)
            thumbCache.removeObject(forKey: id.uuidString as NSString)
        }
    }

    // MARK: Mutations

    /// Creates or updates an item. Returns its id.
    @discardableResult
    func upsert(id: UUID?, name: String?, settings: RenderSettings, panelID: String,
                source: CGImage?, preview: CGImage?, markSent: Bool, markSaved: Bool) -> UUID {
        if let id, let i = items.firstIndex(where: { $0.id == id }) {
            items[i].settings = settings
            items[i].panelID = panelID
            if let name, !name.isEmpty { items[i].name = name }
            if markSent {
                items[i].lastSent = Date()
                items[i].sendCount += 1
                items[i].isRecent = true
            }
            if markSaved { items[i].isSaved = true }
            writeFiles(id: id, source: nil, preview: preview)
            trimRecents()
            persist()
            return id
        }
        var item = LibraryItem(name: name ?? Self.defaultName(), settings: settings, panelID: panelID)
        if markSent {
            item.lastSent = Date()
            item.sendCount = 1
            item.isRecent = true
        }
        item.isSaved = markSaved
        writeFiles(id: item.id, source: source, preview: preview)
        items.append(item)
        trimRecents()
        persist()
        return item.id
    }

    func setSaved(_ id: UUID, _ saved: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isSaved = saved
        if !saved && !items[i].isRecent {
            remove(id)
            return
        }
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        items[i].name = name
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder(id))
        thumbCache.removeObject(forKey: id.uuidString as NSString)
        persist()
    }

    func clearRecents() {
        for item in items where item.isRecent {
            if item.isSaved {
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].isRecent = false }
            } else {
                remove(item.id)
            }
        }
        persist()
    }

    private func trimRecents() {
        let recent = recents
        guard recent.count > Self.recentLimit else { return }
        for item in recent.dropFirst(Self.recentLimit) {
            if item.isSaved {
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].isRecent = false }
            } else {
                items.removeAll { $0.id == item.id }
                try? FileManager.default.removeItem(at: folder(item.id))
            }
        }
    }

    static func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: Date())
    }
}
