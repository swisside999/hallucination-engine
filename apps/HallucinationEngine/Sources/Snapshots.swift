#if SNAPSHOT
// Documentation screenshot generator. Not part of the app: build with
//   swift build -c release -Xswiftc -DSNAPSHOT
// and run the binary from the repo root with an output directory as the only
// argument. It stages the real views with representative data and writes
// PNGs, so README screenshots stay reproducible without a live set running.
// ImageRenderer can't run ScrollViews or async .task loads, so layouts are
// composed from the same components the app uses, with images loaded
// synchronously.

import AppKit
import SwiftUI

@main
struct SnapshotMain {
    @MainActor
    static func main() async {
        // ImageRenderer ignores preferredColorScheme; without this, semantic
        // colors (.primary and friends) resolve to light-mode black
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let outDir = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "docs/img"
        try? FileManager.default.createDirectory(
            atPath: outDir, withIntermediateDirectories: true)

        let engine = Engine()
        engine.repoPath = FileManager.default.currentDirectoryPath
        engine.running = true
        engine.connected = true
        engine.stats = mockStats()
        engine.inputDevices = [AudioDevice(i: 1, name: "BlackHole 2ch", ch: 2)]
        engine.logoPath = engine.repoPath + "/assets/swisside_logo.png"
        engine.logoEnabled = true

        shoot(liveShot(engine), size: CGSize(width: 1180, height: 780),
              to: "\(outDir)/live.png")
        shoot(renderShot(engine), size: CGSize(width: 1180, height: 760),
              to: "\(outDir)/render.png")
        shoot(presetsShot(engine), size: CGSize(width: 1100, height: 560),
              to: "\(outDir)/presets.png")
        shoot(promptPreviewShot(engine), size: CGSize(width: 860, height: 500),
              to: "\(outDir)/prompt_preview.png")
        exit(0)
    }

