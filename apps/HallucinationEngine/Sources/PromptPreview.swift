import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Prompt Preview - its own window: type a prompt, watch SD-Turbo dream it
/// live (debounced as you type), re-roll seeds, save frames you like.
/// Backed by the resident hallucination_engine.prompt_server process; the engine
/// stops it automatically when a set/render/thumbs run needs the GPU.
struct PromptPreviewWindow: View {
    @EnvironmentObject var engine: Engine
    @State private var prompt = ""
    @State private var seed = 7
    @State private var image: NSImage?
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "PROMPT", tint: HE.plasma)
                TextEditor(text: $prompt)
                    .font(HE.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(HE.raised))
                    .frame(minHeight: 120)
                Text("renders as you type - one SD-Turbo step, the same look "
                     + "the engine dreams from")
                    .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                HStack(spacing: 8) {
                    Button("↻ RE-ROLL") {
                        seed = Int.random(in: 0..<100_000)
                        engine.previewPrompt(prompt, seed: seed)
                    }
                    .buttonStyle(HEButtonStyle(tint: HE.plasma))
                    .disabled(!engine.promptServerReady || prompt.isEmpty)
                    Button("SAVE PNG…") { saveFrame() }
                        .buttonStyle(HEButtonStyle())
                        .disabled(image == nil)
                    Text("seed \(seed)").font(HE.mono(9)).foregroundStyle(HE.textFaint)
                    Spacer()
                }
                Spacer()
                HStack(spacing: 7) {
                    LED(on: engine.promptServerReady, color: HE.plasma)
                    Text(engine.promptServerState.isEmpty ? "server off"
                         : engine.promptServerState)
                        .font(HE.mono(9))
                        .foregroundStyle(engine.promptServerState == "ready"
                                         ? HE.textDim : HE.plasma)
                    if engine.promptServerState.isEmpty {
                        Button("START") { engine.startPromptServer() }
                            .buttonStyle(HEButtonStyle(prominent: true))
                    }
                }
            }
            .frame(width: 300)

            VStack(spacing: 8) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ZStack {
                            Rectangle().fill(Color.black.opacity(0.45))
                            Text(engine.promptServerState == "dreaming…"
                                 ? "dreaming…" : "type a prompt")
                                .font(HE.mono(10)).foregroundStyle(HE.textFaint)
                        }
                    }
                }
                .frame(minWidth: 420, minHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .background(HE.bg)
        .frame(minWidth: 780, minHeight: 480)
        .onAppear { engine.startPromptServer() }
        .onDisappear { engine.stopPromptServer() }
        .onChange(of: prompt) { _, p in
            debounce?.cancel()
            debounce = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                engine.previewPrompt(p, seed: seed)
            }
        }
        .onChange(of: engine.promptFrameN) { _, _ in
            if let f = engine.promptFrameFile {
                image = NSImage(contentsOfFile: f)
            }
        }
        // server came up after a GPU handoff - re-dream the current prompt
        .onChange(of: engine.promptServerState) { _, s in
            if s == "ready", image == nil, !prompt.isEmpty {
                engine.previewPrompt(prompt, seed: seed)
            }
        }
    }

    private func saveFrame() {
        guard let file = engine.promptFrameFile else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stem = prompt.split(separator: " ").prefix(4).joined(separator: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        panel.nameFieldStringValue = "dream_\(stem.isEmpty ? "frame" : stem).png"
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: file), to: url)
        }
    }
}
