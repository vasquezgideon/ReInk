import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let openInEditor: () -> Void

    enum Segment: String, CaseIterable, Identifiable {
        case recents = "Recents"
        case saved = "Saved"
        var id: String { rawValue }
    }

    @State private var segment: Segment = .recents
    @State private var renaming: LibraryItem?
    @State private var newName = ""
    @State private var confirmClear = false

    private var items: [LibraryItem] {
        segment == .recents ? model.library.recents : model.library.saved
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Segment", selection: $segment) {
                        ForEach(Segment.allCases) { s in Text(s.rawValue).tag(s) }
                    }
                    .pickerStyle(.segmented)

                    if items.isEmpty {
                        ContentUnavailableView(
                            segment == .recents ? "Nothing sent yet" : "No saved designs",
                            systemImage: segment == .recents ? "clock" : "star",
                            description: Text(segment == .recents
                                              ? "Everything you send to the case lands here, ready to resend."
                                              : "Tap the star in Create to keep a design with all its settings."))
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                            ForEach(items) { item in
                                cell(item)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Library")
            .toolbar {
                if segment == .recents && !model.library.recents.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Clear recents?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Recents", role: .destructive) { model.library.clearRecents() }
            } message: {
                Text("Saved designs stay in Saved.")
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let item = renaming { model.library.rename(item.id, to: newName) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: LibraryItem) -> some View {
        let panel = PanelProfile.presets.first(where: { $0.id == item.panelID }) ?? model.device.panel
        Button {
            model.open(item)
            openInEditor()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(white: 0.14))
                    if let thumb = model.library.thumbnail(item.id) {
                        Image(uiImage: thumb)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(CGFloat(panel.width) / CGFloat(panel.height), contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(8)
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(CGFloat(panel.width) / CGFloat(panel.height) * 1.04, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if item.isSaved {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(6)
                            .glassEffect(.regular, in: .circle)
                            .padding(6)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.open(item)
                openInEditor()
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            Button {
                model.send(item: item)
            } label: {
                Label("Send to Case", systemImage: "wave.3.right")
            }
            .disabled(model.nfcBusy)
            Button {
                model.library.setSaved(item.id, !item.isSaved)
            } label: {
                Label(item.isSaved ? "Remove from Saved" : "Save", systemImage: item.isSaved ? "star.slash" : "star")
            }
            Button {
                newName = item.name
                renaming = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                model.library.remove(item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func subtitle(_ item: LibraryItem) -> String {
        let date = item.lastSent ?? item.created
        let rel = date.formatted(.relative(presentation: .named))
        if item.sendCount > 0 {
            return "Sent \(item.sendCount)× · \(rel)"
        }
        return "Saved \(rel)"
    }
}
