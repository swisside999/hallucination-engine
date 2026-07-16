import AVFoundation
import SwiftUI

// ------------------------------------------------------------ EQ LED meter

/// Vertical segmented LED meter with a decaying peak-hold tick - the classic
/// 3-band EQ loudness read (LOW/MID/HIGH from the engine's band envelopes).
struct EQBar: View {
    let label: String
    let value: Double
    var tint: Color = HE.volt
    @State private var peak = 0.0
    private let segs = 14

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let segH = (geo.size.height - CGFloat(segs - 1) * 2) / CGFloat(segs)
                VStack(spacing: 2) {
                    ForEach((0..<segs).reversed(), id: \.self) { i in
                        let thr = Double(i + 1) / Double(segs)
                        let on = value >= thr
                        let held = !on && peak >= thr && peak < thr + 1.0 / Double(segs)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(segColor(i).opacity(on ? 1.0 : held ? 0.75 : 0.12))
                            .frame(height: segH)
                    }
                }
            }
            Text(label).font(HE.micro).tracking(1.2).foregroundStyle(HE.textDim)
        }
        .animation(.linear(duration: 0.12), value: value)
        .onChange(of: value) { _, v in
            peak = v >= peak ? v : max(v, peak - 0.07)  // decay per stats tick
        }
    }

    private func segColor(_ i: Int) -> Color {
        i >= segs - 2 ? HE.danger : i >= segs - 5 ? HE.amber : tint
    }
}

// ------------------------------------------------------- waveform timeline

/// Downsampled loudness envelope of an audio file - decoded off-main once
/// per path, drawn by WaveformView.
@MainActor
final class WaveformLoader: ObservableObject {
    @Published var buckets: [Float] = []
    @Published var duration = 0.0
    private var loadedPath = ""

    func load(_ path: String) {
        guard path != loadedPath else { return }
        loadedPath = path
        buckets = []
        duration = 0
        guard !path.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            guard let (b, d) = Self.decode(path) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.loadedPath == path else { return }
                self.buckets = b
                self.duration = d
            }
        }
    }

    nonisolated static func decode(_ path: String, target: Int = 480) -> ([Float], Double)? {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              f.length > 0, f.processingFormat.sampleRate > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                         frameCapacity: 1 << 18)
        else { return nil }
        let per = max(Int(f.length) / target, 1)
        var out: [Float] = []
        var acc: Float = 0
        var n = 0
        while f.framePosition < f.length {
            guard (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData else { break }
            let frames = Int(buf.frameLength)
            let chans = Int(buf.format.channelCount)
            for i in 0..<frames {
                var v: Float = 0
                for j in 0..<chans { v += abs(ch[j][i]) }
                acc += v / Float(chans)
                n += 1
                if n == per {
                    out.append(acc / Float(per))
                    acc = 0
                    n = 0
                }
            }
        }
        let peak = max(out.max() ?? 1, 1e-6)
        return (out.map { $0 / peak }, Double(f.length) / f.processingFormat.sampleRate)
    }
}

/// Mix overview with drop-cue markers. Click anywhere to drop a cue there.
struct WaveformView: View {
    let buckets: [Float]
    let duration: Double
    let cues: [Double]
    let onTap: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let n = buckets.count
                if n > 0 {
                    let w = size.width / CGFloat(n)
                    for (i, v) in buckets.enumerated() {
                        let h = max(CGFloat(v) * size.height * 0.9, 1)
                        let bar = CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2,
                                         width: max(w - 0.6, 0.6), height: h)
                        ctx.fill(Path(bar), with: .color(HE.plasma.opacity(0.55)))
                    }
                }
                if duration > 0 {
                    for c in cues where c <= duration {
                        let x = size.width * CGFloat(c / duration)
                        ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5,
                                             height: size.height)),
                                 with: .color(HE.volt))
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: 0, width: 6, height: 6)),
                                 with: .color(HE.volt))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                guard duration > 0, geo.size.width > 0 else { return }
                let t = Double(g.location.x / geo.size.width) * duration
                onTap(min(max(t, 0), duration))
            })
            .overlay {
                if buckets.isEmpty {
                    Text(duration == 0 ? "pick a mix to see its waveform" : "analyzing…")
                        .font(HE.mono(9)).foregroundStyle(HE.textFaint)
                }
            }
        }
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45)))
    }
}

// ---------------------------------------------------------- scene thumbnail

/// Full-size look at one scene's cached thumbnail, with its prompt.
struct ThumbZoomView: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: String
    let path: String

    var body: some View {
        VStack(spacing: 10) {
            if let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 512, maxHeight: 512)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(HE.raised)
                    Text("no thumbnail yet - hit ◉ THUMBS")
                        .font(HE.mono(10)).foregroundStyle(HE.textFaint)
                }
                .frame(width: 400, height: 400)
            }
            Text(prompt)
                .font(HE.mono(11))
                .foregroundStyle(HE.textDim)
                .frame(maxWidth: 512, alignment: .leading)
            Button("CLOSE") { dismiss() }.buttonStyle(HEButtonStyle(prominent: true))
        }
        .padding(16)
        .background(HE.bg)
    }
}

/// One scene's cached SD-Turbo thumbnail - async-loaded, re-fetched when the
/// generation counter bumps.
struct ThumbImage: View {
    let path: String
    let version: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(HE.raised)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(HE.textFaint)
                }
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: "\(path)#\(version)") {
            image = NSImage(contentsOfFile: path)
        }
    }
}
