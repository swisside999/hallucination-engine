import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case live = "LIVE"
    case render = "RENDER"
    case presets = "PRESETS"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .live: "waveform"
        case .render: "film"
        case .presets: "text.book.closed"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @State private var tab: Tab = .live

    var body: some View {
        HStack(spacing: 0) {
            RailView(tab: $tab)
            Rectangle().fill(HE.hairline).frame(width: 1)
            Group {
                switch tab {
                case .live: LiveView()
                case .render: RenderView()
                case .presets: PresetsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HE.bg)
        .frame(minWidth: 1060, minHeight: 700)
    }
}

// --------------------------------------------------------------------- rail

struct RailView: View {
    @EnvironmentObject var engine: Engine
    @Binding var tab: Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // wordmark (below traffic lights)
            VStack(alignment: .leading, spacing: 1) {
                Text("HALLUCINATION").font(HE.mono(13, .black)).tracking(1.8)
                Text("ENGINE").font(HE.mono(13, .black)).tracking(1.8)
                    .foregroundStyle(HE.volt)
                Text("AUDIO-REACTIVE AI VJ").font(HE.mono(7, .semibold)).tracking(1.4)
                    .foregroundStyle(HE.textFaint).padding(.top, 4)
            }
            .padding(.top, 38).padding(.horizontal, 16).padding(.bottom, 22)

            ForEach(Tab.allCases) { t in
                railItem(t)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    LED(on: engine.running, color: engine.connected ? HE.volt : HE.amber)
                    Text(engine.running
                         ? (engine.connected ? "ENGINE LIVE" : "ENGINE STARTING")
                         : "ENGINE IDLE")
                        .font(HE.micro).tracking(1.2)
                        .foregroundStyle(engine.running ? .primary : HE.textFaint)
                }
                HStack(spacing: 7) {
                    LED(on: engine.renderRunning, color: HE.plasma)
                    Text(engine.renderRunning ? "RENDERING" : "RENDER IDLE")
                        .font(HE.micro).tracking(1.2)
                        .foregroundStyle(engine.renderRunning ? .primary : HE.textFaint)
                }
                Text("v2.0").font(HE.mono(8)).foregroundStyle(HE.textFaint)
            }
            .padding(16)
        }
        .frame(width: 176)
        .background(Color.black.opacity(0.25))
    }

    private func railItem(_ t: Tab) -> some View {
        Button { tab = t } label: {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(tab == t ? HE.volt : .clear)
                    .frame(width: 3, height: 16)
                Image(systemName: t.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(t.rawValue).font(HE.label).tracking(1.6)
                Spacer()
            }
            .foregroundStyle(tab == t ? .primary : HE.textDim)
            .padding(.vertical, 9).padding(.horizontal, 13)
            .background(tab == t ? Color.white.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// --------------------------------------------------------------------- live

struct LiveView: View {
    @EnvironmentObject var engine: Engine
    @State private var showBank = false
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                TransportBar()
                HeaderView()
                HStack(spacing: 12) {
                    SceneCard(showBank: $showBank)
                    DropButton()
                }
                MetersView()
                KnobsView()
                LogoCard()
                HStack {
                    StatsFooter()
                    Spacer()
                    Button(showLog ? "HIDE LOG" : "LOG") { showLog.toggle() }
                        .buttonStyle(HEButtonStyle())
                }
                if showLog { LogView() }
            }
            .padding(18)
        }
        .background(HE.bg)
        .sheet(isPresented: $showBank) { SceneBankView() }
        .onAppear {
            // devices rarely change mid-set - scan once, Rescan is explicit
            if engine.inputDevices.isEmpty { engine.refreshInputDevices() }
        }
    }
}

// ---------------------------------------------------------------- transport

struct TransportBar: View {
    @EnvironmentObject var engine: Engine

