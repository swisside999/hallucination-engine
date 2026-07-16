import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// HALLUCINATION ENGINE design system - dark, technical, instrument-grade.
/// One accent (volt) for state/data, one (plasma) for creative/render surfaces.
enum HE {
    // palette
    static let bg = Color(red: 0.043, green: 0.047, blue: 0.059)        // window
    static let panel = Color(red: 0.078, green: 0.086, blue: 0.106)     // cards
    static let raised = Color(red: 0.114, green: 0.125, blue: 0.153)    // controls
    static let hairline = Color.white.opacity(0.08)
    static let volt = Color(red: 0.714, green: 1.0, blue: 0.18)         // data / live
    static let plasma = Color(red: 0.647, green: 0.44, blue: 1.0)       // render / create
    static let amber = Color(red: 1.0, green: 0.694, blue: 0.24)        // warnings
    static let danger = Color(red: 1.0, green: 0.231, blue: 0.306)      // drop / destructive
    static let textDim = Color.white.opacity(0.55)
    static let textFaint = Color.white.opacity(0.35)

    // type
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let micro = mono(9, .bold)
    static let label = mono(10.5, .bold)
    static let data = mono(11)
}

/// One modal open-panel for every picker in the app (files only, never dirs).
@MainActor
func chooseFile(_ types: [UTType]) -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = types
    panel.canChooseDirectories = false
    return panel.runModal() == .OK ? panel.url : nil
}

/// Prompt-preset picker - shared by the LIVE and RENDER tabs (both arm the
/// same engine.promptPreset for the next launch/render).
struct PresetMenu: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        Menu {
            Button("config default") { engine.selectPreset("") }
            Divider()
            ForEach(engine.presetNames, id: \.self) { name in
                Button(name) { engine.selectPreset(name) }
            }
        } label: {
            Label(engine.promptPreset.isEmpty ? "preset" : engine.promptPreset,
                  systemImage: "text.book.closed")
                .font(HE.data).lineLimit(1)
        }
        .frame(maxWidth: 170)
        .help("prompt preset - switches the running set live (crossfaded), "
              + "otherwise applies at next launch. edit in PRESETS")
    }
}

/// Recent-mix picker - shared by the LIVE and RENDER tabs.
struct RecentMixMenu: View {
    @EnvironmentObject var engine: Engine
    let current: String
    let onPick: (String) -> Void
    var body: some View {
        Menu {
            ForEach(engine.recentMixes, id: \.self) { path in
                Button((path as NSString).lastPathComponent) { onPick(path) }
            }
            Divider()
            Button("Open…") {
                if let url = chooseFile([.audio]) {
                    engine.rememberMix(url.path)
                    onPick(url.path)
                }
            }
        } label: {
            Label(current.isEmpty ? "choose mix"
                    : (current as NSString).lastPathComponent,
                  systemImage: "waveform")
                .font(HE.data).lineLimit(1)
        }
        .frame(maxWidth: 300)
    }
}

/// Caps micro-header with a trailing hairline - section separators.
struct SectionLabel: View {
    let text: String
    var tint: Color = HE.textDim
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(HE.micro).tracking(2.2).foregroundStyle(tint)
            Rectangle().fill(HE.hairline).frame(height: 1)
        }
    }
}

/// Standard card: panel fill, hairline stroke.
struct Panel<Content: View>: View {
    var pad: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(HE.panel)
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(HE.hairline, lineWidth: 1)))
    }
}

/// Status LED.
struct LED: View {
    let on: Bool
    var color: Color = HE.volt
    var off: Color = Color.white.opacity(0.15)
    var body: some View {
        Circle()
            .fill(on ? color : off)
            .frame(width: 7, height: 7)
            .shadow(color: on ? color.opacity(0.8) : .clear, radius: 3)
    }
}

/// Small mono stat chip.
struct Chip: View {
    let label: String
    let value: String
    var warn = false
    var body: some View {
        HStack(spacing: 5) {
            Text(label.uppercased()).foregroundStyle(HE.textFaint)
            Text(value).foregroundStyle(warn ? HE.danger : HE.volt)
        }
        .font(HE.mono(10, .semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(HE.hairline, lineWidth: 1))
    }
}

/// Instrument slider: hairline track, volt fill, rectangular grab.
struct HESlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tint: Color = HE.volt
    var onEdit: ((Bool) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = CGFloat(frac.isFinite ? min(max(frac, 0), 1) : 0) * (geo.size.width - 8)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.5)).frame(height: 3)
                Capsule().fill(tint.opacity(0.65)).frame(width: x + 4, height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.85))
                    .frame(width: 8, height: 16)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    onEdit?(true)
                    let f = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                    value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in onEdit?(false) })
        }
        .frame(height: 18)
    }
}

/// Primary action button (filled, tinted).
struct HEButtonStyle: ButtonStyle {
    var tint: Color = HE.volt
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HE.mono(11, .bold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(prominent ? tint : HE.raised))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(prominent ? tint : HE.hairline, lineWidth: 1))
            .foregroundStyle(prominent ? .black : .primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    /// Field label in column layouts.
    func heFieldLabel() -> some View {
        font(HE.label).foregroundStyle(HE.textDim).frame(width: 92, alignment: .leading)
    }
}
