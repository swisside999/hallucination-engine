import Foundation

/// The single source of truth for what each named style flavor / override
/// means in engine-config terms - used by the RENDER tab overlay writer and
/// the PRESETS tab knobs alike.
enum EngineOverride {
    static let sceneStampGuidance = 3.0   // diffusion.phrase_flash.guidance
    static let shortPhraseBars = 4        // scenes.phrase_bars
    static let hybridChance = 0.15        // scenes.hybrid_chance
    static let swirlAmount = 0.05         // diffusion.swirl_amount
    static let antiLockNoise = 0.05       // diffusion.noise_idle
    static let antiLockAniso = 0.28       // diffusion.collapse.anisotropy_max
    static let antiLockGrid = 0.44        // diffusion.collapse.grid_max
}

/// "MM:SS", "H:MM:SS" or plain seconds ("80.4") -> seconds. nil = malformed.
func parseClock(_ s: String) -> Double? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        .map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard !parts.contains(where: { $0 == nil }) else { return nil }
    return parts.compactMap { $0 }.reversed().enumerated()
        .reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
}

/// One stats frame from the engine (~5 Hz). Keys arrive snake_case. Decoding
/// is per-field tolerant: a missing key falls back to its default instead of
/// failing the whole frame (version skew must not freeze the cockpit).
struct Stats: Decodable {
    var bpm: Double = 0
    var beatPhase: Double = 0
    var phrasePhase: Double = 0
    var phraseIndex: Int = 0
    var scene: String = ""
    var sceneId: Int = 0
    var sceneNext: String = ""
    var strength: Double = 0
    var offset: Double = 0
    var tension: Double = 0
    var kick: Double = 0
    var perc: Double = 0
    var synth: Double = 0
    var air: Double = 0
    var rms: Double = 0
    var fpsDiff: Double = 0
    var fpsDisp: Double = 0
    var pos: Double = 0
    var dur: Double = 0
    var stripe: Double = 0
    var grid: Double = 0
    var lockedPct: Double = 0
    var drops: Int = 0
    var resets: Int = 0
    var frames: Int = 0
    var cpuPct: Double = 0
    var rssMb: Double = 0
    var uptime: Double = 0
    var trail: Double = 0
    var strobe: Double = 0
    var zoom: Double = 0
    var noise: Double = 0
    var logo: Double = 0
    var logoOpacity: Double = 0

    enum CodingKeys: String, CodingKey {
        case bpm, beatPhase, phrasePhase, phraseIndex, scene, sceneId, sceneNext
        case strength, offset, tension, kick, perc, synth, air, rms
        case fpsDiff, fpsDisp, pos, dur, stripe, grid, lockedPct
        case drops, resets, frames, cpuPct, rssMb, uptime
        case trail, strobe, zoom, noise, logo, logoOpacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? 0 }
        func i(_ k: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: k)) ?? 0 }
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        bpm = d(.bpm); beatPhase = d(.beatPhase); phrasePhase = d(.phrasePhase)
        phraseIndex = i(.phraseIndex); scene = s(.scene); sceneId = i(.sceneId)
        sceneNext = s(.sceneNext); strength = d(.strength); offset = d(.offset)
        tension = d(.tension); kick = d(.kick); perc = d(.perc); synth = d(.synth)
        air = d(.air); rms = d(.rms); fpsDiff = d(.fpsDiff); fpsDisp = d(.fpsDisp)
        pos = d(.pos); dur = d(.dur); stripe = d(.stripe); grid = d(.grid)
        lockedPct = d(.lockedPct); drops = i(.drops); resets = i(.resets)
        frames = i(.frames); cpuPct = d(.cpuPct); rssMb = d(.rssMb)
        uptime = d(.uptime); trail = d(.trail); strobe = d(.strobe)
        zoom = d(.zoom); noise = d(.noise); logo = d(.logo)
        logoOpacity = d(.logoOpacity)
    }
}

/// One logo-schedule row: this logo is active from start to end (wall clock,
/// "HH:mm"; end < start wraps past midnight - rave sets do).
struct LogoSlot: Codable, Identifiable, Equatable {
    var id = UUID()
    var start = "20:00"
    var end = "22:30"
    var path = ""

    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    func contains(minuteOfDay now: Int) -> Bool {
        guard let a = Self.minutes(start), let b = Self.minutes(end), !path.isEmpty
        else { return false }
        return a <= b ? (now >= a && now < b) : (now >= a || now < b)
    }
}

/// One scene inside a prompt preset file.
struct PromptScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var prompt = ""
    var weight = 1.0

    enum CodingKeys: String, CodingKey { case prompt, weight }

    init(prompt: String = "", weight: Double = 1.0) {
        self.prompt = prompt
        self.weight = weight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1.0
    }
}

/// A prompt preset - one JSON file in <repo>/presets, shared with the engine
/// (`--preset <name>` / `scenes.preset` in config.yaml).
struct PromptPreset: Codable, Equatable {
    var name = "New Preset"
    var negative = ""
    var scenes: [PromptScene] = []

    enum CodingKeys: String, CodingKey { case name, negative, scenes }

    init(name: String = "New Preset", negative: String = "", scenes: [PromptScene] = []) {
        self.name = name
        self.negative = negative
        self.scenes = scenes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "unnamed"
        negative = try c.decodeIfPresent(String.self, forKey: .negative) ?? ""
        scenes = try c.decodeIfPresent([PromptScene].self, forKey: .scenes) ?? []
    }
}

