import AppKit
import CryptoKit
import Foundation
import Network
import SwiftUI

/// Owns the Python engine process and the JSON/TCP control link.
@MainActor
final class Engine: ObservableObject {
    @Published var stats: Stats?
    @Published var scenes: [String] = []
    @Published var weights: [Double] = []
    @Published var running = false
    @Published var connected = false
    @Published var logLines: [String] = []
    @Published var mixPath: String = ""
    @Published var seek: String = "0:00"
    @Published var liveDevice: String = ""   // empty = file mode
    @Published var autoRestart = true
    @Published var restarts = 0

    // render mode
    @Published var renderRunning = false
    @Published var renderProgress = 0.0
    @Published var renderEta = 0.0
    @Published var renderSpeed = 0.0
    @Published var renderDonePath: String?
    @Published var renderError: String?
    @Published var previewPath: String?
    private var renderIsPreview = false

    // named audio inputs (live mode source picker)
    @Published var inputDevices: [AudioDevice] = []

    // preset names cache - @AppStorage/@computed don't publish, and menus
    // re-evaluate at 5 Hz; scan the dir once and on explicit refresh instead
    @Published var presetNames: [String] = []

    // prompt preset used for the next launch ("" = config default)
    @AppStorage("promptPreset") var promptPreset = ""

    // logo
    @Published var logoHold = false
    @AppStorage("logoPath") var logoPath = ""
    @AppStorage("logoEnabled") var logoEnabled = false
    @AppStorage("logoSlots") private var logoSlotsJSON = "[]"

    @AppStorage("repoPath") var repoPath = Engine.defaultRepoPath

    /// The app normally lives at <repo>/apps/HallucinationEngine/dist/ -
    /// walk up to the repo root, or fall back to a home-dir checkout.
    static let defaultRepoPath: String = {
        let root = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()   // dist
            .deletingLastPathComponent()   // HallucinationEngine
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // repo
        if FileManager.default.fileExists(atPath: root.path + "/main.py") {
            return root.path
        }
        return NSHomeDirectory() + "/hallucination-engine"
    }()
    @AppStorage("recentMixes") private var recentMixesJSON = "[]"

    private var renderProc: Process?
    private var process: Process?
    private var conn: NWConnection?
    private var rxBuffer = Data()
    private var userStopped = false
    private var startedAt = Date()
    private var keyMonitor: Any?
    private let port: UInt16 = 7788

