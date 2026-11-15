import SwiftUI

struct SimpleControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            LookChips()

            VStack(spacing: 14) {
                ValueSlider(title: "Brightness", value: $model.settings.look.tone.brightness, range: -0.4...0.4, defaultValue: 0)
                ValueSlider(title: "Contrast", value: $model.settings.look.tone.contrast, range: 0.5...2, defaultValue: 1)
                ValueSlider(title: "Color", value: $model.settings.look.tone.saturation, range: 0...2, defaultValue: 1)
                ValueSlider(title: "Dither detail", value: $model.settings.look.dither.strength, range: 0...1, defaultValue: 0.85,
                            format: { "\(Int(($0 * 100).rounded()))%" })
                Toggle(isOn: Binding(
                    get: { model.settings.look.halftone.enabled },
                    set: { on in model.settings.look.setHalfwayTones(on) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Halfway tones")
                        Text("Pink, orange, grey… as clean patterns instead of noise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))

            HStack(spacing: 10) {
                Picker("Fit", selection: $model.settings.transform.fit) {
                    ForEach(FitMode.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)

                Spacer()

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            model.settings.transform.rotation = (model.settings.transform.rotation + 90) % 360
                        } label: {
                            Image(systemName: "rotate.right")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Rotate")

                        Button {
                            model.settings.transform.mirror.toggle()
                        } label: {
                            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Mirror")
                    }
                }
            }

            Text("Drag and pinch the preview to frame. Looks you save in Advanced show up here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct LookChips: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Look?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Looks")
                    .font(.headline)
                Spacer()
                if model.selectedLook != nil && model.lookIsModified {
                    Button("Revert") {
                        withAnimation(.snappy) { model.revertToLook() }
                    }
                    .font(.subheadline)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(model.allLooks) { look in
                            chip(look)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
            }
        }
        .alert("Rename look", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let look = renaming { model.renameLook(look, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func chip(_ look: Look) -> some View {
        let selected = look.id == model.selectedLookID
        Button {
            withAnimation(.snappy) { model.apply(look) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: look.symbol)
                Text(look.name)
                if selected && model.lookIsModified {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? Glass.regular.tint(Color.accentColor).interactive() : Glass.regular.interactive(), in: .capsule)
        .contextMenu {
            if !look.builtIn {
                Button {
                    model.overwriteLook(look)
                } label: {
                    Label("Update with current settings", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    newName = look.name
                    renaming = look
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    model.deleteLook(look)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Text("Built-in look")
            }
        }
    }
}
