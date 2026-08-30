import AVFoundation
import Foundation

@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    func start() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "april-ai-voice-\(UUID().uuidString).m4a")
        outputURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw VoiceRecorderError.couldNotStart
        }

        self.recorder = recorder
        isRecording = true
    }

    func stop() throws -> URL {
        guard let recorder, let outputURL else {
            throw VoiceRecorderError.notRecording
        }

        recorder.stop()
        self.recorder = nil
        isRecording = false

        return outputURL
    }
}

enum VoiceRecorderError: LocalizedError {
    case couldNotStart
    case notRecording

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Could not start microphone recording. macOS may need Microphone permission for this app."
        case .notRecording:
            "No recording is active."
        }
    }
}
