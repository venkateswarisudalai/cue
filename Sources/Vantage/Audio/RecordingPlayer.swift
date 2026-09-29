import AVFoundation
import VantageCore

/// Plays a meeting's recording; the transcript page seeks it to the line you click.
@MainActor
final class RecordingPlayer: ObservableObject {
    @Published private(set) var loaded: Recording?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func play(_ r: Recording, url: URL, from offset: TimeInterval? = nil) {
        if loaded != r || player == nil {
            stop()
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            p.prepareToPlay()
            player = p
            loaded = r
        }
        if let offset { player?.currentTime = offset }
        player?.play()
        startTicking()
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        refresh()
    }

    func seek(to t: TimeInterval) {
        player?.currentTime = t
        refresh()
    }

    func stop() {
        player?.stop()
        player = nil
        loaded = nil
        ticker?.invalidate()
        ticker = nil
        isPlaying = false
        time = 0
    }

    private func startTicking() {
        refresh()
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        isPlaying = player?.isPlaying ?? false
        time = player?.currentTime ?? 0
    }
}
