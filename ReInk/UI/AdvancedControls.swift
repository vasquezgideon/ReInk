import SwiftUI

struct AdvancedControls: View {
    @Environment(AppModel.self) private var model
    @State private var showSaveLook = false
    @State private var lookName = ""

    var body: some View {
        VStack(spacing: 14) {
            lookBar
            FramingSection()
            ToneSection()
            InkSection()
            RemapSection()
            DitherSection()
            HalftoneSection()
        }
        .alert("Save as Look", isPresented: $showSaveLook) {
            TextField("Name", text: $lookName)
            Button("Save") { model.saveCurrentAsLook(name: lookName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves tone, inks, remap, dither and halftone settings. The look appears as a chip in Simple mode.")
        }
    }

    private var lookBar: some View {
        let custom = model.selectedLook.map { !$0.builtIn } ?? false
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    lookName = ""
                    showSaveLook = true
                } label: {
                    Label("Save as Look", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glassProminent)

                if custom, model.lookIsModified, let look = model.selectedLook {
                    Button {
                        model.overwriteLook(look)
                    } label: {
                        Label("Update “\(look.name)”", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.glass)
                }
                Spacer(minLength: 0)
                if model.selectedLook != nil && model.lookIsModified {
                    Button {
                        withAnimation(.snappy) { model.revertToLook() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Revert to look")
                }
            }
        }
    }
}

// MARK: - Framing

struct FramingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SectionCard("Framing", symbol: "crop", expanded: true) {
            Picker("Fit", selection: $model.settings.transform.fit) {
                ForEach(FitMode.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)
            ValueSlider(title: "Zoom", value: $model.settings.transform.zoom, range: 0.2...5, defaultValue: 1,
                        format: { String(format: "%.2f×", $0) })
            ValueSlider(title: "Horizontal", value: $model.settings.transform.offsetX, range: -1.5...1.5, defaultValue: 0)
            ValueSlider(title: "Vertical", value: $model.settings.transform.offsetY, range: -1.5...1.5, defaultValue: 0)
            HStack {
                Button {
                    model.settings.transform.rotation = (model.settings.transform.rotation + 90) % 360
                } label: {
                    Label("\(model.settings.transform.rotation)°", systemImage: "rotate.right")
                }
                .buttonStyle(.bordered)
                Toggle("Mirror", isOn: $model.settings.transform.mirror)
                    .toggleStyle(.button)
                Spacer()
                Picker("Background", selection: $model.settings.transform.background) {
                    ForEach(Ink.allCases) { ink in Text(ink.name).tag(ink) }
                }
                .pickerStyle(.menu)
            }
            Text("Background fills the panel wherever the photo doesn't reach (Fit mode, zoomed out).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tone

struct ToneSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SectionCard("Tone & grading", symbol: "slider.horizontal.3") {
            Group {
            ValueSlider(title: "Exposure", value: $model.settings.look.tone.exposure, range: -2...2, defaultValue: 0,
                        format: { String(format: "%+.2f EV", $0) })
            ValueSlider(title: "Brightness", value: $model.settings.look.tone.brightness, range: -0.4...0.4, defaultValue: 0)
            ValueSlider(title: "Contrast", value: $model.settings.look.tone.contrast, range: 0.5...2, defaultValue: 1)
            ValueSlider(title: "Saturation", value: $model.settings.look.tone.saturation, range: 0...2, defaultValue: 1)
            ValueSlider(title: "Vibrance", value: $model.settings.look.tone.vibrance, range: -1...1, defaultValue: 0)
            ValueSlider(title: "Warmth", value: $model.settings.look.tone.warmth, range: -3000...3000, defaultValue: 0,
                        format: { String(format: "%+.0f K", $0) })
            ValueSlider(title: "Tint", value: $model.settings.look.tone.tint, range: -100...100, defaultValue: 0,
                        format: { String(format: "%+.0f", $0) })
            }
            Group {
            ValueSlider(title: "Highlights", value: $model.settings.look.tone.highlights, range: 0...1, defaultValue: 1)
            ValueSlider(title: "Shadows", value: $model.settings.look.tone.shadows, range: -1...1, defaultValue: 0)
            ValueSlider(title: "Gamma", value: $model.settings.look.tone.gamma, range: 0.5...2, defaultValue: 1)
            ValueSlider(title: "Black point", value: $model.settings.look.tone.blackPoint, range: 0...0.4, defaultValue: 0)
            ValueSlider(title: "White point", value: $model.settings.look.tone.whitePoint, range: 0.6...1, defaultValue: 1)
            ValueSlider(title: "Sharpen", value: $model.settings.look.tone.sharpen, range: 0...2, defaultValue: 0)
            }
            HStack {
                Text("Double-tap a label to reset it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset tone") {
                    model.settings.look.tone = ToneSettings()
                }
                .font(.subheadline)
            }
        }
    }
}

// MARK: - Inks & color approximation

struct InkSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let ink = model.settings.look.ink
        SectionCard("Inks & color matching", symbol: "paintpalette") {
            Picker("Ink profile", selection: $model.settings.look.ink.profile) {
                ForEach(InkProfile.allCases) { p in Text(p.title).tag(p) }
            }
            .pickerStyle(.menu)
            Text(ink.profile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Ink.allCases) { i in
                InkRow(ink: i)
            }

            Picker("Color matching", selection: $model.settings.look.ink.metric) {
                ForEach(MatchMetric.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.menu)
            Toggle("Preview with real ink colors", isOn: $model.settings.look.ink.previewRealInk)
            Text("Matching uses the ink colors above, so a measured profile gives an honest preview. Tap a swatch to set your own measured color.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct InkRow: View {
    @Environment(AppModel.self) private var model
    let ink: Ink

    var body: some View {
        @Bindable var model = model
        let i = ink.rawValue
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 32)
                Text(ink.name)
                    .font(.subheadline.weight(.semibold))
                Text(model.settings.look.ink.colors[i].hexString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Use", isOn: $model.settings.look.ink.enabled[i])
                    .labelsHidden()
            }
            if model.settings.look.ink.enabled[i] {
                ValueSlider(title: "Bias (avoid ↔ prefer)", value: $model.settings.look.ink.bias[i], range: -1...1, defaultValue: 0,
                            format: { String(format: "%+.2f", $0) })
            }
        }
        .padding(.vertical, 2)
    }

    private var colorBinding: Binding<Color> {
        let i = ink.rawValue
        return Binding(
            get: { model.settings.look.ink.colors[i].color },
            set: { newColor in
                var s = model.settings
                if s.look.ink.profile != .custom {
                    s.look.ink.custom = s.look.ink.colors
                    s.look.ink.profile = .custom
                }
                if s.look.ink.custom.count == 4 {
                    s.look.ink.custom[i] = RGB(newColor)
                }
                model.settings = s
            })
    }
}

// MARK: - Remap

struct RemapSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let colors = model.settings.look.ink.colors
        SectionCard("Color remap", symbol: "arrow.triangle.swap") {
            Text("Give colors the panel can't show (blue, green, purple) a deliberate home before dithering.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($model.settings.look.remap) { $rule in
                RemapRuleEditor(rule: $rule, inkColors: colors) {
                    let id = rule.id
                    model.settings.look.remap.removeAll { $0.id == id }
                }
                Divider()
            }
            Menu {
                ForEach(RemapRule.presets) { preset in
                    Button(preset.name) {
                        var r = preset
                        r.id = UUID()
                        model.settings.look.remap.append(r)
                    }
                }
                Divider()
                Button("Custom rule") {
                    model.settings.look.remap.append(RemapRule(name: "Custom", hue: 200, target: RGB(0.1, 0.1, 0.12)))
                }
            } label: {
                Label("Add rule", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

private struct RemapRuleEditor: View {
    @Binding var rule: RemapRule
    let inkColors: [RGB]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Rule name", text: $rule.name)
                    .font(.subheadline.weight(.semibold))
                Toggle("On", isOn: $rule.enabled)
                    .labelsHidden()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            HueWindow(hue: rule.hue, width: rule.width)
                .frame(height: 14)
            ValueSlider(title: "Hue", value: $rule.hue, range: 0...360, format: { String(format: "%.0f°", $0) })
            ValueSlider(title: "Range", value: $rule.width, range: 10...180, format: { String(format: "%.0f°", $0) })
            ValueSlider(title: "Min. saturation", value: $rule.minChroma, range: 0...0.8)
            ValueSlider(title: "Strength", value: $rule.strength, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
            HStack(spacing: 8) {
                Text("Target")
                    .font(.subheadline)
                Spacer()
                ForEach(Ink.allCases) { ink in
                    Button {
                        rule.target = inkColors[ink.rawValue]
                    } label: {
                        InkSwatch(color: inkColors[ink.rawValue].color, size: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ink.name)
                }
                ColorPicker("", selection: Binding(get: { rule.target.color }, set: { rule.target = RGB($0) }), supportsOpacity: false)
                    .labelsHidden()
            }
            Toggle("Keep original lightness", isOn: $rule.keepLightness)
                .font(.subheadline)
        }
        .opacity(rule.enabled ? 1 : 0.55)
    }
}

/// Hue strip with the rule's window highlighted (wraps around 0°/360°).
private struct HueWindow: View {
    let hue: Double
    let width: Double

    var body: some View {
        Canvas { ctx, size in
            let stops: [Color] = stride(from: 0.0, through: 360.0, by: 30.0).map { h in
                Color(hue: h / 360, saturation: 0.85, brightness: 0.95)
            }
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: stops), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            let full = Path(CGRect(origin: .zero, size: size))
            var dim = ctx
            dim.opacity = 0.3
            dim.fill(full, with: shading)

            let w = size.width
            let start = CGFloat((hue - width / 2) / 360) * w
            let span = CGFloat(width / 360) * w
            var pieces: [CGRect] = []
            if start < 0 {
                pieces.append(CGRect(x: 0, y: 0, width: max(0, start + span), height: size.height))
                pieces.append(CGRect(x: w + start, y: 0, width: -start, height: size.height))
            } else if start + span > w {
                pieces.append(CGRect(x: start, y: 0, width: w - start, height: size.height))
                pieces.append(CGRect(x: 0, y: 0, width: start + span - w, height: size.height))
            } else {
                pieces.append(CGRect(x: start, y: 0, width: span, height: size.height))
            }
            for r in pieces {
                ctx.fill(Path(r), with: shading)
            }
        }
        .clipShape(Capsule())
    }
}

// MARK: - Dither

struct DitherSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let algo = model.settings.look.dither.algorithm
        SectionCard("Dithering", symbol: "circle.dotted") {
            Picker("Method", selection: $model.settings.look.dither.algorithm) {
                ForEach(DitherAlgorithm.allCases) { a in Text(a.title).tag(a) }
            }
            .pickerStyle(.menu)
            if algo != .none {
                ValueSlider(title: algo.isOrdered ? "Pattern spread" : "Error carried", value: $model.settings.look.dither.strength,
                            range: 0...1, defaultValue: 0.85, format: { "\(Int(($0 * 100).rounded()))%" })
            }
            if algo.isDiffusion {
                Toggle("Serpentine scan", isOn: $model.settings.look.dither.serpentine)
                ValueSlider(title: "Error clamp", value: $model.settings.look.dither.errorClamp, range: 0.05...1, defaultValue: 0.6)
                ValueSlider(title: "Clean flat areas", value: $model.settings.look.dither.deadzone, range: 0...0.15, defaultValue: 0,
                            format: { String(format: "%.3f", $0) })
            }
            Toggle("Linear-light diffusion", isOn: $model.settings.look.dither.linearLight)
            ValueSlider(title: "Snap to pure ink", value: $model.settings.look.dither.snap, range: 0...0.25, defaultValue: 0,
                        format: { $0 == 0 ? "Off" : String(format: "%.3f", $0) })
            Text("Lower the error carried or raise “clean flat areas” to cut speckle. Snap makes near-solid regions solid. Ordered methods (Bayer) give a regular texture that suits graphics.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Halftone tones

struct HalftoneSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let colors = model.settings.look.ink.colors
        let enabled = model.settings.look.halftone.enabled
        SectionCard("Halfway tones", symbol: "circle.lefthalf.filled") {
            Toggle("Use halfway tones", isOn: $model.settings.look.halftone.enabled)
            Text("Each tone is two inks in a fixed checker (or 25/75 pattern). At 212 PPI it reads as a flat new color, so areas like skin, sky or orange stay smooth instead of noisy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if enabled && model.settings.look.dither.algorithm.isDiffusion {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Halfway tones work best with ordered dithering. With error diffusion, tone boundaries grow worm-like textures.")
                            .font(.caption)
                        Button("Switch to Bayer 8×8") {
                            model.settings.look.dither.algorithm = .bayer8
                            model.settings.look.dither.strength = min(model.settings.look.dither.strength, 0.6)
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .padding(10)
                .background(Color.yellow.opacity(0.12), in: .rect(cornerRadius: 12))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(InkMix.all) { mix in
                    let on = model.settings.look.halftone.mixes.contains(mix.id)
                    Button {
                        if on {
                            model.settings.look.halftone.mixes.removeAll { $0 == mix.id }
                        } else {
                            model.settings.look.halftone.mixes.append(mix.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            CheckerSwatch(a: colors[mix.a.rawValue].color, b: colors[mix.b.rawValue].color)
                            Text(mix.name)
                                .font(.subheadline)
                            Spacer(minLength: 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        }
                        .padding(8)
                        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            Toggle("Also 25% / 75% tones", isOn: $model.settings.look.halftone.quarterTones)
                .disabled(!enabled)
        }
    }
}

struct CheckerSwatch: View {
    let a: Color
    let b: Color

    var body: some View {
        Canvas { ctx, size in
            let n = 4
            let s = size.width / CGFloat(n)
            for y in 0..<n {
                for x in 0..<n {
                    let rect = CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)
                    ctx.fill(Path(rect), with: .color((x + y) % 2 == 0 ? a : b))
                }
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.2), lineWidth: 1))
    }
}