    @MainActor
    static func shoot<V: View>(_ view: V, size: CGSize, to path: String) {
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { print("snapshot FAILED \(path)"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot \(path)")
    }

    @MainActor
    static func mockStats() -> Stats? {
        let json = """
        {"bpm": 141.0, "beat_phase": 0.18, "phrase_phase": 0.62, "phrase_index": 14,
         "scene": "cavernous abandoned warehouse, green laser fans cutting through smoke",
         "scene_id": 8,
         "scene_next": "sea of raised hands in strobing darkness, hypnotic crowd",
         "strength": 0.48, "offset": 0.02, "tension": 0.35, "kick": 0.86,
         "perc": 0.42, "synth": 0.58, "air": 0.33, "rms": 0.71, "fps_diff": 4.6,
         "fps_disp": 60.0, "pos": 1621.0, "dur": 3820.0, "stripe": 0.18,
         "grid": 0.34, "locked_pct": 0.16, "drops": 7, "resets": 2,
         "frames": 26840, "cpu_pct": 212.0, "rss_mb": 6100.0, "uptime": 5410.0,
         "trail": 0.25, "strobe": 0.45, "zoom": 0.004, "noise": 0.03,
         "logo": 1.0, "logo_opacity": 0.8}
        """
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try? dec.decode(Stats.self, from: Data(json.utf8))
    }

    /// Synchronous thumbnail (ImageRenderer can't run .task loads).
    @MainActor
    static func thumb(_ engine: Engine, _ prompt: String, size: CGFloat = 46) -> some View {
        Group {
            if let img = NSImage(contentsOfFile: engine.thumbPath(prompt: prompt)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(HE.raised)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    static func shell<V: View>(_ tab: Tab, _ engine: Engine,
                               @ViewBuilder content: () -> V) -> some View {
        HStack(spacing: 0) {
            RailView(tab: .constant(tab)).environmentObject(engine)
            Rectangle().fill(HE.hairline).frame(width: 1)
            VStack(spacing: 12) { content() }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(HE.bg)
    }

    // ------ stand-ins for AppKit-backed controls ImageRenderer can't draw

    static func menuChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(HE.data).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7)).foregroundStyle(HE.textFaint)
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(HE.raised))
    }

    static func capsuleBar(_ value: Double, width: CGFloat,
                           tint: Color = HE.volt) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.black.opacity(0.5)).frame(width: width, height: 4)
            Capsule().fill(tint).frame(width: width * value, height: 4)
        }
    }

    static func checkbox(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.square.fill" : "square")
            .font(.system(size: 12))
            .foregroundStyle(on ? HE.volt : HE.textDim)
    }

    static func segmented(_ options: [String], selected: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, label in
                Text(label).font(HE.mono(10, .semibold))
                    .padding(.vertical, 4).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(i == selected ? Color.white.opacity(0.18) : .clear))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.4)))
    }

    // LiveView minus its ScrollView; menus/toggles/progress staged.
    @MainActor
    static func liveShot(_ engine: Engine) -> some View {
        shell(.live, engine) {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "SOURCE")
                    HStack(spacing: 10) {
                        menuChip("music.note", "FILE")
                        menuChip("waveform", "Simmer_Master.wav")
                        Text("27:01").font(HE.data)
                            .padding(.vertical, 5).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
                        menuChip("text.book.closed", "General Rave")
                        checkbox(true)
                        Text("AUTO-RESTART").font(HE.micro)
                        Spacer()
                        Button("■ STOP") {}
                            .buttonStyle(HEButtonStyle(tint: HE.danger, prominent: true))
                    }
                }
            }
            Panel {
                HStack(alignment: .center, spacing: 18) {
                    Circle().fill(HE.volt.opacity(0.85)).frame(width: 15, height: 15)
                        .shadow(color: HE.volt.opacity(0.5), radius: 5)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("141.0").font(HE.mono(46, .bold)).foregroundStyle(HE.volt)
                        Text("BPM").font(HE.micro).foregroundStyle(HE.textDim)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PHRASE 14").font(HE.micro).foregroundStyle(HE.textDim)
                        capsuleBar(0.62, width: 90, tint: HE.plasma)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("27:01 / 1:03:40").font(HE.mono(15, .semibold))
                        capsuleBar(0.42, width: 190)
                        Text("SET 1:30:10").font(HE.mono(9)).foregroundStyle(HE.textFaint)
                    }
                }
            }
            HStack(spacing: 12) {
                SceneCard(showBank: .constant(false)).environmentObject(engine)
                DropButton().environmentObject(engine)
            }
            MetersView().environmentObject(engine)
            KnobsView().environmentObject(engine)
            Panel {
                HStack(spacing: 10) {
                    Text("LOGO").font(HE.micro).tracking(2).foregroundStyle(HE.textDim)
                    LED(on: true)
                    menuChip("photo", "swisside_logo.png")
                    checkbox(true)
                    Text("AUTO").font(HE.micro)
                    HESlider(value: .constant(0.8), range: 0...1).frame(width: 110)
                    Text("0.80").font(HE.data).foregroundStyle(HE.textDim)
                    Button("SHOW NOW") {}.buttonStyle(HEButtonStyle())
                    Button("SCHEDULE…") {}.buttonStyle(HEButtonStyle())
                    Spacer()
                    Button("RESET FLASH") {}.buttonStyle(HEButtonStyle())
                    Button("CAPTURE") {}.buttonStyle(HEButtonStyle())
                    Button("FULLSCREEN") {}.buttonStyle(HEButtonStyle())
                }
            }
            HStack {
                StatsFooter().environmentObject(engine)
                Spacer()
            }
        }
    }

    // The render tab's panels, staged (RenderView itself scrolls).
    @MainActor
    static func renderShot(_ engine: Engine) -> some View {
        let cues = [80.4, 190.6]
        let dur = 272.3
        var buckets: [Float] = []
        for i in 0..<480 {  // representative techno envelope
            let t = Float(i) / 480
            let breakdown = (t > 0.24 && t < 0.30) || (t > 0.60 && t < 0.70)
            let base: Float = breakdown ? 0.35 : 0.8
            buckets.append(base + 0.2 * sin(Float(i) * 0.9) * (breakdown ? 0.4 : 1))
        }
        return shell(.render, engine) {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "OUTPUT")
                    HStack(spacing: 10) {
                        Text("FORMAT").heFieldLabel()
                        menuChip("rectangle.portrait", "Instagram Reel 9:16")
                        Text("1080×1920").font(HE.data).foregroundStyle(HE.volt)
                    }
                    HStack(spacing: 10) {
                        Text("QUALITY").heFieldLabel()
                        segmented(["Draft", "HD", "Full"], selected: 2)
                        segmented(["30 FPS", "60 FPS"], selected: 0)
                    }
                    HStack(spacing: 10) {
                        Text("DREAM RATE").heFieldLabel()
                        HESlider(value: .constant(6.0), range: 3...10, tint: HE.plasma)
                            .frame(width: 200)
                        Text("6.0 visions/s").font(HE.data).foregroundStyle(HE.textDim)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "DIRECTION")
                    Text("click the waveform (or add times, MM:SS.s) where THE DROP fires - "
                         + "scene explosion, logo burst, strobe volley.")
                        .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                    WaveformView(buckets: buckets, duration: dur, cues: cues) { _ in }
                    HStack(spacing: 14) {
                        ForEach(cues, id: \.self) { c in
                            Text(String(format: "%d:%04.1f", Int(c) / 60,
                                        c.truncatingRemainder(dividingBy: 60)))
                                .font(HE.data)
                                .padding(.vertical, 4).padding(.horizontal, 10)
                                .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
                        }
                        Text("BPM 141").font(HE.data).foregroundStyle(HE.volt)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "STYLE FLAVORS")
                    flavorRow("SCENE STAMPS", true,
                              "each phrase opens as a prompt-faithful image (CFG)")
                    flavorRow("SHORT PHRASES", true,
                              "scene change every 4 bars - snappy social-clip pacing")
                    flavorRow("SPIRAL SWIRL", false,
                              "polar swirl in the feedback loop - hypnotic tunnels")
                }
            }
        }
    }

    static func flavorRow(_ name: String, _ on: Bool, _ desc: String) -> some View {
        HStack(spacing: 10) {
            checkbox(on)
            Text(name).font(HE.label)
                .foregroundStyle(on ? HE.plasma : Color.primary)
                .frame(width: 122, alignment: .leading)
            Text(desc).font(HE.mono(9)).foregroundStyle(HE.textFaint)
            Spacer()
        }
    }

    // The preset editor's scene list with the real thumbnail cache.
    @MainActor
    static func presetsShot(_ engine: Engine) -> some View {
        let scenes = [
            ("cavernous abandoned warehouse, green laser fans cutting through smoke, silhouetted crowd, monolithic concrete pillars, darkness", 1.0),
            ("surrealist oil painting in the style of salvador dali, melting clocks dripping over a dark dancefloor, elongated shadows, dreamlike desert of speakers, impossible architecture", 2.0),
            ("sea of raised hands in strobing darkness, hypnotic crowd swaying in unison, sweat and haze, backlit silhouettes, grainy monochrome", 1.0),
            ("writhing mass of snakes coiling in darkness, iridescent scales catching light, cobra hoods flaring, hypnotic serpent eyes, macro detail, black background", 1.0),
            ("fleet of glowing ufo saucers hovering over a night rave in the desert, abduction beams of white light, silhouetted crowd reaching upward, swirling storm clouds and stars, cinematic, ominous", 1.0),
        ]
        return shell(.presets, engine) {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel(text: "SCENES (42)")
                        Button("＋ ADD SCENE") {}.buttonStyle(HEButtonStyle())
                        Button("◉ THUMBS") {}.buttonStyle(HEButtonStyle(tint: HE.plasma))
                        Button("↻") {}.buttonStyle(HEButtonStyle())
                        Button("PREVIEW…") {}.buttonStyle(HEButtonStyle(tint: HE.plasma))
                    }
                    Text("weight = relative pick probability in the random walk")
                        .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                    ForEach(scenes, id: \.0) { prompt, weight in
                        HStack(alignment: .top, spacing: 8) {
                            thumb(engine, prompt)
                            Text(prompt)
                                .font(HE.data)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
                            HESlider(value: .constant(weight), range: 0...3)
                                .frame(width: 90).padding(.top, 4)
                            Text(String(format: "%.1f", weight))
                                .font(HE.data).foregroundStyle(HE.textDim).padding(.top, 6)
                        }
                    }
                }
            }
        }
    }

    // The prompt playground with a cached frame.
    @MainActor
    static func promptPreviewShot(_ engine: Engine) -> some View {
        let prompt = "occult illuminati ritual, hooded figures circling a glowing all-seeing eye atop a pyramid, candlelit lodge, masonic symbols in smoke, chiaroscuro, ominous"
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "PROMPT", tint: HE.plasma)
                Text(prompt)
                    .font(HE.mono(12))
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(HE.raised))
                Text("renders as you type - one SD-Turbo step, the same look "
                     + "the engine dreams from")
                    .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                HStack(spacing: 8) {
                    Button("↻ RE-ROLL") {}.buttonStyle(HEButtonStyle(tint: HE.plasma))
                    Button("SAVE PNG…") {}.buttonStyle(HEButtonStyle())
                    Text("seed 41291").font(HE.mono(9)).foregroundStyle(HE.textFaint)
                }
                Spacer()
                HStack(spacing: 7) {
                    LED(on: true, color: HE.plasma)
                    Text("ready").font(HE.mono(9)).foregroundStyle(HE.textDim)
                }
            }
            .frame(width: 300)
            thumb(engine, prompt, size: 440)
        }
        .padding(16)
        .background(HE.bg)
    }
}
#endif
