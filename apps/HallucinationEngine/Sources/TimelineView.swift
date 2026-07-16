import AppKit
import AVFoundation
import SwiftUI

/// Video-editor style timeline for a render: waveform ruler with a playhead
/// and audio scrub playback, then lanes for drops, scene blocks, logo
/// windows, strobe zones and an intensity curve. Edits a RenderTimeline
/// binding; RenderView ships it to the engine as render.timeline.
struct TimelineEditor: View {
    @Binding var timeline: RenderTimeline
    let mixPath: String
    let buckets: [Float]
    let duration: Double
    let sceneNames: [String]   // preset bank order = engine scene indices
    let bpmPin: Double?        // BPM field pin, overrides analyzed bpm

    @EnvironmentObject var engine: Engine
    @StateObject private var player = TimelinePlayer()
    @State private var pxPerSec = 6.0
    @State private var snap = true
    @State private var dragOrigin: [String: (a: Double, b: Double)] = [:]
    @State private var pickingScene: RenderTimeline.SceneCue?

    private var bpm: Double { bpmPin ?? (timeline.bpm > 0 ? timeline.bpm : 0) }
    private var beat: Double { bpm > 0 ? 60.0 / bpm : 0 }
    private var laneWidth: CGFloat { max(CGFloat(duration * pxPerSec), 200) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if duration <= 0 {
                Text("pick a mix to edit its timeline")
                    .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.45)))
            } else {
                HStack(alignment: .top, spacing: 6) {
                    labelColumn
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 3) {
                            ruler
                            dropsLane
                            scenesLane
                            regionLane(regions: $timeline.logo, color: .white,
                                       defaultLen: 3.0, key: "logo",
                                       help: "logo stays stamped for the whole window - "
                                             + "click adds, drag body moves, drag right edge resizes")
                            regionLane(regions: $timeline.strobe, color: HE.amber,
                                       defaultLen: 2.0, key: "strobe",
                                       help: "full strobe volley for the whole zone - "
                                             + "click adds, drag body moves, drag right edge resizes")
                            intensityLane
                        }
                        .frame(width: laneWidth)
                    }
                }
            }
        }
        .onAppear { player.load(mixPath) }
        .onChange(of: mixPath) { _, m in player.load(m) }
        .onDisappear { player.stop() }
        .popover(item: $pickingScene) { cue in scenePicker(cue) }
    }

    // ------------------------------------------------------------- toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(player.playing ? "❚❚" : "▶") { player.toggle() }
                .buttonStyle(HEButtonStyle(tint: HE.volt))
                .disabled(duration <= 0)
                .help("play/pause at the playhead - drag the waveform to scrub")
            Text(fmtClock(player.time)).font(HE.data).foregroundStyle(HE.volt)
                .frame(width: 52, alignment: .leading)
            Button(engine.analyzeRunning ? "DETECTING…" : "◉ DETECT DROPS") {
                engine.analyzeMix(mixPath) { drops, bpm in
                    timeline.drops = drops
                    timeline.bpm = bpm
                }
            }
            .buttonStyle(HEButtonStyle(tint: HE.plasma))
            .disabled(engine.analyzeRunning || mixPath.isEmpty)
            .help("audio-only analysis fills the drops lane and the beat grid "
                  + "(a few seconds, no GPU)")
            Button("⧉ SHUFFLE SCENES") { shuffleScenes() }
                .buttonStyle(HEButtonStyle())
                .disabled(sceneNames.isEmpty || duration <= 0)
                .help("fill the scene lane with random phrase-length blocks, then edit")
            Toggle("SNAP", isOn: $snap).toggleStyle(.checkbox).font(HE.label)
                .help(bpm > 0 ? "snap edits to the beat grid"
                              : "no BPM yet - detect drops or pin BPM to enable")
            Spacer()
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 9)).foregroundStyle(HE.textDim)
            HESlider(value: $pxPerSec, range: 2...40, tint: HE.textDim)
                .frame(width: 90)
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 9)).foregroundStyle(HE.textDim)
        }
    }

    private var labelColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            laneLabel("", h: 56)
            laneLabel("DROPS", h: 26)
            laneLabel("SCENES", h: 34)
            laneLabel("LOGO", h: 26)
            laneLabel("STROBE", h: 26)
            laneLabel("INTENSITY", h: 44)
        }
        .frame(width: 62)
    }

    private func laneLabel(_ s: String, h: CGFloat) -> some View {
        Text(s).font(HE.mono(8)).foregroundStyle(HE.textDim)
            .frame(maxWidth: .infinity, minHeight: h, maxHeight: h,
                   alignment: .trailing)
    }

    // ------------------------------------------------------ ruler + playhead

    private var ruler: some View {
        Canvas { ctx, size in
            let n = buckets.count
            if n > 0 {
                let w = size.width / CGFloat(n)
                for (i, v) in buckets.enumerated() {
                    let h = max(CGFloat(v) * size.height * 0.85, 1)
                    ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2,
                                         width: max(w - 0.5, 0.5), height: h)),
                             with: .color(HE.plasma.opacity(0.5)))
                }
            }
            if beat > 0, pxPerSec * beat * 4 >= 8 {
                var t = 0.0
                var bar = 0
                while t < duration {
                    let x = CGFloat(t * pxPerSec)
                    let strong = bar % 4 == 0
                    ctx.fill(Path(CGRect(x: x, y: 0, width: strong ? 1 : 0.5,
                                         height: size.height)),
                             with: .color(.white.opacity(strong ? 0.18 : 0.08)))
                    t += beat * 4
                    bar += 1
                }
            }
            let px = CGFloat(player.time * pxPerSec)
            ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)),
                     with: .color(HE.volt))
        }
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.45)))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in player.seek(clampT(Double(g.location.x) / pxPerSec)) })
    }

    // ----------------------------------------------------------- drops lane

    private var dropsLane: some View {
        laneCanvas(h: 26) { ctx, size in
            for t in timeline.drops {
                marker(ctx: ctx, x: CGFloat(t * pxPerSec), size: size, color: HE.volt)
            }
        }
        .onLaneTap { x, _ in
            timeline.drops.append(snapT(clampT(x / pxPerSec)))
            timeline.drops.sort()
        }
        .overlay { dropHandles }
        .help("THE DROP fires here: scene explosion, logo burst, strobe volley. "
              + "click adds, drag moves, right-click removes")
    }

    private var dropHandles: some View {
        GeometryReader { _ in
            ForEach(timeline.drops.indices, id: \.self) { idx in
                hitArea(w: 12, h: 26)
                    .position(x: CGFloat(timeline.drops[idx] * pxPerSec), y: 13)
                    .gesture(dragGesture(key: "drop-\(idx)",
                                         start: timeline.drops[idx]) { newT in
                        timeline.drops[idx] = newT
                    })
                    .contextMenu {
                        Button("Delete drop") { timeline.drops.remove(at: idx) }
                    }
            }
        }
    }

    // ---------------------------------------------------------- scenes lane

    private var scenesLane: some View {
        let cues = timeline.scenes.sorted { $0.t < $1.t }
        return laneCanvas(h: 34) { ctx, size in
            if cues.isEmpty {
                ctx.draw(Text("empty = random scene walk (AUTO behavior)")
                            .font(HE.mono(8)).foregroundStyle(HE.textFaint),
                         at: CGPoint(x: 118, y: size.height / 2))
            }
            for (k, cue) in cues.enumerated() {
                let x0 = CGFloat(cue.t * pxPerSec)
                let x1 = k + 1 < cues.count ? CGFloat(cues[k + 1].t * pxPerSec)
                                            : size.width
                let r = CGRect(x: x0 + 1, y: 2, width: max(x1 - x0 - 2, 2),
                               height: size.height - 4)
                ctx.fill(Path(roundedRect: r, cornerRadius: 4),
                         with: .color(sceneColor(cue.i).opacity(0.35)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 4),
                           with: .color(sceneColor(cue.i)), lineWidth: 1)
                if r.width > 40 {
                    let name = cue.i < sceneNames.count ? sceneNames[cue.i] : "?"
                    ctx.draw(Text(String(name.prefix(Int(r.width / 6))))
                                .font(HE.mono(8)).foregroundStyle(.white.opacity(0.85)),
                             in: r.insetBy(dx: 5, dy: 9))
                }
            }
        }
        .onLaneTap { x, _ in
            let t = snapT(clampT(x / pxPerSec))
            if timeline.scenes.isEmpty {
                timeline.scenes.append(.init(t: 0, i: 0))
                if t > 1 { timeline.scenes.append(.init(t: t, i: 0)) }
            } else {
                timeline.scenes.append(.init(
                    t: t, i: Int.random(in: 0..<max(sceneNames.count, 1))))
            }
        }
        .overlay { sceneHandles(cues) }
        .help("scene blocks: click empty space to split, drag a boundary to "
              + "retime, click a block to pick its scene, right-click to merge away")
    }

    private func sceneHandles(_ cues: [RenderTimeline.SceneCue]) -> some View {
        GeometryReader { _ in
            ForEach(cues) { cue in
                let x = CGFloat(cue.t * pxPerSec)
                let nextT = cues.first { $0.t > cue.t }?.t ?? duration
                let w = max(CGFloat((nextT - cue.t) * pxPerSec) - 12, 4)
                // block body: click = scene picker, right-click = delete
                hitArea(w: w, h: 28)
                    .position(x: x + 6 + w / 2, y: 17)
                    .onTapGesture { pickingScene = cue }
                    .contextMenu {
                        Button("Remove block (merge left)") {
                            timeline.scenes.removeAll { $0.id == cue.id }
                        }
                    }
                if cue.t > 0 {  // boundary handle; the t=0 block start is fixed
                    hitArea(w: 10, h: 28)
                        .position(x: x, y: 17)
                        .gesture(dragGesture(key: cue.id.uuidString,
                                             start: cue.t) { newT in
                            if let j = timeline.scenes.firstIndex(where: { $0.id == cue.id }) {
                                timeline.scenes[j].t = newT
                            }
                        })
                }
            }
        }
    }

    // ---------------------------------------------------------- region lanes

    private func regionLane(regions: Binding<[RenderTimeline.Region]>,
                            color: Color, defaultLen: Double, key: String,
                            help: String) -> some View {
        laneCanvas(h: 26) { ctx, _ in
            for r in regions.wrappedValue {
                let rect = CGRect(x: CGFloat(r.t * pxPerSec), y: 3,
                                  width: max(CGFloat(r.len * pxPerSec), 3),
                                  height: 20)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(color.opacity(0.3)))
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 3),
                           with: .color(color.opacity(0.8)), lineWidth: 1)
            }
        }
        .onLaneTap { x, _ in
            regions.wrappedValue.append(.init(t: snapT(clampT(x / pxPerSec)),
                                              len: defaultLen))
        }
        .overlay { regionHandles(regions: regions, key: key) }
        .help(help)
    }

    private func regionHandles(regions: Binding<[RenderTimeline.Region]>,
                               key: String) -> some View {
        GeometryReader { _ in
            ForEach(regions.wrappedValue) { r in
                let x = CGFloat(r.t * pxPerSec)
                let w = max(CGFloat(r.len * pxPerSec), 3)
                // body drag moves the region
                hitArea(w: max(w - 8, 3), h: 20)
                    .position(x: x + w / 2 - 4, y: 13)
                    .gesture(dragGesture(key: key + r.id.uuidString,
                                         start: r.t) { newT in
                        if let j = regions.wrappedValue.firstIndex(where: { $0.id == r.id }) {
                            regions.wrappedValue[j].t = newT
                        }
                    })
                    .contextMenu {
                        Button("Delete") {
                            regions.wrappedValue.removeAll { $0.id == r.id }
                        }
                    }
                // right-edge drag resizes
                hitArea(w: 8, h: 20)
                    .position(x: x + w, y: 13)
                    .gesture(dragLenGesture(key: key + r.id.uuidString + "L",
                                            start: r.len) { newLen in
                        if let j = regions.wrappedValue.firstIndex(where: { $0.id == r.id }) {
                            regions.wrappedValue[j].len = max(newLen, 0.2)
                        }
                    })
            }
        }
    }

    // -------------------------------------------------------- intensity lane

    private var intensityLane: some View {
        let pts = timeline.intensity.sorted { $0.t < $1.t }
        return laneCanvas(h: 44) { ctx, size in
            let midY = size.height / 2
            ctx.fill(Path(CGRect(x: 0, y: midY - 0.25, width: size.width,
                                 height: 0.5)),
                     with: .color(.white.opacity(0.15)))
            if pts.isEmpty {
                ctx.draw(Text("empty = audio-driven strength (AUTO behavior)")
                            .font(HE.mono(8)).foregroundStyle(HE.textFaint),
                         at: CGPoint(x: 126, y: midY))
                return
            }
            func pos(_ p: RenderTimeline.CurvePoint) -> CGPoint {
                CGPoint(x: CGFloat(p.t * pxPerSec),
                        y: midY - CGFloat(p.v / 0.3) * (midY - 4))
            }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: pos(pts[0]).y))
            for p in pts { path.addLine(to: pos(p)) }
            path.addLine(to: CGPoint(x: size.width, y: pos(pts[pts.count - 1]).y))
            ctx.stroke(path, with: .color(HE.plasma), lineWidth: 1.5)
            for p in pts {
                ctx.fill(Path(ellipseIn: CGRect(x: pos(p).x - 3, y: pos(p).y - 3,
                                                width: 6, height: 6)),
                         with: .color(HE.plasma))
            }
        }
        .onLaneTap { x, y in
            timeline.intensity.append(.init(t: snapT(clampT(x / pxPerSec)),
                                            v: yToV(y)))
        }
        .overlay { intensityHandles }
        .help("dream intensity: above the line dissolves harder, below "
              + "crystallizes (denoise strength offset). click adds a point, "
              + "drag moves, right-click removes")
    }

    private var intensityHandles: some View {
        GeometryReader { _ in
            ForEach(timeline.intensity) { p in
                hitArea(w: 12, h: 14)
                    .position(x: CGFloat(p.t * pxPerSec),
                              y: 22 - CGFloat(p.v / 0.3) * 18)
                    .gesture(
                        DragGesture()
                            .onChanged { g in
                                let key = p.id.uuidString
                                if dragOrigin[key] == nil {
                                    dragOrigin[key] = (p.t, p.v)
                                }
                                let o = dragOrigin[key]!
                                if let j = timeline.intensity.firstIndex(where: { $0.id == p.id }) {
                                    timeline.intensity[j].t = snapT(clampT(
                                        o.a + Double(g.translation.width) / pxPerSec))
                                    timeline.intensity[j].v = min(max(
                                        o.b - Double(g.translation.height) / 60,
                                        -0.3), 0.3)
                                }
                            }
                            .onEnded { _ in dragOrigin[p.id.uuidString] = nil })
                    .contextMenu {
                        Button("Delete point") {
                            timeline.intensity.removeAll { $0.id == p.id }
                        }
                    }
            }
        }
    }

    // ----------------------------------------------------------- scene picker

    private func scenePicker(_ cue: RenderTimeline.SceneCue) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sceneNames.indices, id: \.self) { i in
                    Button {
                        if let j = timeline.scenes.firstIndex(where: { $0.id == cue.id }) {
                            timeline.scenes[j].i = i
                        }
                        pickingScene = nil
                    } label: {
                        HStack(spacing: 8) {
                            ThumbImage(path: engine.thumbPath(prompt: sceneNames[i]),
                                       version: engine.thumbsVersion)
                            Text(sceneNames[i]).font(HE.mono(9)).lineLimit(2)
                                .foregroundStyle(i == cue.i ? HE.volt : Color.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 340, height: 320)
    }

    // ---------------------------------------------------------------- helpers

    private func laneCanvas(h: CGFloat,
                            draw: @escaping (GraphicsContext, CGSize) -> Void)
        -> some View {
        Canvas { ctx, size in draw(ctx, size) }
            .frame(height: h)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.3)))
    }

    private func hitArea(w: CGFloat, h: CGFloat) -> some View {
        Color.white.opacity(0.001)  // visuals live in the lane canvas
            .frame(width: w, height: h)
            .contentShape(Rectangle())
    }

    private func marker(ctx: GraphicsContext, x: CGFloat, size: CGSize,
                        color: Color) {
        ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)),
                 with: .color(color))
        var tri = Path()
        tri.move(to: CGPoint(x: x - 4, y: 0))
        tri.addLine(to: CGPoint(x: x + 4, y: 0))
        tri.addLine(to: CGPoint(x: x, y: 7))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(color))
    }

    private func dragGesture(key: String, start: Double,
                             apply: @escaping (Double) -> Void) -> some Gesture {
        DragGesture()
            .onChanged { g in
                if dragOrigin[key] == nil { dragOrigin[key] = (start, 0) }
                apply(snapT(clampT(dragOrigin[key]!.a
                                   + Double(g.translation.width) / pxPerSec)))
            }
            .onEnded { _ in dragOrigin[key] = nil }
    }

    private func dragLenGesture(key: String, start: Double,
                                apply: @escaping (Double) -> Void) -> some Gesture {
        DragGesture()
            .onChanged { g in
                if dragOrigin[key] == nil { dragOrigin[key] = (start, 0) }
                apply(dragOrigin[key]!.a + Double(g.translation.width) / pxPerSec)
            }
            .onEnded { _ in dragOrigin[key] = nil }
    }

    private func clampT(_ t: Double) -> Double { min(max(t, 0), duration) }

    private func snapT(_ t: Double) -> Double {
        guard snap, beat > 0 else { return t }
        return (t / beat).rounded() * beat
    }

    private func yToV(_ y: Double) -> Double {
        min(max((22.0 - y) / 18.0 * 0.3, -0.3), 0.3)
    }

    private func sceneColor(_ i: Int) -> Color {
        Color(hue: Double(i * 47 % 360) / 360, saturation: 0.55, brightness: 0.85)
    }

    private func shuffleScenes() {
        let phraseSecs = beat > 0 ? beat * 4 * 8 : 16  // 8 bars, the engine default
        var cues: [RenderTimeline.SceneCue] = []
        var t = 0.0
        var prev = -1
        while t < duration {
            var i = Int.random(in: 0..<sceneNames.count)
            if sceneNames.count > 1 {
                while i == prev { i = Int.random(in: 0..<sceneNames.count) }
            }
            prev = i
            cues.append(.init(t: t, i: i))
            t += phraseSecs
        }
        timeline.scenes = cues
    }
}

