import AVFoundation

/// Plays a meeting's m4a, which lives on the Google Drive mount: the file is opened off the main thread (a stat or
/// read there can stall), and the polling timer only runs while playing. `stop()` releases everything.
@MainActor final class AudioPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var failure: String?

    private var player: AVAudioPlayer?
    private var path: String?
    private var ticker: Timer?
    private var generation = 0  // a load that finishes after stop() or another play() is stale
    private let loadQueue = DispatchQueue(label: "eavesdroppy.playback.load", qos: .userInitiated)

    /// Starts `path` at `seconds` (the file's start when nil). Reuses the loaded player for the same file.
    func play(path: String, from seconds: Double? = nil) {
        failure = nil
        if let p = player, self.path == path {
            if let seconds { p.currentTime = min(max(seconds, 0), max(p.duration - 0.1, 0)) }
            start(p); return
        }
        stop()
        self.path = path; loading = true
        generation += 1
        let gen = generation
        loadQueue.async {
            let result = Result { try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) }
            if case .success(let p) = result { p.prepareToPlay() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.generation else { return }
                    self.loading = false
                    switch result {
                    case .success(let p):
                        self.player = p; self.duration = p.duration
                        if let seconds { p.currentTime = min(max(seconds, 0), max(p.duration - 0.1, 0)) }
                        self.start(p)
                    case .failure(let e):
                        self.path = nil
                        self.failure = "Can't play the audio: \(e.localizedDescription)"
                    }
                }
            }
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; ticker?.invalidate(); ticker = nil }
        else { if p.currentTime >= p.duration - 0.1 { p.currentTime = 0 }; start(p) }
    }

    func stop() {
        generation += 1
        ticker?.invalidate(); ticker = nil
        player?.stop(); player = nil; path = nil
        isPlaying = false; loading = false; position = 0; duration = 0
    }

    private func start(_ p: AVAudioPlayer) {
        p.play(); isPlaying = true; position = p.currentTime
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player else { return }
                self.position = p.currentTime
                if !p.isPlaying { self.isPlaying = false; self.ticker?.invalidate(); self.ticker = nil }
            }
        }
    }
}