    private var liveMode: Bool { !engine.liveDevice.isEmpty }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "SOURCE")
                HStack(spacing: 10) {
                    sourceMenu
                    if liveMode && engine.inputDevices.isEmpty {
                        // enumeration failed/empty - manual index fallback so
                        // live mode is never unreachable
                        TextField("dev #", text: $engine.liveDevice)
                            .textFieldStyle(.plain).font(HE.data)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 5).frame(width: 52)
                            .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
                            .help("input device index - python main.py --list-devices")
                    }
                    if !liveMode {
                        RecentMixMenu(current: engine.mixPath) { engine.mixPath = $0 }
                        TextField("0:00", text: $engine.seek)
                            .textFieldStyle(.plain).font(HE.data).multilineTextAlignment(.center)
                            .padding(.vertical, 5).padding(.horizontal, 6)
                            .frame(width: 62)
                            .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
                            .help("start position - MM:SS")
                    }
                    PresetMenu()
                    Toggle("AUTO-RESTART", isOn: $engine.autoRestart)
                        .toggleStyle(.checkbox).font(HE.micro)
                        .help("relaunch the engine if it dies mid-set")
                    Spacer()
                    if engine.running {
                        Button("■ STOP") { engine.stop() }
                            .buttonStyle(HEButtonStyle(tint: HE.danger, prominent: true))
                    } else {
                        Button("▶ START") { engine.start() }
                            .buttonStyle(HEButtonStyle(prominent: true))
                    }
                }
            }
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button("Audio file") { engine.liveDevice = "" }
            Divider()
            ForEach(engine.inputDevices) { d in
                Button("\(d.name)  (\(d.ch) ch)") { engine.liveDevice = "\(d.i)" }
            }
            Divider()
            Button("Rescan inputs") { engine.refreshInputDevices() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: liveMode ? "dot.radiowaves.left.and.right" : "music.note")
                Text(liveMode ? (deviceName ?? "input #\(engine.liveDevice)") : "FILE")
                    .font(HE.data).lineLimit(1)
            }
        }
        .frame(maxWidth: 220)
        .help("audio source: a file, or a live input (BlackHole for DJ software)")
    }

    private var deviceName: String? {
        guard let i = Int(engine.liveDevice) else { return nil }
        return engine.inputDevices.first(where: { $0.i == i })?.name
    }
}

// ------------------------------------------------------------------ header

struct HeaderView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let s = engine.stats
        Panel {
            HStack(alignment: .center, spacing: 18) {
                beatDot(phase: s?.beatPhase ?? 0)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%5.1f", s?.bpm ?? 0))
                        .font(HE.mono(46, .bold))
                        .foregroundStyle(HE.volt)
                    Text("BPM").font(HE.micro).foregroundStyle(HE.textDim)
                }
                phraseBlock(s)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(fmtClock(s?.pos ?? 0)) / \(fmtClock(s?.dur ?? 0))")
                        .font(HE.mono(15, .semibold))
                    ProgressView(value: min(max((s?.pos ?? 0) / max(s?.dur ?? 1, 1), 0), 1))
                        .tint(HE.volt)
                        .frame(width: 190)
                    Text("SET \(fmtClock(s?.uptime ?? 0))"
                         + (engine.restarts > 0 ? "  ·  \(engine.restarts) RESTARTS" : ""))
                        .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                }
            }
        }
    }

    private func phraseBlock(_ s: Stats?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("PHRASE \(s?.phraseIndex ?? 0)")
                .font(HE.micro).foregroundStyle(HE.textDim)
            ProgressView(value: min(max(s?.phrasePhase ?? 0, 0), 1))
                .tint(HE.plasma).frame(width: 90)
        }
    }

    private func beatDot(phase: Double) -> some View {
        Circle()
            .fill(HE.volt.opacity(1.0 - phase * 0.85))
            .frame(width: 15, height: 15)
            .shadow(color: HE.volt.opacity(0.6 * (1 - phase)), radius: 5)
    }
}

// ------------------------------------------------------------- scene + drop

struct SceneCard: View {
    @EnvironmentObject var engine: Engine
    @Binding var showBank: Bool

    var body: some View {
        let s = engine.stats
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "SCENE")
                    Button("BANK") { showBank = true }.buttonStyle(HEButtonStyle())
                    Button("SKIP →") { engine.skipScene() }.buttonStyle(HEButtonStyle())
                        .disabled(!engine.connected)
                }
                Text(s?.scene ?? "-")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                Text("NEXT  \(s?.sceneNext ?? "-")")
                    .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                    .lineLimit(1)
            }
        }
    }
}

struct DropButton: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let tension = engine.stats?.tension ?? 0
        Button { engine.drop() } label: {
            VStack(spacing: 3) {
                Text("DROP").font(HE.mono(26, .black)).tracking(3)
                Text("SPACE").font(HE.mono(8)).opacity(0.65)
            }
            .foregroundStyle(.white)
            .frame(width: 168, height: 92)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(HE.danger.opacity(0.35 + 0.6 * tension)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(HE.danger.opacity(0.5 + 0.5 * tension), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!engine.connected)
        .help("force the drop: scene change + explosion + strobe (spacebar)")
    }
}

// ------------------------------------------------------------------ meters

