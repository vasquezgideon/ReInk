import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CreateView: View {
    @Environment(AppModel.self) private var model
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var showSaveItem = false
    @State private var itemName = ""

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if model.sourceImage == nil {
                        emptyState
                            .padding(.top, 40)
                    } else {
                        PreviewStage()
                        sendRow
                        if let r = model.render {
                            CoverageBar(coverage: r.coverage, colors: model.settings.look.ink.previewRealInk ? model.settings.look.ink.colors : (InkProfile.pure.presetColors ?? []))
                                .padding(.horizontal, 4)
                        }
                        Picker("Mode", selection: $model.mode) {
                            ForEach(EditorMode.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        if model.mode == .simple {
                            SimpleControls()
                        } else {
                            AdvancedControls()
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ReInk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .accessibilityLabel("Choose photo")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showFiles = true
                        } label: {
                            Label("Import from Files", systemImage: "folder")
                        }
                        if model.render != nil {
                            Button {
                                itemName = model.library.item(model.currentItemID)?.name ?? LibraryStore.defaultName()
                                showSaveItem = true
                            } label: {
                                Label("Save to Library", systemImage: "star")
                            }
                            Button {
                                var s = model.settings
                                s.transform = ImageTransform()
                                model.settings = s
                            } label: {
                                Label("Reset Framing", systemImage: "arrow.counterclockwise")
                            }
                        }
                        if let r = model.render {
                            let image = Image(decorative: r.preview, scale: 1)
                            ShareLink(item: image, preview: SharePreview("ReInk design", image: image)) {
                                Label("Export Preview", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.loadImage(data: data)
                }
                pickerItem = nil
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let data {
                Task { await model.loadImage(data: data) }
            }
        }
        .alert("Save to Library", isPresented: $showSaveItem) {
            TextField("Name", text: $itemName)
            Button("Save") { model.saveToLibrary(name: itemName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved designs keep the photo and every setting, so you can reopen and tweak them.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Design your case", systemImage: "iphone.gen3")
        } description: {
            Text("Pick a photo and ReInk converts it to the case's four inks: black, white, yellow and red.")
        } actions: {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("Choose Photo")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
        }
    }

    private var sendRow: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.sendCurrent()
                } label: {
                    Label(model.nfcBusy ? "Sending…" : "Send to Case", systemImage: "wave.3.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.render == nil || model.nfcBusy)

                Button {
                    itemName = model.library.item(model.currentItemID)?.name ?? LibraryStore.defaultName()
                    showSaveItem = true
                } label: {
                    Image(systemName: model.currentIsSaved ? "star.fill" : "star")
                        .font(.headline)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .disabled(model.render == nil)
                .accessibilityLabel("Save to Library")
            }
        }
    }
}

/// The case mock with the live dithered preview. Drag to move, pinch to zoom,
/// double-tap to reset framing, hold the eye to compare with the original.
struct PreviewStage: View {
    @Environment(AppModel.self) private var model
    @State private var showOriginal = false
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        let panel = model.device.panel
        let aspect = CGFloat(panel.width) / CGFloat(panel.height)
        VStack {
            GeometryReader { geo in
                screen(size: geo.size)
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            )
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 540)
    }

    @ViewBuilder
    private func screen(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.82)
            if let r = model.render {
                Image(decorative: showOriginal ? r.graded : r.preview, scale: 1)
                    .resizable()
                    .interpolation(showOriginal ? .medium : .none)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(pinch)
                    .offset(drag)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button {
                } label: {
                    Image(systemName: showOriginal ? "eye.fill" : "eye")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in showOriginal = true }
                        .onEnded { _ in showOriginal = false }
                )
                .accessibilityLabel("Hold to compare with original")
                Spacer()
                if model.isRendering {
                    ProgressView()
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular, in: .circle)
                }
            }
            .padding(10)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(panGesture(size: size).simultaneously(with: zoomGesture))
        .onTapGesture(count: 2) {
            var s = model.settings
            s.transform.zoom = 1
            s.transform.offsetX = 0
            s.transform.offsetY = 0
            model.settings = s
        }
    }

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($drag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                guard size.width > 0, size.height > 0 else { return }
                var s = model.settings
                s.transform.offsetX = min(max(s.transform.offsetX + Double(value.translation.width / size.width), -1.5), 1.5)
                s.transform.offsetY = min(max(s.transform.offsetY + Double(value.translation.height / size.height), -1.5), 1.5)
                model.settings = s
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                var s = model.settings
                s.transform.zoom = min(max(s.transform.zoom * Double(value.magnification), 0.2), 5)
                model.settings = s
            }
    }
}