// ------------------------------------------------------------ lane tap shim

private extension View {
    /// Single click on a lane -> (x, y) in lane pixels.
    func onLaneTap(_ f: @escaping (Double, Double) -> Void) -> some View {
        gesture(SpatialTapGesture().onEnded { g in
            f(Double(g.location.x), Double(g.location.y))
        })
    }
}

// --------------------------------------------------------------- playback

/// AVAudioPlayer + 30 Hz playhead for the timeline editor.
@MainActor
final class TimelinePlayer: ObservableObject {
    @Published var time = 0.0
    @Published var playing = false
    private var av: AVAudioPlayer?
    private var timer: Timer?
    private var path = ""

    func load(_ p: String) {
        guard p != path else { return }
        stop()
        path = p
        time = 0
        av = p.isEmpty ? nil : try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: p))
        av?.prepareToPlay()
    }

    func toggle() { playing ? pause() : play() }

    func play() {
        guard let av else { return }
        av.currentTime = time
        av.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, let av = self.av else { return }
                self.time = av.currentTime
                if !av.isPlaying { self.pause() }
            }
        }
    }

    func pause() {
        av?.pause()
        playing = false
        timer?.invalidate()
        timer = nil
    }

    func seek(_ t: Double) {
        time = max(t, 0)
        av?.currentTime = time
    }

    func stop() {
        pause()
        av?.stop()
    }
}