struct MetersView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let s = engine.stats
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "SPECTRUM")
                HStack(alignment: .bottom, spacing: 18) {
                    // 3-band EQ loudness: the engine's band envelopes
                    HStack(spacing: 12) {
                        EQBar(label: "LOW", value: s?.kick ?? 0)
                        EQBar(label: "MID", value: s?.synth ?? 0)
                        EQBar(label: "HIGH", value: s?.air ?? 0)
                    }
                    .frame(width: 150, height: 104)
                    Rectangle().fill(HE.hairline).frame(width: 1, height: 96)
                    VStack(spacing: 10) {
                        meter("PERC", s?.perc ?? 0, HE.volt)
                        meter("RMS", s?.rms ?? 0, HE.volt)
                        meter("TENSION", s?.tension ?? 0, HE.danger)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func meter(_ label: String, _ v: Double, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(HE.micro).tracking(1.2).foregroundStyle(HE.textDim)
                .frame(width: 54, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.5))
                    Capsule().fill(color.opacity(0.9))
                        .frame(width: max(geo.size.width * min(max(v, 0), 1), 3))
                }
            }
            .frame(height: 7)
            .animation(.linear(duration: 0.12), value: v)
        }
    }
}

// ------------------------------------------------------------------- knobs

struct KnobsView: View {
    @EnvironmentObject var engine: Engine
    @State private var offset = 0.0
    @State private var trail = 0.25
    @State private var strobe = 0.45
    @State private var zoom = 0.004
    @State private var noise = 0.03
    @State private var dragging: String? = nil

    var body: some View {
        Panel {
            VStack(spacing: 8) {
                SectionLabel(text: "ENGINE")
                knob("STRENGTH", $offset, -0.3...0.3) { engine.setOffset($0) }
                knob("TRAIL", $trail, 0...0.6) { engine.setParam("display.trail_base", $0) }
                knob("STROBE", $strobe, 0...0.8) { engine.setParam("display.strobe_intensity", $0) }
                knob("ZOOM", $zoom, 0...0.015) { engine.setParam("diffusion.zoom_base", $0) }
                knob("NOISE", $noise, 0...0.08) { engine.setParam("diffusion.noise_idle", $0) }
            }
        }
        .onChange(of: engine.stats?.offset) { _, v in
            if dragging != "STRENGTH", let v { offset = v }
        }
        .onChange(of: engine.stats?.trail) { _, v in
            if dragging != "TRAIL", let v { trail = v }
        }
        .onChange(of: engine.stats?.strobe) { _, v in
            if dragging != "STROBE", let v { strobe = v }
        }
        .onChange(of: engine.stats?.zoom) { _, v in
            if dragging != "ZOOM", let v { zoom = v }
        }
        .onChange(of: engine.stats?.noise) { _, v in
            if dragging != "NOISE", let v { noise = v }
        }
    }

    private func knob(_ label: String, _ value: Binding<Double>,
                      _ range: ClosedRange<Double>,
                      send: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label).font(HE.label).foregroundStyle(HE.volt)
                .frame(width: 78, alignment: .leading)
            HESlider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0; send($0) }
            ), range: range) { editing in
                dragging = editing ? label : nil
            }
            Text(String(format: "%.3f", value.wrappedValue))
                .font(HE.data).foregroundStyle(HE.textDim)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// -------------------------------------------------------------------- logo

struct LogoCard: View {
    @EnvironmentObject var engine: Engine
    @State private var showSchedule = false
    @State private var opacity = 0.8
    @State private var draggingOpacity = false

    var body: some View {
        Panel {
            HStack(spacing: 10) {
                Text("LOGO").font(HE.micro).tracking(2).foregroundStyle(HE.textDim)
                LED(on: (engine.stats?.logo ?? 0) > 0)
                    .help("lit while the logo is in the hallucination")

                Menu {
                    Button("Choose…") { pickLogo() }
                    if !engine.logoPath.isEmpty {
                        Button("Clear") { engine.setLogoPath("") }
                    }
                } label: {
                    Label(engine.logoPath.isEmpty ? "no logo"
                            : (engine.logoPath as NSString).lastPathComponent,
                          systemImage: "photo")
                        .font(HE.data).lineLimit(1)
                }
                .frame(maxWidth: 220)

                Toggle("AUTO", isOn: Binding(
                    get: { engine.logoEnabled },
                    set: { engine.setLogoEnabled($0) }))
                    .toggleStyle(.checkbox).font(HE.micro)
                    .help("flash the logo with drops/strobes and on random phrases")

                HESlider(value: Binding(
                    get: { opacity },
                    set: { opacity = $0; engine.setParam("logo.opacity", $0) }
                ), range: 0...1) { editing in
                    draggingOpacity = editing
                }
                .frame(width: 110)
                .help("logo opacity - lower lets more hallucination through the strokes")
                Text(String(format: "%.2f", opacity))
                    .font(HE.data).foregroundStyle(HE.textDim)
                    .frame(width: 34, alignment: .trailing)

                Button("SHOW NOW") { engine.setLogoHold(!engine.logoHold) }
                    .buttonStyle(HEButtonStyle(prominent: engine.logoHold))
                    .disabled(!engine.connected)
                    .help("hold the logo in the hallucination until toggled off")

                Button("SCHEDULE…") { showSchedule = true }
                    .buttonStyle(HEButtonStyle())
                    .help("different logos for different timeslots")

                Spacer()

                Button("RESET FLASH") { engine.resetFlash() }
                    .buttonStyle(HEButtonStyle())
                    .disabled(!engine.connected)
                    .help("noise-burst reset of the feedback loop (panic button)")
                Button("CAPTURE") { engine.capture() }
                    .buttonStyle(HEButtonStyle())
                    .disabled(!engine.connected)
                Button("FULLSCREEN") { engine.fullscreen() }
                    .buttonStyle(HEButtonStyle())
                    .disabled(!engine.connected)
                Button("RETUNE BPM") { engine.setBpm(nil) }
                    .buttonStyle(HEButtonStyle())
                    .disabled(!engine.connected)
                    .help("clear any BPM override and re-detect")
            }
        }
        .sheet(isPresented: $showSchedule) { LogoScheduleView() }
        .onChange(of: engine.stats?.logoOpacity) { _, v in
            if !draggingOpacity, let v { opacity = v }
        }
    }

