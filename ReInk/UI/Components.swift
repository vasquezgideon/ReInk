import SwiftUI

/// Grouped content card. Content stays on a plain surface; Liquid Glass is
/// reserved for the floating controls layer (tab bar, toolbar, chips, send).
struct SectionCard<Content: View>: View {
    let title: String
    let symbol: String
    @State private var expanded: Bool
    private let content: Content

    init(_ title: String, symbol: String, expanded: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self._expanded = State(initialValue: expanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Label(title, systemImage: symbol)
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// Slider with title, live value and a reset-on-double-tap title row.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(format(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if let d = defaultValue { value = d }
            }
            Slider(value: $value, in: range)
        }
    }
}

struct InkSwatch: View {
    let color: Color
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.3).strokeBorder(.primary.opacity(0.2), lineWidth: 1))
    }
}

/// Ink usage bar under the preview.
struct CoverageBar: View {
    let coverage: [Double]
    let colors: [RGB]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Ink.allCases) { ink in
                        let v = coverage.indices.contains(ink.rawValue) ? coverage[ink.rawValue] : 0
                        Rectangle()
                            .fill(colors[ink.rawValue].color)
                            .frame(width: max(0, geo.size.width * v))
                    }
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(Ink.allCases) { ink in
                    let v = coverage.indices.contains(ink.rawValue) ? coverage[ink.rawValue] : 0
                    HStack(spacing: 4) {
                        InkSwatch(color: colors[ink.rawValue].color, size: 10)
                        Text("\(ink.short) \(Int((v * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Status pill shown above the tab bar while talking to the case.
struct NFCStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if model.nfcBusy {
                ProgressView(value: model.nfcProgress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else if let r = model.lastResult {
                Image(systemName: r.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.success ? .green : .orange)
            } else {
                Image(systemName: "wave.3.right")
                    .foregroundStyle(.secondary)
            }
            Text(statusText)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.nfcBusy {
                Button("Cancel") { model.cancelNFC() }
                    .font(.subheadline.weight(.semibold))
            } else if model.render != nil {
                Button {
                    model.sendCurrent()
                } label: {
                    Label("Send", systemImage: "wave.3.right")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var statusText: String {
        if model.nfcBusy || model.lastResult != nil, !model.nfcStatus.isEmpty { return model.nfcStatus }
        return model.render == nil ? "Pick a photo to start" : "Ready to send"
    }
}
