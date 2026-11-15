import SwiftUI
import UIKit

struct DeviceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                caseSection
                panelSection
                calibrationSection
                transferSection
                toolsSection
            }
            .navigationTitle("Case")
        }
    }

    // MARK: Case info

    private var caseSection: some View {
        Section {
            Button {
                model.probe()
            } label: {
                Label("Read Case Info", systemImage: "wave.3.right.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.nfcBusy)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if let info = model.lastInfo {
                LabeledContent("Reported", value: info.summary)
                if let preset = info.matchingPreset(), preset.id != model.device.panel.id {
                    Button("Switch to \(preset.width)×\(preset.height) profile") {
                        model.device.panel = preset
                    }
                }
                DisclosureGroup("Raw D1 fields") {
                    ForEach(info.fields) { f in
                        LabeledContent(String(format: "%02X", f.tag), value: f.value.spacedHex)
                            .font(.caption.monospaced())
                    }
                }
            }
            if let r = model.lastResult {
                Label(r.message, systemImage: r.success ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(r.success ? Color.green : Color.orange)
                    .font(.subheadline)
            }
        } footer: {
            Text("Reads the case's info block (D1), access state (D8) and busy flag (DE). It never writes.")
        }
    }

    // MARK: Panel profile

    private var panelSection: some View {
        @Bindable var model = model
        return Section("Panel") {
            Picker("Profile", selection: Binding(
                get: { model.device.panel.id },
                set: { id in
                    if let p = PanelProfile.presets.first(where: { $0.id == id }) { model.device.panel = p }
                })) {
                ForEach(PanelProfile.presets) { p in Text(p.name).tag(p.id) }
            }
            Stepper("Width \(model.device.panel.width)", value: $model.device.panel.width, in: 8...2048, step: 4)
            Stepper("Height \(model.device.panel.height)", value: $model.device.panel.height, in: 8...2048, step: 4)
            Picker("Pixel layout", selection: $model.device.panel.scan) {
                ForEach(ScanOrder.allCases) { s in Text(s.title).tag(s) }
            }
            LabeledContent("Frame size", value: "\(model.device.panel.frameBytes.formatted()) bytes")
        }
    }

    // MARK: Calibration

    private var calibrationSection: some View {
        @Bindable var model = model
        return Section {
            Button {
                model.sendTestPattern()
            } label: {
                Label("Send Test Pattern", systemImage: "square.grid.3x3.topleft.filled")
            }
            .disabled(model.nfcBusy)

            VStack(alignment: .leading, spacing: 8) {
                Text("Where did the black square land?")
                    .font(.subheadline)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        cornerButton(.topLeft)
                        cornerButton(.topRight)
                    }
                    GridRow {
                        cornerButton(.bottomLeft)
                        cornerButton(.bottomRight)
                    }
                }
            }
            .padding(.vertical, 4)

            Button {
                let all = ScanOrder.allCases
                let i = all.firstIndex(of: model.device.panel.scan) ?? 0
                model.device.panel.scan = all[(i + 1) % all.count]
                model.sendTestPattern()
            } label: {
                Label("Scrambled? Try Next Layout", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.nfcBusy)

            Toggle("Rotate 180°", isOn: $model.device.panel.rotate180)
            Toggle("Mirror", isOn: $model.device.panel.mirror)

            HStack {
                Button("Swap B/W codes") { swapCodes(0, 1) }
                Spacer()
                Button("Swap Y/R codes") { swapCodes(2, 3) }
            }
            .buttonStyle(.bordered)

            ForEach(Ink.allCases) { ink in
                Picker(selection: $model.device.panel.codes[ink.rawValue]) {
                    ForEach(0..<4) { c in Text("Code \(c)").tag(UInt8(c)) }
                } label: {
                    HStack {
                        InkSwatch(color: ink.ideal.color, size: 14)
                        Text(ink.name)
                    }
                }
            }

            Menu {
                ForEach(Ink.allCases) { ink in
                    Button("Fill \(ink.name.lowercased())") { model.sendSolid(ink) }
                }
                Button("Redraw stored image") { model.refreshStored() }
            } label: {
                Label("Solid Fill & Redraw", systemImage: "rectangle.fill")
            }
            .disabled(model.nfcBusy)
        } header: {
            Text("Calibration")
        } footer: {
            Text("Send the test pattern, then tap the corner where the black square appeared; ReInk fixes rotation and mirroring. If the image is noise or stripes, try the next layout. If colors are swapped, swap their codes.")
        }
    }

    private func cornerButton(_ corner: TestPattern.Corner) -> some View {
        Button {
            let c = corner.correction
            model.device.panel.rotate180 = model.device.panel.rotate180 != c.rotate180
            model.device.panel.mirror = model.device.panel.mirror != c.mirror
        } label: {
            Text(corner.title)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func swapCodes(_ a: Int, _ b: Int) {
        var codes = model.device.panel.codes
        guard codes.count == 4 else { return }
        codes.swapAt(a, b)
        model.device.panel.codes = codes
    }

    // MARK: Transfer

    private var transferSection: some View {
        @Bindable var model = model
        return Section {
            Picker("Upload", selection: $model.device.transfer.compression) {
                ForEach(CompressionMode.allCases) { c in Text(c.title).tag(c) }
            }
            Picker("Refresh", selection: $model.device.transfer.refreshMode) {
                ForEach(RefreshMode.allCases) { m in Text(m.title).tag(m) }
            }
            Picker("Reconnect before refresh", selection: $model.device.transfer.reconnect) {
                ForEach(ReconnectPolicy.allCases) { p in Text(p.title).tag(p) }
            }
            if model.device.transfer.reconnect == .auto {
                Stepper("…if upload > \(Int(model.device.transfer.reconnectAfterSeconds)) s",
                        value: $model.device.transfer.reconnectAfterSeconds, in: 4...19, step: 1)
            }
            Stepper("Power-on wait \(model.device.transfer.powerOnDelayMs) ms",
                    value: $model.device.transfer.powerOnDelayMs, in: 0...12700, step: 100)
            Toggle("Skip panel detection", isOn: $model.device.transfer.skipPanelDetection)
            Stepper("Charge wait \(model.device.transfer.prechargeMs) ms",
                    value: $model.device.transfer.prechargeMs, in: 0...3000, step: 50)
            Stepper("Packet gap \(model.device.transfer.packetDelayMs) ms",
                    value: $model.device.transfer.packetDelayMs, in: 0...100, step: 5)
            if model.device.transfer.refreshMode == .polling {
                Stepper("Poll every \(model.device.transfer.pollIntervalMs) ms",
                        value: $model.device.transfer.pollIntervalMs, in: 100...2000, step: 100)
            }
            Picker("PIN", selection: $model.device.transfer.pinHex) {
                ForEach(TransferSettings.knownPins, id: \.self) { p in Text(p.name).tag(p.hex) }
                if !TransferSettings.knownPins.contains(where: { $0.hex == model.device.transfer.pinHex }) {
                    Text("Custom").tag(model.device.transfer.pinHex)
                }
            }
            TextField("PIN hex (blank = none)", text: $model.device.transfer.pinHex)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        } header: {
            Text("Transfer")
        } footer: {
            Text("Defaults suit most cases: LZO upload, blocking refresh, reconnect only if the upload ran long (iOS cuts a tag connection after ~20 s). A PIN is only sent if the case answers 6985; a wrong PIN can lock some chips.")
        }
    }

    // MARK: Tools

    private var toolsSection: some View {
        @Bindable var model = model
        return Section {
            NavigationLink {
                LogView()
            } label: {
                LabeledContent("Log", value: "\(model.log.count) lines")
            }
            NavigationLink {
                ConsoleView()
            } label: {
                Label("APDU Console", systemImage: "terminal")
            }
            Toggle(isOn: $model.device.transfer.allowDriverWrites) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow driver writes (DA/DB)")
                    Text("Lets the console overwrite the case's stored panel driver. Not reversible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.red)
            Button("Reset Case Settings", role: .destructive) {
                model.device = DeviceSettings()
            }
        } header: {
            Text("Tools")
        }
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.log.reversed()) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(e.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(color(e.level))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: model.logText) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = model.logText
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button(role: .destructive) {
                    model.clearLog()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .overlay {
            if model.log.isEmpty {
                ContentUnavailableView("No log yet", systemImage: "text.alignleft",
                                       description: Text("NFC traffic appears here. Share it when reporting a problem."))
            }
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warn: return .orange
        case .ok: return .green
        case .tx: return .blue
        case .rx: return .primary
        case .info: return .secondary
        }
    }
}

struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var text = "# One APDU per line (hex). Lines starting with # are ignored.\n00D1000000\n"

    private struct Snippet: Identifiable {
        var title: String
        var apdu: String
        var id: String { apdu }
    }

    private let snippets: [Snippet] = [
        Snippet(title: "D1 info", apdu: "00D1000000"),
        Snippet(title: "D8 access", apdu: "F0D8000005000000000E"),
        Snippet(title: "DE status", apdu: "F0DE000001"),
        Snippet(title: "D4 refresh (block)", apdu: "F0D4850000"),
        Snippet(title: "D4 refresh (async)", apdu: "F0D4858000")
    ]

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(snippets) { s in
                        Button(s.title) {
                            if !text.hasSuffix("\n") { text += "\n" }
                            text += s.apdu + "\n"
                        }
                        .buttonStyle(.glass)
                        .font(.caption)
                    }
                }
                .padding(.horizontal)
            }
            TextEditor(text: $text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                .padding(.horizontal)
            List {
                ForEach(model.log.suffix(40).reversed()) { e in
                    Text(e.text)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
            .listStyle(.plain)
            .frame(maxHeight: 220)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("APDU Console")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Send") { model.sendConsole(text) }
                    .disabled(model.nfcBusy)
            }
        }
    }
}
