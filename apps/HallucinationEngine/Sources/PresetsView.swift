import AppKit
import SwiftUI

/// One structured engine-override knob surfaced in the preset editor. Values
/// live in the preset's "config" dict (merged over config.yaml at launch);
/// disabled = key absent = engine default.
private struct OverrideKnob: Identifiable {
    let id: String
    let path: [String]
    let range: ClosedRange<Double>
    let fmt: String
    let def: Double
    let help: String
}

private let overrideKnobs: [OverrideKnob] = [
    .init(id: "STRENGTH", path: ["diffusion", "strength_base"], range: 0.25...0.65,
          fmt: "%.2f", def: 0.48,
          help: "trip intensity - 0.25 frozen, 0.65 dissolving"),
    .init(id: "IDLE NOISE", path: ["diffusion", "noise_idle"], range: 0.0...0.08,
          fmt: "%.3f", def: 0.03,
          help: "per-frame anti-attractor noise floor - raise to 0.05 for dark presets"),
    .init(id: "SATURATION", path: ["diffusion", "servo", "sat_target"], range: 0.1...0.7,
          fmt: "%.2f", def: 0.5,
          help: "color servo target - drop to ~0.22 for mono presets or they turn neon"),
    .init(id: "PHRASE BARS", path: ["scenes", "phrase_bars"], range: 2...16,
          fmt: "%.0f", def: 8,
          help: "bars per scene - 4 is snappy, 8 hypnotic"),
    .init(id: "TRAIL", path: ["display", "trail_base"], range: 0.0...0.6,
          fmt: "%.2f", def: 0.25,
          help: "smear amount in the 60fps composite layer"),
]

/// Prompt-preset manager: CRUD on <repo>/presets/*.json, shared with the
/// engine (--preset / scenes.preset). Scenes + weights, negative prompt, and
/// the preset's engine-config overrides - structured knobs or raw JSON.
struct PresetsView: View {
    @EnvironmentObject var engine: Engine
    @State private var files: [URL] = []
    @State private var names: [URL: String] = [:]  // decoded once per reload
    @State private var selected: URL?
    @State private var editing = PromptPreset()
    @State private var loadedFrom: URL?
    @State private var saved = PromptPreset()
    @State private var config: [String: Any] = [:]
    @State private var savedConfigJSON = "{}"
    @State private var confirmDelete = false
    @State private var showRawConfig = false
    @State private var saveError: String?
    @State private var zoomed: PromptScene?
    @Environment(\.openWindow) private var openWindow