    private func pickLogo() {
        if let url = chooseFile([.image]) { engine.setLogoPath(url.path) }
    }
}

struct LogoScheduleView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var slots: [LogoSlot] = []

    var body: some View {
        VStack(spacing: 10) {
            Text("LOGO SCHEDULE").font(HE.label).tracking(2)
            Text("Wall clock, HH:mm - end before start wraps past midnight. "
                 + "The active slot's logo overrides the manual pick.")
                .font(.caption).foregroundStyle(HE.textDim)

            List {
                ForEach($slots) { $slot in
                    HStack(spacing: 8) {
                        TextField("20:00", text: $slot.start)
                            .textFieldStyle(.roundedBorder).frame(width: 64)
                            .foregroundStyle(LogoSlot.minutes(slot.start) == nil
                                             ? HE.danger : .primary)
                        Text("-").foregroundStyle(.secondary)
                        TextField("22:30", text: $slot.end)
                            .textFieldStyle(.roundedBorder).frame(width: 64)
                            .foregroundStyle(LogoSlot.minutes(slot.end) == nil
                                             ? HE.danger : .primary)
                        Button { pick(into: slot.id) } label: {
                            Label(slot.path.isEmpty ? "choose logo"
                                    : (slot.path as NSString).lastPathComponent,
                                  systemImage: "photo")
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            slots.removeAll { $0.id == slot.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button("ADD SLOT") { slots.append(LogoSlot()) }.buttonStyle(HEButtonStyle())
                Spacer()
                Button("DONE") {
                    engine.logoSlots = slots
                    dismiss()
                }
                .buttonStyle(HEButtonStyle(prominent: true))
            }
        }
        .padding(16)
        .frame(width: 540, height: 340)
        .background(HE.bg)
        .onAppear { slots = engine.logoSlots }
    }

    private func pick(into id: UUID) {
        if let url = chooseFile([.image]),
           let i = slots.firstIndex(where: { $0.id == id }) {
            slots[i].path = url.path
        }
    }
}

// ------------------------------------------------------------------- stats

struct StatsFooter: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let s = engine.stats
        HStack(spacing: 6) {
            Chip(label: "diff", value: String(format: "%.1f fps", s?.fpsDiff ?? 0),
                 warn: (s?.fpsDiff ?? 9) < 3.0)
            Chip(label: "disp", value: String(format: "%.0f fps", s?.fpsDisp ?? 0),
                 warn: (s?.fpsDisp ?? 60) < 45)
            Chip(label: "locked", value: String(format: "%.0f%%", (s?.lockedPct ?? 0) * 100),
                 warn: (s?.lockedPct ?? 0) > 0.35)
            Chip(label: "drops", value: "\(s?.drops ?? 0)")
            Chip(label: "resets", value: "\(s?.resets ?? 0)")
            Chip(label: "frames", value: "\(s?.frames ?? 0)")
            Chip(label: "cpu", value: String(format: "%.0f%%", s?.cpuPct ?? 0),
                 warn: (s?.cpuPct ?? 0) > 300)
            Chip(label: "ram", value: String(format: "%.1f GB", (s?.rssMb ?? 0) / 1000))
        }
    }
}

// --------------------------------------------------------------------- log

struct LogView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(engine.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(HE.mono(10))
                            .foregroundStyle(HE.textDim)
                            .id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 130)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)))
            .onChange(of: engine.logLines.count) { _, n in
                proxy.scrollTo(n - 1, anchor: .bottom)
            }
        }
    }
}