/// A scene-weight preset: ordered keyword rules, first match wins.
struct Preset: Identifiable {
    let id: String
    let name: String
    let rules: [(keywords: [String], weight: Double)]
    let fallback: Double

    func weights(for scenes: [String]) -> [Double] {
        scenes.map { scene in
            let s = scene.lowercased()
            for rule in rules where rule.keywords.contains(where: { s.contains($0) }) {
                return rule.weight
            }
            return fallback
        }
    }
}

let presets: [Preset] = [
    Preset(id: "full", name: "Full Bank",
           rules: [(["dali", "surrealist"], 2.0)], fallback: 1.0),
    Preset(id: "warehouse", name: "Dark Warehouse",
           rules: [(["warehouse", "laser", "crowd", "concrete", "stairwell", "rebar",
                     "club", "dancers", "hands", "speakers"], 2.5),
                   (["painting", "cartoon", "egypt", "renaissance", "fresco"], 0.3)],
           fallback: 0.8),
    Preset(id: "surreal", name: "Surreal Gallery",
           rules: [(["dali", "surrealist", "renaissance", "fresco", "eyes",
                     "painting"], 2.5)], fallback: 0.4),
    Preset(id: "ancient", name: "Ancient Conspiracies",
           rules: [(["egypt", "pyramid", "snake", "serpent", "alien", "ufo",
                     "illuminati"], 2.5)], fallback: 0.3),
    Preset(id: "flesh", name: "Flesh & Neon",
           rules: [(["goth", "lips", "eyes", "crowd", "club", "dancers",
                     "hands"], 2.5)], fallback: 0.4),
    Preset(id: "machine", name: "Machine World",
           rules: [(["motherboard", "machine", "industrial", "city", "highway",
                     "apartment", "tunnel", "speakers"], 2.5)], fallback: 0.3),
]

// ------------------------------------------------------------------ render

/// Output shape. Reel/landscape render a larger square and center-crop -
/// the feedback loop itself is always square.
enum RenderFormat: String, CaseIterable, Identifiable {
    case square = "Square 1:1"
    case reel = "Instagram Reel 9:16"
    case landscape = "YouTube 16:9"
    var id: String { rawValue }

    func geometry(_ q: RenderQuality) -> (size: Int, w: Int, h: Int) {
        switch (self, q) {
        case (.square, .draft): (512, 512, 512)
        case (.square, .hd): (1024, 1024, 1024)
        case (.square, .full): (1920, 1920, 1920)
        case (.reel, .draft): (512, 288, 512)
        case (.reel, .hd): (1024, 576, 1024)
        case (.reel, .full): (1920, 1080, 1920)
        case (.landscape, .draft): (512, 512, 288)
        case (.landscape, .hd): (1024, 1024, 576)
        case (.landscape, .full): (1920, 1920, 1080)
        }
    }

    /// Largest safe logo.scale (fraction of the square frame width) for this
    /// format - only the 9:16 crop cuts width, so only it constrains the logo.
    var maxLogoScale: Double {
        let g = geometry(.full)
        return g.w < g.size ? (Double(g.w) / Double(g.size) * 0.995).rounded(toPlaces: 2)
                            : 0.9
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let f = pow(10.0, Double(p))
        return (self * f).rounded(.down) / f
    }
}

enum RenderQuality: String, CaseIterable, Identifiable {
    case draft = "Draft"
    case hd = "HD"
    case full = "Full"
    var id: String { rawValue }
}

/// One drop cue, kept as editable text ("1:20.4" or "80.4"), track-absolute.
struct DropCue: Identifiable, Equatable {
    var id = UUID()
    var text = ""

    var seconds: Double? { parseClock(text) }
}

/// Style flavors - each maps to a documented engine override; all off = the
/// stock config.yaml behavior.
struct RenderFlavors: Equatable {
    var sceneStamps = false   // phrase_flash.guidance 3.0 - prompt-faithful phrase opens
    var shortPhrases = false  // phrase_bars 4 - snappier scene walk
    var hybrids = false       // hybrid_chance 0.15 - two-scene fusions
    var swirl = false         // swirl_amount 0.05 - spiral tunnel
    var antiLock = false      // noise_idle 0.05 + tighter collapse thresholds
    var isDefault: Bool { self == RenderFlavors() }
}

/// Logo overrides for a render (config.yaml logo section stays untouched).
struct RenderLogo: Equatable {
    var enabled = false
    var path = ""
    var opacity = 0.98
    var scale = 0.45
    var dropChance = 1.0
    var flashSeconds = 3.0
}

/// Everything the Render tab hands to Engine.startRender.
struct RenderJob {
    var mix = ""
    var seek = ""
    var duration = ""
    var fps = 30
    var format = RenderFormat.square
    var quality = RenderQuality.hd
    var diffFps = 6.0
    var out = ""
    var dropCues: [Double] = []
    var bpmOverride: Double?
    var logo = RenderLogo()
    var flavors = RenderFlavors()
}

/// A named audio input device (index = what --device expects).
struct AudioDevice: Identifiable, Decodable, Equatable {
    var i: Int
    var name: String
    var ch: Int
    var id: Int { i }
}

func fmtClock(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "--:--" }
    let s = Int(t)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    return String(format: "%02d:%02d", s / 60, s % 60)
}
