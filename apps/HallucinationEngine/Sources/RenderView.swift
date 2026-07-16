import AppKit
import AVKit
import SwiftUI

/// Render tab: mix in -> video file out, offline. Formats (square / reel /
/// landscape), drop cues, logo burn-in, style flavors, 12 s previews.
/// Everything is an overlay on the stock config - defaults untouched.
struct RenderView: View {
    @EnvironmentObject var engine: Engine
    @State private var mix = ""
    @State private var seek = ""
    @State private var duration = ""
    @State private var outPath = ""
    @AppStorage("renderFps") private var fps = 30
    @AppStorage("renderFormat") private var format = RenderFormat.square
    @AppStorage("renderQuality") private var quality = RenderQuality.hd
    @State private var diffFps = 6.0
    @State private var cues: [DropCue] = []
    @State private var bpmText = ""
    @State private var logo = RenderLogo()
    @State private var flavors = RenderFlavors()
    @State private var player: AVPlayer?
    @StateObject private var wave = WaveformLoader()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollView {
                VStack(spacing: 12) {
                    sourcePanel
                    outputPanel
                    directionPanel
                    logoPanel
                    flavorsPanel
                }
                .padding(.vertical, 18).padding(.leading, 18)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                previewPanel
                runPanel
                Spacer()
            }
            .frame(width: 340)
            .padding(.vertical, 18).padding(.trailing, 18)
        }
        .background(HE.bg)
        .onAppear {
            if mix.isEmpty { mix = engine.recentMixes.first ?? "" }
            if outPath.isEmpty { suggestOutput() }
            if logo.path.isEmpty { logo.path = engine.logoPath }
            wave.load(mix)
        }
        .onChange(of: mix) { _, m in wave.load(m) }
        .onChange(of: engine.previewPath) { _, p in
            if let p { player = AVPlayer(url: URL(fileURLWithPath: p)); player?.play() }
        }
    }

    // ------------------------------------------------------------- sections

    private var sourcePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "SOURCE")
                HStack(spacing: 10) {
                    RecentMixMenu(current: mix) { path in
                        mix = path
                        suggestOutput()
                    }
                    PresetMenu()
                }
                HStack(spacing: 10) {
                    field("START", $seek, "0:00", width: 66,
                          valid: seek.isEmpty || parseClock(seek) != nil)
                    field("LENGTH", $duration, "to end", width: 66,
                          valid: duration.isEmpty || parseClock(duration) != nil)
                        .help("MM:SS - empty renders the whole file")
                }
            }
        }
    }

    private var outputPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "OUTPUT")
                HStack(spacing: 10) {
                    Text("FORMAT").heFieldLabel()
                    Picker("", selection: $format) {
                        ForEach(RenderFormat.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .labelsHidden().frame(width: 200)
                    let g = format.geometry(quality)
                    Text("\(g.w)×\(g.h)").font(HE.data).foregroundStyle(HE.volt)
                }
                HStack(spacing: 10) {
                    Text("QUALITY").heFieldLabel()
                    Picker("", selection: $quality) {
                        ForEach(RenderQuality.allCases) { q in Text(q.rawValue).tag(q) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    .help("Ultra: full SD VAE decode + 20M bitrate - sharper "
                          + "detail and color, renders 3-4x slower")
                    Picker("", selection: $fps) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                }
                HStack(spacing: 10) {
                    Text("DREAM RATE").heFieldLabel()
                    HESlider(value: $diffFps, range: 3...10, tint: HE.plasma)
                        .frame(width: 200)
                    Text(String(format: "%.1f visions/s", diffFps))
                        .font(HE.data).foregroundStyle(HE.textDim)
                }
                .help("diffusion steps per second of mix - live manages ~4.5; renders can afford more")
                HStack(spacing: 10) {
                    Text("SAVE TO").heFieldLabel()
                    Button("Choose…") { pickOutput() }.buttonStyle(HEButtonStyle())
                    Text(outPath.isEmpty ? "-" : (outPath as NSString).lastPathComponent)
                        .font(HE.data).foregroundStyle(HE.textDim).lineLimit(1)
                }
            }
        }
    }

    private var directionPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "DIRECTION")
                HStack(spacing: 10) {
                    Text("BPM").heFieldLabel()
                    TextField("auto", text: $bpmText)
                        .textFieldStyle(.plain).font(HE.data).multilineTextAlignment(.center)
                        .padding(.vertical, 5).frame(width: 66)
                        .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
                        .foregroundStyle(bpmValid ? Color.primary : HE.danger)
                    Text("pin the tempo when auto-detect drifts (e.g. 141)")
                        .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("DROP CUES").heFieldLabel()
                        Button("＋ ADD CUE") { cues.append(DropCue()) }
                            .buttonStyle(HEButtonStyle())
                        Spacer()
                    }
                    Text("click the waveform (or add times, MM:SS.s) where THE DROP fires - "
                         + "scene explosion, logo burst, strobe volley. Cues mute auto "
                         + "drop detection for the render.")
                        .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                    WaveformView(buckets: wave.buckets, duration: wave.duration,
                                 cues: cues.compactMap(\.seconds)) { t in
                        cues.append(DropCue(text: fmtCue(t)))
                    }
                    ForEach($cues) { $cue in
                        HStack(spacing: 8) {
                            TextField("1:20.4", text: $cue.text)
                                .textFieldStyle(.plain).font(HE.data)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 5).frame(width: 80)
                                .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
                                .foregroundStyle(cue.seconds == nil && !cue.text.isEmpty
                                                 ? HE.danger : Color.primary)
                            if let s = cue.seconds {
                                Text(String(format: "= %.1fs", s))
                                    .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                            }
                            Button { cues.removeAll { $0.id == cue.id } } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain).foregroundStyle(HE.textDim)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private var logoPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "LOGO BURN-IN",
                                 tint: logo.enabled ? HE.plasma : HE.textDim)
                    Toggle("", isOn: $logo.enabled).toggleStyle(.switch).labelsHidden()
                        .scaleEffect(0.72, anchor: .trailing)
                }
                if logo.enabled {
                    HStack(spacing: 10) {
                        Text("IMAGE").heFieldLabel()
                        Button {
                            pickLogoFile()
                        } label: {
                            Label(logo.path.isEmpty ? "choose PNG"
                                    : (logo.path as NSString).lastPathComponent,
                                  systemImage: "photo")
                                .font(HE.data).lineLimit(1)
                        }
                        .buttonStyle(HEButtonStyle())
                    }
                    sliderRow("OPACITY", $logo.opacity, 0.3...1.0, "%.2f",
                              help: "1.0 = solid white; lower lets scene texture bleed through")
                    sliderRow("SIZE", $logo.scale, 0.2...format.maxLogoScale, "%.2f",
                              help: "fraction of frame width - capped per format so "
                                    + "crops can't clip the wordmark")
                    sliderRow("DROP CHANCE", $logo.dropChance, 0...1, "%.2f",
                              help: "probability the logo bursts on each drop")
                    sliderRow("FLASH SECS", $logo.flashSeconds, 1...6, "%.1f",
                              help: "how long each burst stays before melting back")
                }
            }
        }
    }

    private var flavorsPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "STYLE FLAVORS")
                flavor("SCENE STAMPS", $flavors.sceneStamps,
                       "each phrase opens as a prompt-faithful image (CFG)")
                flavor("SHORT PHRASES", $flavors.shortPhrases,
                       "scene change every 4 bars - snappy social-clip pacing")
                flavor("HYBRID FUSIONS", $flavors.hybrids,
                       "some phrases fuse two scenes into one dream")
                flavor("SPIRAL SWIRL", $flavors.swirl,
                       "polar swirl in the feedback loop - hypnotic tunnels")
                flavor("ANTI-LOCK BOOST", $flavors.antiLock,
                       "extra noise + tighter detectors for dark or graphic presets")
            }
        }
    }

    private func flavor(_ name: String, _ on: Binding<Bool>, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden()
            Text(name).font(HE.label)
                .foregroundStyle(on.wrappedValue ? HE.plasma : Color.primary)
                .frame(width: 122, alignment: .leading)
            Text(desc).font(HE.mono(9)).foregroundStyle(HE.textFaint).lineLimit(1)
            Spacer()
        }
    }

    // ------------------------------------------------------ preview + run

    private var previewPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "PREVIEW", tint: HE.plasma)
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(previewAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.45))
                        .aspectRatio(previewAspect, contentMode: .fit)
                        .overlay(
                            Text(engine.renderRunning ? "rendering…" : "no preview yet")
                                .font(HE.mono(10)).foregroundStyle(HE.textFaint))
                }
                Button("◉ PREVIEW 12 SEC") { startPreview() }
                    .buttonStyle(HEButtonStyle(tint: HE.plasma))
                    .disabled(mix.isEmpty || engine.renderRunning || engine.running)
                    .help(cues.isEmpty
                          ? "quick draft render from the start position"
                          : "quick draft render around your first drop cue")
            }
        }
    }

    private var previewAspect: CGFloat {
        let g = format.geometry(.draft)
        return CGFloat(g.w) / CGFloat(g.h)
    }

    private var runPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "RENDER", tint: HE.plasma)
                if engine.renderRunning {
                    Button("■ CANCEL") { engine.cancelRender() }
                        .buttonStyle(HEButtonStyle(tint: HE.danger, prominent: true))
                    ProgressView(value: engine.renderProgress).tint(HE.plasma)
                    Text(String(format: "%.0f%%  ·  %.2fx  ·  eta %@",
                                engine.renderProgress * 100, engine.renderSpeed,
                                fmtClock(engine.renderEta)))
                        .font(HE.data).foregroundStyle(HE.textDim)
                } else {
                    Button("▶ RENDER") { startFull() }
                        .buttonStyle(HEButtonStyle(tint: HE.plasma, prominent: true))
                        .disabled(mix.isEmpty || outPath.isEmpty || engine.running)
                }
                if engine.running {
                    Text("live set running - stop it first, the render shares the GPU")
                        .font(HE.mono(9)).foregroundStyle(HE.amber)
                }
                if let err = engine.renderError {
                    Text(err).font(HE.mono(9)).foregroundStyle(HE.danger)
                }
                if let done = engine.renderDonePath {
                    HStack {
                        Text((done as NSString).lastPathComponent)
                            .font(HE.data).foregroundStyle(HE.volt).lineLimit(1)
                        Button("REVEAL") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: done)])
                        }
                        .buttonStyle(HEButtonStyle())
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------- actions

    private var bpmValid: Bool { bpmText.isEmpty || Double(bpmText) != nil }

    private func job() -> RenderJob {
        var j = RenderJob()
        j.mix = mix
        j.seek = seek
        j.duration = duration
        j.fps = fps
        j.format = format
        j.quality = quality
        j.diffFps = diffFps
        j.out = outPath
        j.dropCues = cues.compactMap(\.seconds).sorted().filter { $0 > 0 }
        j.bpmOverride = Double(bpmText).flatMap { $0 > 0 ? $0 : nil }
        var l = logo
        l.scale = min(l.scale, format.maxLogoScale)
        j.logo = logo.enabled && !logo.path.isEmpty ? l : RenderLogo()
        j.flavors = flavors
        return j
    }

    private func startPreview() {
        var j = job()
        j.quality = .draft
        j.duration = "12"
        if let first = j.dropCues.first {
            j.seek = String(format: "%.1f", max(first - 4.0, 0))
        } else if seek.isEmpty {
            j.seek = "0"
        }
        // one preview on disk at a time - previous iterations get deleted
        if let old = engine.previewPath {
            try? FileManager.default.removeItem(atPath: old)
        }
        j.out = NSTemporaryDirectory() + "he_preview_\(Int(Date().timeIntervalSince1970)).mp4"
        player = nil
        engine.startRender(job: j, preview: true)
    }

    private func startFull() {
        engine.startRender(job: job())
    }

    // ---------------------------------------------------------------- misc

    private func field(_ label: String, _ text: Binding<String>, _ prompt: String,
                       width: CGFloat, valid: Bool = true) -> some View {
        HStack(spacing: 8) {
            Text(label).heFieldLabel()
            TextField(prompt, text: text)
                .textFieldStyle(.plain).font(HE.data).multilineTextAlignment(.center)
                .padding(.vertical, 5).frame(width: width)
                .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
                .foregroundStyle(valid ? Color.primary : HE.danger)
        }
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>,
                           _ range: ClosedRange<Double>, _ fmt: String,
                           help: String) -> some View {
        HStack(spacing: 10) {
            Text(label).heFieldLabel()
            HESlider(value: value, range: range, tint: HE.plasma).frame(width: 170)
            Text(String(format: fmt, value.wrappedValue))
                .font(HE.data).foregroundStyle(HE.textDim)
                .frame(width: 40, alignment: .trailing)
        }
        .help(help)
    }

    private func pickLogoFile() {
        if let url = chooseFile([.image]) { logo.path = url.path }
    }

    private func fmtCue(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    private func pickOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = suggestedName()
        panel.directoryURL = FileManager.default.urls(
            for: .moviesDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            outPath = url.path
        }
    }

    private func suggestOutput() {
        let movies = FileManager.default.urls(
            for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        outPath = movies.appendingPathComponent(suggestedName()).path
    }

    private func suggestedName() -> String {
        let base = mix.isEmpty ? "hallucination"
            : (mix as NSString).lastPathComponent
                .replacingOccurrences(of: " ", with: "_")
        let stem = (base as NSString).deletingPathExtension
        return "hallucination_\(stem.prefix(40)).mp4"
    }
}