    init() {
        mixPath = recentMixes.first ?? ""
        refreshPresets()
        // space means DROP while a set is live - but never while the user is
        // typing (prompts/names/cues are legitimate space-bearing text)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.keyCode == 49, self.connected,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return ev }
            self.drop()
            return nil
        }
    }

    /// Publishing setters - @AppStorage inside an ObservableObject writes
    /// UserDefaults but never fires objectWillChange on its own.
    func selectPreset(_ name: String) {
        objectWillChange.send()
        promptPreset = name
    }

    func rememberMix(_ path: String) {
        objectWillChange.send()
        var r = recentMixes.filter { $0 != path }
        r.insert(path, at: 0)
        recentMixes = r
    }

    var recentMixes: [String] {
        get { (try? JSONDecoder().decode([String].self,
                                         from: Data(recentMixesJSON.utf8))) ?? [] }
        set {
            let d = (try? JSONEncoder().encode(Array(newValue.prefix(10)))) ?? Data("[]".utf8)
            recentMixesJSON = String(decoding: d, as: UTF8.self)
        }
    }

    // -------------------------------------------------------------- process

    func start() {
        guard !running else { return }
        guard !renderRunning else { log("wait for the render to finish - shared GPU"); return }
        stopPromptServer()  // shared GPU
        userStopped = false
        NSApp.keyWindow?.makeFirstResponder(nil)  // free the spacebar
        launch()
    }

    private func launch() {
        let p = Process()
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        p.executableURL = URL(fileURLWithPath: repoPath + "/.venv/bin/python")
        var args = ["main.py", "--no-panel", "--control-port", "\(port)"]
        if !promptPreset.isEmpty { args += ["--preset", promptPreset] }
        if let dev = Int(liveDevice) {
            args += ["--device", "\(dev)"]
        } else {
            guard !mixPath.isEmpty else { log("pick a mix first"); return }
            args += ["--file", mixPath, "--seek", seek.isEmpty ? "0" : seek]
            rememberMix(mixPath)
        }
        p.arguments = args

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.log(text) }
        }
        p.terminationHandler = { [weak self] proc in
            // disarm, or the EOF'd fd re-fires the handler forever
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.processEnded(status: proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
            running = true
            startedAt = Date()
            log("engine started (pid \(p.processIdentifier))")
            connectSoon(delay: 2.0)
        } catch {
            log("launch failed: \(error.localizedDescription)")
        }
    }

    private func processEnded(status: Int32) {
        running = false
        connected = false
        conn?.cancel()
        conn = nil
        stats = nil
        log("engine exited (status \(status))")
        // 8-hour-set insurance: relaunch on unexpected death, but never crash-loop
        if autoRestart, !userStopped, Date().timeIntervalSince(startedAt) > 30 {
            restarts += 1
            log("auto-restarting engine ...")
            launch()
        }
    }

    func stop() {
        userStopped = true
        if connected { send(["cmd": "quit"]) }
        let p = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if let p, p.isRunning { p.terminate() }
        }
    }

    // ------------------------------------------------------------- socket

    private func connectSoon(delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func connect() {
        guard running, !connected else { return }
        let c = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.connected = true
                    self.log("control link up")
                    self.receive(on: c)
                case .waiting:
                    // refused: engine still loading the model. NWConnection
                    // parks in .waiting forever on localhost - cancel and let
                    // .cancelled schedule the retry
                    c.cancel()
                case .failed, .cancelled:
                    self.connected = false
                    if self.running { self.connectSoon(delay: 1.0) }
                default: break
                }
            }
        }
        c.start(queue: .main)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, done, _ in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.ingest(data) }
                if done {
                    self.connected = false
                    if self.running { self.connectSoon(delay: 1.0) }
                } else {
                    self.receive(on: c)
                }
            }
        }
    }

    private func ingest(_ data: Data) {
        rxBuffer.append(data)
        while let nl = rxBuffer.firstIndex(of: 0x0A) {
            let line = rxBuffer[rxBuffer.startIndex..<nl]
            rxBuffer.removeSubrange(rxBuffer.startIndex...nl)
            handle(Data(line))
        }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        if type == "hello" {
            scenes = obj["scenes"] as? [String] ?? []
            weights = (obj["weights"] as? [Double])
                ?? (obj["weights"] as? [NSNumber])?.map(\.doubleValue) ?? []
            pushLogo()  // engine boots with config defaults (logo off) - restore ours
        } else if type == "stats" {
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            if let s = try? dec.decode(Stats.self, from: line) { stats = s }
            applyLogoSchedule()
        }
    }

    // ------------------------------------------------------------ commands

    func send(_ dict: [String: Any]) {
        guard connected, let c = conn,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        c.send(content: data + Data([0x0A]), completion: .contentProcessed { _ in })
    }

    func drop()            { send(["cmd": "drop"]) }
    func skipScene()       { send(["cmd": "skip"]) }
    func resetFlash()      { send(["cmd": "reset"]) }
    func capture()         { send(["cmd": "capture"]) }
    func fullscreen()      { send(["cmd": "fullscreen"]) }
    func setOffset(_ v: Double)          { send(["cmd": "offset", "value": v]) }
    func setParam(_ path: String, _ v: Double) { send(["cmd": "set", "path": path, "value": v]) }
    func setBpm(_ v: Double?)            { send(["cmd": "bpm", "value": v as Any]) }
    func playScene(_ i: Int)             { send(["cmd": "scene_select", "index": i]) }
    func pushWeights() {
        send(["cmd": "weights", "values": weights])
    }
    func applyPreset(_ p: Preset) {
        weights = p.weights(for: scenes)
        pushWeights()
    }

    // -------------------------------------------------------------- presets

    var presetsDir: URL { URL(fileURLWithPath: repoPath + "/presets") }

    /// Rescan <repo>/presets/*.json into the presetNames cache - called at
    /// init and whenever the PRESETS tab writes a file.
    func refreshPresets() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: presetsDir,
                                                 includingPropertiesForKeys: nil)) ?? []
        presetNames = files.filter { $0.pathExtension == "json" }.compactMap {
            guard let d = try? Data(contentsOf: $0),
                  let p = try? JSONDecoder().decode(PromptPreset.self, from: d)
            else { return nil }
            return p.name
        }.sorted()
    }

    // ---------------------------------------------------------------- logo

    var logoSlots: [LogoSlot] {
        get { (try? JSONDecoder().decode([LogoSlot].self,
                                         from: Data(logoSlotsJSON.utf8))) ?? [] }
        set {
            let d = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            logoSlotsJSON = String(decoding: d, as: UTF8.self)
            objectWillChange.send()
            applyLogoSchedule()
        }
    }

    func pushLogo() {
        send(["cmd": "set", "path": "logo.path", "value": logoPath])
        send(["cmd": "set", "path": "logo.enable", "value": logoEnabled])
        send(["cmd": "logo_hold", "value": logoHold])
    }

    func setLogoPath(_ p: String) {
        logoPath = p
        objectWillChange.send()  // @AppStorage in an ObservableObject doesn't publish
        pushLogo()
    }

    func setLogoEnabled(_ on: Bool) {
        logoEnabled = on
        objectWillChange.send()
        pushLogo()
    }

    func setLogoHold(_ on: Bool) {
        logoHold = on
        send(["cmd": "logo_hold", "value": on])
    }

    /// Called on every stats frame: while a schedule slot is active its logo
    /// wins over the manual pick (and sticks after the slot ends until the
    /// next slot or a manual change).
    func applyLogoSchedule() {
        guard logoSlotsJSON != "[]" else { return }  // 5 Hz caller, common case
        let cal = Calendar.current
        let now = cal.component(.hour, from: Date()) * 60
            + cal.component(.minute, from: Date())
        guard let slot = logoSlots.first(where: { $0.contains(minuteOfDay: now) }),
              slot.path != logoPath else { return }
        setLogoPath(slot.path)
    }

    // -------------------------------------------------------------- render

    /// Overlay config with ONLY the job's non-default overrides - no
    /// overrides, no file, and the engine runs exactly its stock config.
    /// Emitted as JSON (valid YAML for yaml.safe_load) so escaping and
    /// nesting come from JSONSerialization, not hand-built strings. The
    /// renderer itself mutes the drop heuristic when drop_times is present.
    private func overlayConfig(_ job: RenderJob) -> [String: Any] {
        var cfg: [String: Any] = [:]
        var render: [String: Any] = [:]
        if !job.dropCues.isEmpty { render["drop_times"] = job.dropCues.sorted() }
        if job.quality == .ultra { render["bitrate"] = "20M" }
        if !render.isEmpty { cfg["render"] = render }
        if let bpm = job.bpmOverride {
            cfg["tempo"] = ["bpm_override": bpm]
        }
        if job.logo.enabled, !job.logo.path.isEmpty {
            cfg["logo"] = ["enable": true,
                           "path": job.logo.path,
                           "opacity": job.logo.opacity,
                           "scale": job.logo.scale,
                           "drop_chance": job.logo.dropChance,
                           "flash_seconds": job.logo.flashSeconds]
        }
        var diffusion: [String: Any] = [:]
        if job.quality == .ultra { diffusion["taesd"] = false }  // full SD VAE decode
        if job.flavors.sceneStamps {
            diffusion["phrase_flash"] = ["guidance": EngineOverride.sceneStampGuidance]
        }
        if job.flavors.swirl { diffusion["swirl_amount"] = EngineOverride.swirlAmount }
        if job.flavors.antiLock {
            diffusion["noise_idle"] = EngineOverride.antiLockNoise
            diffusion["collapse"] = ["anisotropy_max": EngineOverride.antiLockAniso,
                                     "grid_max": EngineOverride.antiLockGrid]
        }
        if !diffusion.isEmpty { cfg["diffusion"] = diffusion }
        var scenes: [String: Any] = [:]
        if job.flavors.shortPhrases { scenes["phrase_bars"] = EngineOverride.shortPhraseBars }
        if job.flavors.hybrids { scenes["hybrid_chance"] = EngineOverride.hybridChance }
        if !scenes.isEmpty { cfg["scenes"] = scenes }
        return cfg
    }

    func startRender(job: RenderJob, preview: Bool = false) {
        guard !renderRunning else { return }
        guard !running else { renderError = "stop the live set first - they share the GPU"; return }
        stopPromptServer()  // shared GPU
        renderError = nil
        renderDonePath = nil
        if preview { previewPath = nil }
        renderIsPreview = preview
        renderProgress = 0
        renderEta = 0
        renderSpeed = 0

        let geo = job.format.geometry(job.quality)
        let p = Process()
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        p.executableURL = URL(fileURLWithPath: repoPath + "/.venv/bin/python")
        var args = ["main.py", "--file", job.mix, "--render", job.out,
                    "--render-fps", "\(job.fps)", "--render-size", "\(geo.size)",
                    "--render-diff-fps", String(format: "%.1f", job.diffFps)]
        if geo.w != geo.size || geo.h != geo.size {
            args += ["--render-crop", "\(geo.w)x\(geo.h)"]
        }
        if !promptPreset.isEmpty { args += ["--preset", promptPreset] }
        if !job.seek.isEmpty { args += ["--seek", job.seek] }
        if !job.duration.isEmpty { args += ["--render-duration", job.duration] }
        let overlay = overlayConfig(job)
        if !overlay.isEmpty {
            // per-job filename: two app instances (or a future concurrent
            // preview) must not read each other's overlay
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("he_overlay_\(UUID().uuidString).json")
            do {
                let data = try JSONSerialization.data(withJSONObject: overlay,
                                                      options: [.prettyPrinted])
                try data.write(to: url)
                args += ["--config", url.path]
            } catch {
                renderError = "could not write overlay config: \(error.localizedDescription)"
                return
            }
        }
        p.arguments = args

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.log(text)
                self?.parseRender(text)
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.renderRunning = false
                if proc.terminationStatus != 0, self.renderDonePath == nil,
                   self.renderError == nil {
                    self.renderError = "render exited with status \(proc.terminationStatus) - see Log"
                }
            }
        }
        do {
            try p.run()
            renderProc = p
            renderRunning = true
            log("render started (pid \(p.processIdentifier))")
        } catch {
            renderError = "launch failed: \(error.localizedDescription)"
        }
    }

    func cancelRender() {
        renderError = "cancelled"
        renderProc?.terminate()
    }

    private func parseRender(_ text: String) {
        for line in text.split(separator: "\n") where line.hasPrefix("[render]") {
            if line.contains(" done ") {
                // "[render] done /path/to/file.mp4 (600 frames, ...)"
                if let range = line.range(of: " done ") {
                    let rest = line[range.upperBound...]
                    let path = String(rest.split(separator: " (").first ?? "")
                    if renderIsPreview { previewPath = path } else { renderDonePath = path }
                }
                renderProgress = 1.0
                renderEta = 0
            } else if let pct = capture(line, #"([\d.]+)%"#) {
                renderProgress = (Double(pct) ?? 0) / 100.0
                if let eta = capture(line, #"eta=(\d+)s"#) { renderEta = Double(eta) ?? 0 }
                if let sp = capture(line, #"speed=([\d.]+)x"#) { renderSpeed = Double(sp) ?? 0 }
            }
        }
    }

    private func capture(_ line: Substring, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let s = String(line)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    // --------------------------------------------------------------- thumbs

    @Published var thumbsRunning = false
    @Published var thumbsStatus = ""
    @Published var thumbsVersion = 0  // bump -> ThumbImage views re-read disk

    var thumbsDir: String { repoPath + "/presets/.thumbs" }

    /// Cache path for one prompt's thumbnail - sha1 prefix, must match
    /// hallucination_engine/thumbs.py thumb_name().
    func thumbPath(prompt: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(prompt.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        return repoPath + "/presets/.thumbs/" + digest + ".png"
    }

    /// One SD-Turbo frame per scene of a preset FILE (save first - reads
    /// disk). GPU-shared with the engine: refuses while live or rendering.
    func renderThumbs(preset url: URL, force: Bool) {
        guard !thumbsRunning else { return }
        guard !running, !renderRunning else {
            thumbsStatus = "GPU busy - stop the set/render first"
            return
        }
        stopPromptServer()  // shared GPU
        thumbsRunning = true
        thumbsStatus = "loading model…"
        let p = Process()
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        p.executableURL = URL(fileURLWithPath: repoPath + "/.venv/bin/python")
        var args = ["-m", "hallucination_engine.thumbs", url.path, thumbsDir]
        if force { args.append("--force") }
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                for line in text.split(separator: "\n") where line.hasPrefix("[thumbs]") {
                    self.thumbsStatus = String(line.dropFirst(9))
                    if line.contains("/") { self.thumbsVersion += 1 }  // live refresh
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.thumbsRunning = false
                if proc.terminationStatus != 0 {
                    self.thumbsStatus = "thumbnail run failed (status \(proc.terminationStatus))"
                }
                self.thumbsVersion += 1
            }
        }
        do { try p.run() } catch {
            thumbsRunning = false
            thumbsStatus = "launch failed: \(error.localizedDescription)"
        }
    }

    // ------------------------------------------------------- prompt preview

    @Published var promptServerState = ""      // "" = off
    @Published var promptFrameFile: String?
    @Published var promptFrameN = 0
    private var promptProc: Process?
    private var promptStdin: FileHandle?
    private var promptPending: (String, Int)?  // latest request while busy
    private var promptBusy = false

    var promptServerReady: Bool { promptProc != nil && !promptServerState.isEmpty
        && promptServerState != "loading model…" }

    /// Resident SD-Turbo txt2img process for the Prompt Preview window.
    func startPromptServer() {
        guard promptProc == nil else { return }
        guard !running, !renderRunning, !thumbsRunning else {
            promptServerState = "GPU busy - stop the set/render first"
            return
        }
        promptServerState = "loading model…"
        let p = Process()
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        p.executableURL = URL(fileURLWithPath: repoPath + "/.venv/bin/python")
        p.arguments = ["-m", "hallucination_engine.prompt_server"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                for line in text.split(separator: "\n") {
                    guard let obj = try? JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any] else { continue }
                    if obj["ready"] as? Bool == true {
                        self.promptServerState = "ready"
                    } else if let file = obj["file"] as? String {
                        self.promptFrameFile = file
                        self.promptFrameN = obj["n"] as? Int ?? self.promptFrameN + 1
                        self.promptBusy = false
                        self.promptServerState = "ready"
                        if let (prompt, seed) = self.promptPending {
                            self.promptPending = nil
                            self.previewPrompt(prompt, seed: seed)
                        }
                    }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.promptProc = nil
                self.promptStdin = nil
                self.promptBusy = false
                self.promptServerState = ""
            }
        }
        do {
            try p.run()
            promptProc = p
            promptStdin = inPipe.fileHandleForWriting
        } catch {
            promptServerState = "launch failed: \(error.localizedDescription)"
        }
    }

    func stopPromptServer() {
        promptStdin = nil
        promptProc?.terminate()
    }

    /// Dream one frame. Requests while a frame is in flight are coalesced -
    /// only the latest queued prompt renders next.
    func previewPrompt(_ prompt: String, seed: Int) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let h = promptStdin, !trimmed.isEmpty else { return }
        if promptBusy {
            promptPending = (trimmed, seed)
            return
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["prompt": trimmed, "seed": seed]) else { return }
        promptBusy = true
        promptServerState = "dreaming…"
        try? h.write(contentsOf: data + Data([0x0A]))
    }

    // -------------------------------------------------------------- devices

    /// Enumerate named audio inputs via the engine's own venv/sounddevice, so
    /// indices are exactly what --device expects (PortAudio order, not CoreAudio).
    func refreshInputDevices() {
        let code = "import sounddevice as sd, json; " +
            "print(json.dumps([{'i': i, 'name': d['name'], 'ch': d['max_input_channels']} " +
            "for i, d in enumerate(sd.query_devices()) if d['max_input_channels'] > 0]))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: repoPath + "/.venv/bin/python")
        p.arguments = ["-c", code]
        let pipe = Pipe()
        p.standardOutput = pipe
        // discard, don't buffer: verbose CoreAudio warnings can fill an
        // undrained pipe and deadlock the child before it ever exits
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let devs = (try? JSONDecoder().decode([AudioDevice].self, from: data)) ?? []
            Task { @MainActor in self?.inputDevices = devs }
        }
        try? p.run()
    }

    // ----------------------------------------------------------------- log

    private func log(_ text: String) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            logLines.append(String(raw))
        }
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}
