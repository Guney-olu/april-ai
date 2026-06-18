import AVFoundation
import Foundation

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var queuedAudio: [Data] = []
    private let liveEngine = AVAudioEngine()
    private let livePlayer = AVAudioPlayerNode()
    private let liveFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var liveEngineConfigured = false
    private var pendingLiveBuffers = 0
    private var playbackGeneration = 0

    var onOutputActivityChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let cleaned = text.replacingOccurrences(of: #"(?s)```.*?```"#, with: "", options: .regularExpression)
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.rate = 0.52
        utterance.pitchMultiplier = 0.92
        utterance.volume = 1
        synthesizer.speak(utterance)
        setOutputActive(true)
    }

    func playAudio(_ wavData: Data) throws {
        stop()
        let player = try AVAudioPlayer(data: wavData)
        player.delegate = self
        player.prepareToPlay()
        player.play()
        audioPlayer = player
        setOutputActive(true)
    }

    func enqueueLivePCM16(_ pcm: Data) {
        guard let buffer = Self.makeFloatBuffer(fromPCM16: pcm, format: liveFormat) else { return }

        do {
            try ensureLiveEngineRunning()
        } catch {
            return
        }

        let generation = playbackGeneration
        pendingLiveBuffers += 1
        setOutputActive(true)

        livePlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard generation == self.playbackGeneration else { return }
                self.pendingLiveBuffers = max(0, self.pendingLiveBuffers - 1)
                if self.pendingLiveBuffers == 0 {
                    self.setOutputActive(false)
                }
            }
        }

        if !livePlayer.isPlaying {
            livePlayer.play()
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        queuedAudio.removeAll()
        playbackGeneration += 1
        if livePlayer.engine != nil {
            livePlayer.stop()
        }
        pendingLiveBuffers = 0
        setOutputActive(false)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.setOutputActive(false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.setOutputActive(false) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.playNextQueuedAudio()
        }
    }

    private func playNextQueuedAudio() {
        guard !queuedAudio.isEmpty else {
            setOutputActive(false)
            return
        }

        let data = queuedAudio.removeFirst()
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            setOutputActive(true)
        } catch {
            playNextQueuedAudio()
        }
    }

    private func ensureLiveEngineRunning() throws {
        if !liveEngineConfigured {
            liveEngine.attach(livePlayer)
            liveEngine.connect(livePlayer, to: liveEngine.mainMixerNode, format: liveFormat)
            liveEngine.prepare()
            liveEngineConfigured = true
        }

        if !liveEngine.isRunning {
            try liveEngine.start()
        }
    }

    private func setOutputActive(_ active: Bool) {
        if isSpeaking != active {
            isSpeaking = active
            onOutputActivityChanged?(active)
        }
    }

    private static func makeFloatBuffer(fromPCM16 pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = pcm.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channel = buffer.floatChannelData?.pointee else { return nil }

        for index in 0..<frameCount {
            let offset = index * 2
            let sample = Int16(bitPattern: UInt16(pcm[offset]) | (UInt16(pcm[offset + 1]) << 8))
            channel[index] = max(-1, Float(sample) / 32768.0)
        }

        return buffer
    }
}