    private var dirty: Bool { editing != saved || configJSON() != savedConfigJSON }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, maxWidth: 250)
            if selected == nil {
                VStack {
                    Spacer()
                    Text("select a preset - or create one with ＋")
                        .font(HE.data).foregroundStyle(HE.textFaint)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            } else {
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(HE.bg)
        .onAppear(perform: reload)
        .sheet(isPresented: $showRawConfig) { rawConfigSheet }
        .sheet(item: $zoomed) { scene in
            ThumbZoomView(prompt: scene.prompt,
                          path: engine.thumbPath(prompt: scene.prompt))
        }
    }

    /// Kick off thumbnail generation for any scene without a cached frame -
    /// silently skipped while something else owns the GPU.
    private func autoThumbs() {
        guard let url = loadedFrom, canThumb else { return }
        let missing = editing.scenes.contains {
            !$0.prompt.isEmpty
                && !FileManager.default.fileExists(atPath: engine.thumbPath(prompt: $0.prompt))
        }
        if missing { engine.renderThumbs(preset: url, force: false) }
    }

    // -------------------------------------------------------------- sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(files, id: \.self, selection: Binding(
                get: { selected },
                set: { sel in if let sel { open(sel) } }
            )) { url in
                Text(presetName(url))
                    .font(HE.data)
                    .lineLimit(1)
                    .tag(url)
            }
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 10) {
                Button { create(PromptPreset(
                    name: uniqueName("New Preset"), negative: "",
                    scenes: [PromptScene()])) } label: { Image(systemName: "plus") }
                    .help("new empty preset")
                Button {
                    var copy = editing
                    copy.name = uniqueName(editing.name)
                    // copy the EDITOR's config (incl. unsaved knob changes),
                    // not the stale on-disk block
                    create(copy, config: config, preserving: selected)
                } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(selected == nil)
                    .help("duplicate selected preset")
                Button(role: .destructive) { confirmDelete = true }
                    label: { Image(systemName: "trash") }
                    .disabled(selected == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .background(Color.black.opacity(0.2))
        .confirmationDialog("Delete preset \"\(editing.name)\"?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
        }
    }

    // --------------------------------------------------------------- editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("preset name", text: $editing.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .bold))
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(HE.raised))
                        .frame(maxWidth: 320)
                    Spacer()
                    if dirty {
                        Text("UNSAVED").font(HE.micro).foregroundStyle(HE.amber)
                    }
                    Button("SAVE") { save() }
                        .buttonStyle(HEButtonStyle(prominent: true))
                        .disabled(!dirty || editing.name.trimmingCharacters(
                            in: .whitespaces).isEmpty)
                }
                if let saveError {
                    Text(saveError).font(HE.mono(9)).foregroundStyle(HE.danger)
                }

                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "NEGATIVE PROMPT")
                        Text("applied on every CFG frame - never put style words here "
                             + "(they kill matching scenes)")
                            .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                        TextField("negative prompt", text: $editing.negative, axis: .vertical)
                            .textFieldStyle(.plain).font(HE.data)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(HE.raised))
                            .lineLimit(1...3)
                    }
                }

                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel(text: "ENGINE OVERRIDES")
                            Button("RAW JSON…") { showRawConfig = true }
                                .buttonStyle(HEButtonStyle())
                                .help("full config block - anything config.yaml accepts")
                        }
                        Text("merged over config.yaml when this preset loads. OFF = engine "
                             + "default. Dark presets want idle noise 0.05 + saturation ~0.22.")
                            .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                        ForEach(overrideKnobs) { knob in
                            knobRow(knob)
                        }
                        toggleRow("SCENE STAMPS", path: ["diffusion", "phrase_flash", "guidance"],
                                  onValue: EngineOverride.sceneStampGuidance,
                                  help: "CFG stamp at each phrase - prompt-faithful scene opens")
                        toggleRow("FREEZE HUE", path: ["display", "hue_rate_deg"], onValue: 0.0,
                                  help: "zero the air-energy hue rotation - REQUIRED for "
                                        + "color-brand presets (reds walk to green in seconds)")
                    }
                }

                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel(text: "SCENES (\(editing.scenes.count))")
                            Button("＋ ADD SCENE") { editing.scenes.append(PromptScene()) }
                                .buttonStyle(HEButtonStyle())
                            Button("◉ THUMBS") { thumbs(force: false) }
                                .buttonStyle(HEButtonStyle(tint: HE.plasma))
                                .disabled(!canThumb)
                                .help("render one SD-Turbo frame per scene - a rough "
                                      + "look at what each prompt dreams like")
                            Button("↻") { thumbs(force: true) }
                                .buttonStyle(HEButtonStyle())
                                .disabled(!canThumb)
                                .help("re-roll every thumbnail (new random variations)")
                            Button("PREVIEW…") { openWindow(id: "prompt-preview") }
                                .buttonStyle(HEButtonStyle(tint: HE.plasma))
                                .help("live prompt playground - type and watch it dream")
                        }
                        if engine.thumbsRunning || !engine.thumbsStatus.isEmpty {
                            Text(engine.thumbsStatus)
                                .font(HE.mono(9))
                                .foregroundStyle(engine.thumbsRunning ? HE.plasma : HE.textFaint)
                        }
                        if dirty, loadedFrom != nil {
                            Text("thumbnails render from the SAVED file - save first to "
                                 + "include prompt edits")
                                .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                        }
                        Text("weight = relative pick probability in the random walk")
                            .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                        ForEach($editing.scenes) { $scene in
                            sceneRow($scene)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var canThumb: Bool {
        loadedFrom != nil && !engine.thumbsRunning && !engine.running
            && !engine.renderRunning
    }

    private func thumbs(force: Bool) {
        guard let url = loadedFrom else { return }
        engine.renderThumbs(preset: url, force: force)
    }

    private func sceneRow(_ scene: Binding<PromptScene>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { zoomed = scene.wrappedValue } label: {
                ThumbImage(path: engine.thumbPath(prompt: scene.prompt.wrappedValue),
                           version: engine.thumbsVersion)
            }
            .buttonStyle(.plain)
            .help("view full size")
            TextField("prompt", text: scene.prompt, axis: .vertical)
                .textFieldStyle(.plain).font(HE.data)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(HE.raised))
                .lineLimit(1...4)
            HESlider(value: scene.weight, range: 0...3)
                .frame(width: 90)
                .padding(.top, 4)
            Text(String(format: "%.1f", scene.weight.wrappedValue))
                .font(HE.data).foregroundStyle(HE.textDim)
                .frame(width: 26, alignment: .trailing)
                .padding(.top, 6)
            Button {
                var copy = scene.wrappedValue
                copy.id = UUID()
                if let i = editing.scenes.firstIndex(where: { $0.id == scene.wrappedValue.id }) {
                    editing.scenes.insert(copy, at: i + 1)
                }
            } label: { Image(systemName: "plus.square.on.square") }
                .buttonStyle(.plain).foregroundStyle(HE.textDim)
                .padding(.top, 6)
                .help("duplicate scene")
            Button(role: .destructive) {
                editing.scenes.removeAll { $0.id == scene.wrappedValue.id }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(HE.textDim)
                .padding(.top, 6)
        }
    }

    // ---------------------------------------------------- config overrides

    private func knobRow(_ knob: OverrideKnob) -> some View {
        let current = getPath(config, knob.path) as? Double
            ?? (getPath(config, knob.path) as? Int).map(Double.init)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { current != nil },
                set: { on in setPath(&config, knob.path, on ? knob.def : nil) }
            )).toggleStyle(.checkbox).labelsHidden()
            Text(knob.id).font(HE.label)
                .foregroundStyle(current != nil ? HE.volt : HE.textDim)
                .frame(width: 100, alignment: .leading)
            if current != nil {
                HESlider(value: Binding(
                    get: { current ?? knob.def },
                    set: { setPath(&config, knob.path,
                                   knob.fmt == "%.0f" ? Double(Int($0.rounded())) : $0) }
                ), range: knob.range)
                .frame(width: 170)
                Text(String(format: knob.fmt, current ?? knob.def))
                    .font(HE.data).foregroundStyle(HE.textDim)
                    .frame(width: 44, alignment: .trailing)
            } else {
                Text("engine default").font(HE.mono(9)).foregroundStyle(HE.textFaint)
            }
            Spacer()
        }
        .help(knob.help)
    }

    private func toggleRow(_ name: String, path: [String], onValue: Double,
                           help: String) -> some View {
        let isOn = (getPath(config, path) as? Double) == onValue
            || (getPath(config, path) as? Int).map(Double.init) == onValue
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { setPath(&config, path, $0 ? onValue : nil) }
            )).toggleStyle(.checkbox).labelsHidden()
            Text(name).font(HE.label)
                .foregroundStyle(isOn ? HE.volt : HE.textDim)
                .frame(width: 100, alignment: .leading)
            Text(help).font(HE.mono(9)).foregroundStyle(HE.textFaint).lineLimit(1)
            Spacer()
        }
    }

    private var rawConfigSheet: some View {
        RawConfigEditor(configJSON: configJSON()) { newConfig in
            config = newConfig
        }
    }

    private func configJSON() -> String {
        guard JSONSerialization.isValidJSONObject(config),
              let d = try? JSONSerialization.data(
                withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    // ---------------------------------------------------------------- files

    private func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: engine.presetsDir, withIntermediateDirectories: true)
        let found = ((try? fm.contentsOfDirectory(at: engine.presetsDir,
                                                  includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        // decode each file ONCE - the List and sort re-run per body evaluation
        names = Dictionary(uniqueKeysWithValues: found.map { url in
            let name = (try? JSONDecoder().decode(PromptPreset.self,
                                                  from: Data(contentsOf: url)))?.name
                ?? url.deletingPathExtension().lastPathComponent
            return (url, name)
        })
        files = found.sorted { presetName($0).lowercased() < presetName($1).lowercased() }
        if let sel = selected, !files.contains(sel) { selected = nil }
        engine.refreshPresets()
    }

    private func presetName(_ url: URL) -> String {
        names[url] ?? url.deletingPathExtension().lastPathComponent
    }

    private func open(_ url: URL) {
        guard let d = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(PromptPreset.self, from: d) else { return }
        selected = url
        loadedFrom = url
        editing = p
        saved = p
        config = rawJSON(url)["config"] as? [String: Any] ?? [:]
        savedConfigJSON = configJSON()
        autoThumbs()
    }

    private func slugURL(for name: String) -> URL {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return engine.presetsDir.appendingPathComponent(String(slug) + ".json")
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(files.map { presetName($0).lowercased() })
        if !names.contains(base.lowercased()) { return base }
        for i in 2...99 where !names.contains("\(base) \(i)".lowercased()) {
            return "\(base) \(i)"
        }
        return base + " copy"
    }

    private func rawJSON(_ url: URL?) -> [String: Any] {
        guard let url, let d = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return [:] }
        return o
    }

    /// Writes name/negative/scenes/config while PRESERVING keys the editor
    /// doesn't model from `source`.
    private func write(_ preset: PromptPreset, config cfg: [String: Any]?,
                       to url: URL, preserving source: URL?) -> Bool {
        var obj = rawJSON(source)
        obj["name"] = preset.name
        obj["negative"] = preset.negative
        obj["scenes"] = preset.scenes.map { ["prompt": $0.prompt, "weight": $0.weight] }
        if let cfg {
            if cfg.isEmpty { obj.removeValue(forKey: "config") } else { obj["config"] = cfg }
        }
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              (try? d.write(to: url, options: .atomic)) != nil else { return false }
        return true
    }

    private func create(_ preset: PromptPreset, config cfg: [String: Any]? = nil,
                        preserving source: URL? = nil) {
        let url = slugURL(for: preset.name)
        // distinct names can slug to the same filename - never clobber another
        // preset silently
        guard !FileManager.default.fileExists(atPath: url.path) else {
            saveError = "\"\(preset.name)\" maps to \(url.lastPathComponent), "
                + "which already exists - pick another name"
            return
        }
        saveError = nil
        guard write(preset, config: cfg, to: url, preserving: source) else { return }
        reload()
        open(url)
    }

    private func save() {
        let url = slugURL(for: editing.name)
        if url != loadedFrom, FileManager.default.fileExists(atPath: url.path) {
            saveError = "\"\(editing.name)\" maps to \(url.lastPathComponent), "
                + "which is another preset's file - pick another name"
            return
        }
        saveError = nil
        guard write(editing, config: config, to: url, preserving: loadedFrom) else { return }
        if let old = loadedFrom, old != url {
            try? FileManager.default.removeItem(at: old)
        }
        loadedFrom = url
        saved = editing
        savedConfigJSON = configJSON()
        reload()
        selected = url
        autoThumbs()  // new/edited prompts hash to new, missing thumbs
    }

    private func deleteSelected() {
        guard let sel = selected else { return }
        try? FileManager.default.removeItem(at: sel)
        selected = nil
        loadedFrom = nil
        editing = PromptPreset()
        saved = editing
        config = [:]
        savedConfigJSON = "{}"
        reload()
    }
}

// ------------------------------------------------------------ nested paths

private func getPath(_ dict: [String: Any], _ path: [String]) -> Any? {
    var cur: Any? = dict
    for key in path {
        cur = (cur as? [String: Any])?[key]
    }
    return cur
}

/// Sets (or, with nil, removes) a nested value, pruning empty parents.
private func setPath(_ dict: inout [String: Any], _ path: [String], _ value: Any?) {
    guard let key = path.first else { return }
    if path.count == 1 {
        if let value { dict[key] = value } else { dict.removeValue(forKey: key) }
        return
    }
    var child = dict[key] as? [String: Any] ?? [:]
    setPath(&child, Array(path.dropFirst()), value)
    if child.isEmpty { dict.removeValue(forKey: key) } else { dict[key] = child }
}

// ---------------------------------------------------------- raw JSON sheet

private struct RawConfigEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var configJSON: String
    @State private var error: String?
    let apply: ([String: Any]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "ENGINE CONFIG OVERRIDES - RAW JSON")
            Text("any config.yaml key works here (collapse thresholds, servo rates, drop "
                 + "tuning…). Keep logo.path OUT - the app's LOGO row owns it.")
                .font(HE.mono(9)).foregroundStyle(HE.textFaint)
            TextEditor(text: $configJSON)
                .font(HE.mono(11))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45)))
            if let error {
                Text(error).font(HE.mono(9)).foregroundStyle(HE.danger)
            }
            HStack {
                Spacer()
                Button("CANCEL") { dismiss() }.buttonStyle(HEButtonStyle())
                Button("APPLY") {
                    guard let d = configJSON.data(using: .utf8),
                          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                    else { error = "not valid JSON (must be an object at the top level)"; return }
                    apply(o)
                    dismiss()
                }
                .buttonStyle(HEButtonStyle(prominent: true))
            }
        }
        .padding(16)
        .frame(width: 560, height: 460)
        .background(HE.bg)
    }
}
