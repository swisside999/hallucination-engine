import SwiftUI

/// Scene bank: per-scene weight sliders, jump-to-scene, weight presets.
struct SceneBankView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                SectionLabel(text: "SCENE BANK")
                Menu("WEIGHT PRESETS") {
                    ForEach(presets) { p in
                        Button(p.name) { engine.applyPreset(p) }
                    }
                }
                .font(HE.label)
                .frame(width: 160)
                Button("DONE") { dismiss() }.buttonStyle(HEButtonStyle(prominent: true))
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(engine.scenes.indices, id: \.self) { i in
                        row(i)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 720, height: 560)
        .background(HE.bg)
    }

    private func row(_ i: Int) -> some View {
        let current = engine.stats?.sceneId == i
        return HStack(spacing: 10) {
            Button {
                engine.playScene(i)
            } label: {
                Image(systemName: "play.circle\(current ? ".fill" : "")")
                    .foregroundStyle(current ? HE.volt : .secondary)
            }
            .buttonStyle(.plain)
            .help("play this scene now")

            Text(engine.scenes[i])
                .font(HE.mono(11))
                .lineLimit(1)
                .foregroundStyle(current ? HE.volt
                    : (weight(i) == 0 ? HE.textFaint : Color.primary))
                .frame(maxWidth: .infinity, alignment: .leading)

            HESlider(value: Binding(
                get: { weight(i) },
                set: { v in
                    if engine.weights.indices.contains(i) { engine.weights[i] = v }
                }
            ), range: 0...3) { editing in
                if !editing { engine.pushWeights() }
            }
            .frame(width: 160)

            Text(String(format: "%.1f", weight(i)))
                .font(HE.mono(10)).foregroundStyle(HE.textDim)
                .frame(width: 26, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func weight(_ i: Int) -> Double {
        engine.weights.indices.contains(i) ? engine.weights[i] : 1.0
    }
}
