@preconcurrency import AVFoundation
import Foundation

@MainActor
final class GeminiLiveSession: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isStreamingMic = false
    @Published private(set) var lastInputTranscript = ""
    @Published private(set) var lastOutputTranscript = ""
    @Published private(set) var sentAudioChunkCount = 0
    @Published private(set) var isModelResponding = false
    @Published private(set) var isToolActive = false

    var isBusyForMemoryContext: Bool {
        isModelResponding || isToolActive
    }

    var onStatus: ((String) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onTranscript: ((String, String) -> Void)?
    var onError: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    var onToolCall: (@MainActor ([LiveToolFunctionCall]) async -> [LiveToolFunctionResponse])?
    var onLog: ((String, [String: Any]) -> Void)?

    private var apiKey = ""
    private var model = AppSettings.defaultLiveModel
    private var voice = AppSettings.defaultTTSVoice
    private var webSocket: URLSessionWebSocketTask?
    private let webSocketDelegate = LiveWebSocketDelegate()
    private lazy var session = URLSession(configuration: .default, delegate: webSocketDelegate, delegateQueue: nil)
    private let audioEngine = AVAudioEngine()
    private let audioSender = LiveAudioSender()
    private var didSendSetup = false
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private var outputSuppressionActive = false
    private var shouldResumeMicAfterOutput = false
    private var sessionResumptionHandle = ""
    private var lastMemoryContext = ""
    private var cancelledToolCallIDs = Set<String>()
    private var toolCallTasksByID: [String: Task<Void, Never>] = [:]
    private var toolCallNamesByID: [String: String] = [:]
    private var keepAliveTask: Task<Void, Never>?
    private var lastServerEventAt = Date()
    private var audioEngineConfigObserver: NSObjectProtocol?

    init() {
        audioEngineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAudioEngineConfigurationChange()
            }
        }
    }

    func connect(apiKey: String, model: String, voice: String, systemInstruction: String) async throws {
        if isConnected, didSendSetup {
            return
        }

        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppSettings.defaultLiveModel : model
        self.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppSettings.defaultTTSVoice : voice

        guard !self.apiKey.isEmpty else {
            throw GeminiError.missingAPIKey
        }

        var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: self.apiKey)]
        guard let url = components.url else {
            throw GeminiError.badResponse("Could not create Live API WebSocket URL.")
        }

        onStatus?("Opening Live socket...")
        log("live_connect_start", [
            "model": self.model,
            "voice": self.voice,
            "has_stale_session_resumption": !sessionResumptionHandle.isEmpty
        ])
        webSocketDelegate.prepareForOpen()
        webSocketDelegate.onClose = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                if self.looksLikeInvalidArgumentClose(message) {
                    self.clearSessionResumptionHandle(reason: "invalid_argument_close")
                }
                self.stopKeepAlive()
                self.forceStopMic()
                self.webSocket = nil
                self.audioSender.webSocket = nil
                self.isConnected = false
                self.isModelResponding = false
                self.isToolActive = false
                self.didSendSetup = false
                self.failPendingSetup(GeminiError.badResponse(message))
                self.onStatus?(message)
                self.onError?(message)
                self.log("live_socket_closed", ["message": message])
            }
        }

        let task = session.webSocketTask(with: url)
        webSocket = task
        audioSender.onChunkSent = { [weak self] count in
            Task { @MainActor in self?.sentAudioChunkCount = count }
        }
        task.resume()
        try await webSocketDelegate.waitForOpen()
        isConnected = true
        lastServerEventAt = Date()
        sentAudioChunkCount = 0
        didSendSetup = false
        receiveLoop()
        startKeepAlive()

        onStatus?("Live socket open. Sending setup...")
        var setupConfig: [String: Any] = [
            "model": "models/\(self.model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "mediaResolution": "MEDIA_RESOLUTION_LOW",
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": self.voice
                        ]
                    ]
                ]
            ],
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ],
            "tools": [
                [
                    "functionDeclarations": LiveToolExecutor.toolDeclarations
                ]
            ],
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "disabled": false,
                    "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                    "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                    "prefixPaddingMs": 40,
                    "silenceDurationMs": 600
                ],
                "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                "turnCoverage": "TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO"
            ],
            "contextWindowCompression": [
                "slidingWindow": [:]
            ],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:]
        ]

        // Gemini can reject stale Live resumption handles with 1007 after a manual restart.
        // Keep the latest handle for diagnostics, but start user-triggered sessions clean.
        if !sessionResumptionHandle.isEmpty {
            setupConfig["sessionResumption"] = nil
            log("live_session_resumption_skipped", ["reason": "manual_restart", "handle_length": sessionResumptionHandle.count])
        }
        let setupMessage: [String: Any] = ["setup": setupConfig]

        try await waitForSetupComplete {
            try await self.sendJSON(setupMessage)
        }

        didSendSetup = true
        audioSender.webSocket = task
        onStatus?("Live ready. Speak, then press Pause.")
        log("live_ready", ["model": self.model])
    }

    func disconnect() {
        log("live_disconnect_requested")
        stopKeepAlive()
        stopMic()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        audioSender.webSocket = nil
        audioSender.reset()
        isConnected = false
        isModelResponding = false
        isToolActive = false
        didSendSetup = false
        lastMemoryContext = ""
        cancelledToolCallIDs.removeAll()
        toolCallTasksByID.values.forEach { $0.cancel() }
        toolCallTasksByID.removeAll()
        toolCallNamesByID.removeAll()
        clearSessionResumptionHandle(reason: "manual_disconnect")
        outputSuppressionActive = false
        shouldResumeMicAfterOutput = false
        failPendingSetup(GeminiError.badResponse("Live disconnected."))
        onStatus?("Live disconnected.")
        log("live_disconnected")
    }

    func clearSessionResumptionHandle(reason: String) {
        guard !sessionResumptionHandle.isEmpty else { return }
        let previousLength = sessionResumptionHandle.count
        sessionResumptionHandle = ""
        log("live_session_resumption_cleared", ["reason": reason, "previous_handle_length": previousLength])
    }

    func startMic() async throws {
        guard !outputSuppressionActive else {
            onStatus?("Assistant is speaking; mic will resume after output.")
            return
        }
        guard isConnected, didSendSetup else {
            throw GeminiError.badResponse("Live session is not connected yet.")
        }
        guard !isStreamingMic else { return }
        try await ensureMicrophoneAccess()

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw LiveAudioError.invalidInputFormat
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: LiveAudioTap.makeBlock(sender: audioSender))

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isStreamingMic = true
            onStatus?("Live mic streaming.")
            log("live_mic_started", ["sample_rate": format.sampleRate, "channels": format.channelCount])
        } catch {
            input.removeTap(onBus: 0)
            isStreamingMic = false
            throw error
        }
    }

    func stopMic() {
        guard isStreamingMic || audioEngine.isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isStreamingMic = false
        audioSender.sendAudioStreamEnd()
        onStatus?("Live mic paused. Waiting for Gemini...")
        log("live_mic_stopped")
    }

    private func handleAudioEngineConfigurationChange() {
        let wasStreaming = isStreamingMic
        log("live_audio_engine_configuration_changed", [
            "was_streaming_mic": wasStreaming,
            "engine_running": audioEngine.isRunning
        ])

        guard wasStreaming else { return }
        forceStopMic()
        onStatus?("Audio device changed. Restarting live mic...")

        Task { @MainActor in
            do {
                try await self.startMic()
                self.onStatus?("Live mic streaming after audio device change.")
                self.log("live_mic_restarted_after_audio_device_change")
            } catch {
                self.onError?(error.localizedDescription)
                self.onStatus?("Audio device changed, but mic restart failed.")
                self.log("live_mic_restart_after_audio_device_change_failed", ["error": error.localizedDescription])
            }
        }
    }

    func setOutputSuppression(_ active: Bool) {
        if active {
            outputSuppressionActive = true
            if isStreamingMic || audioEngine.isRunning {
                shouldResumeMicAfterOutput = true
                forceStopMic()
                onStatus?("Live playback active; mic paused to prevent feedback.")
                log("live_mic_suppressed_for_output")
            }
            return
        }

        outputSuppressionActive = false
        guard shouldResumeMicAfterOutput else { return }
        shouldResumeMicAfterOutput = false

        Task { @MainActor in
            do {
                try await self.startMic()
            } catch {
                self.onError?(error.localizedDescription)
                self.log("live_mic_resume_failed", ["error": error.localizedDescription])
            }
        }
    }

    func toggleMic() async throws {
        if isStreamingMic {
            stopMic()
        } else {
            try await startMic()
        }
    }

    func sendVideoFrame(_ data: Data, mimeType: String) async throws {
        log("live_video_frame_send", ["bytes": data.count, "mime_type": mimeType])
        try await sendJSON([
            "realtimeInput": [
                "video": [
                    "data": data.base64EncodedString(),
                    "mimeType": mimeType
                ]
            ]
        ])
    }

    func sendMemoryContext(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isConnected, didSendSetup else { return }
        lastMemoryContext = trimmed

        try await sendJSON([
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [
                            [
                                "text": """
                                Approved long-term memory context for future live turns. Use this as background only; do not respond to this packet directly.

                                \(trimmed)
                                """
                            ]
                        ]
                    ]
                ],
                "turnComplete": false
            ]
        ])
        onStatus?("Live memory context refreshed.")
        log("live_memory_context_sent", ["characters": trimmed.count])
    }

    private func ensureMicrophoneAccess() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                return
            }
            throw LiveAudioError.microphonePermissionDenied
        case .denied, .restricted:
            throw LiveAudioError.microphonePermissionDenied
        @unknown default:
            throw LiveAudioError.microphonePermissionDenied
        }
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .success(let message):
                    self.lastServerEventAt = Date()
                    self.handle(message)
                    if self.webSocket != nil {
                        self.receiveLoop()
                    }
                case .failure(let error):
                    self.stopKeepAlive()
                    self.forceStopMic()
                    self.isConnected = false
                    self.didSendSetup = false
                    self.audioSender.webSocket = nil
                    self.onStatus?("Live socket closed: \(error.localizedDescription)")
                    self.onError?("Live socket closed: \(error.localizedDescription)")
                    self.log("live_receive_failed", ["error": error.localizedDescription])
                }
            }
        }
    }

    private func forceStopMic() {
        if audioEngine.isRunning || isStreamingMic {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        isStreamingMic = false
    }

    private func looksLikeInvalidArgumentClose(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("1007") || normalized.contains("invalid argument")
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return
        }

        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("live_inbound_unparsed", ["characters": text.count])
            return
        }
        log("live_inbound", summarizeInbound(json))

        if let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "\(error)"
            onStatus?("Live error: \(message)")
            onError?("Live error: \(message)")
            log("live_error", ["message": message])
            failPendingSetup(GeminiError.badResponse(message))
            disconnect()
            return
        }

        if json["setupComplete"] != nil {
            isConnected = true
            didSendSetup = true
            setupContinuation?.resume()
            setupContinuation = nil
            onStatus?("Live ready. Speak, then press Pause.")
            log("live_setup_complete")
            return
        }

        if let serverContent = json["serverContent"] as? [String: Any] {
            if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
                lastOutputTranscript = ""
                isModelResponding = false
                onStatus?("Live interrupted.")
                onInterrupted?()
                return
            }

            if
                let input = serverContent["inputTranscription"] as? [String: Any],
                let transcript = input["text"] as? String,
                !transcript.isEmpty
            {
                lastInputTranscript = transcript
                onTranscript?("You", transcript)
                log("live_input_transcript", ["text": transcript])
            }

            if
                let output = serverContent["outputTranscription"] as? [String: Any],
                let transcript = output["text"] as? String,
                !transcript.isEmpty
            {
                isModelResponding = true
                lastOutputTranscript += transcript
                onTranscript?("Live", transcript)
                log("live_output_transcript_delta", ["text": transcript])
            }

            if
                let modelTurn = serverContent["modelTurn"] as? [String: Any],
                let parts = modelTurn["parts"] as? [[String: Any]]
            {
                isModelResponding = true
                for part in parts {
                    let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
                    if
                        let base64 = inline?["data"] as? String,
                        let pcm = Data(base64Encoded: base64)
                    {
                        onAudio?(pcm)
                        log("live_audio_received", ["bytes": pcm.count])
                    }
                }
            }

            if let complete = serverContent["turnComplete"] as? Bool, complete {
                isModelResponding = false
                if !lastOutputTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onTranscript?("Assistant", lastOutputTranscript.trimmingCharacters(in: .whitespacesAndNewlines))
                    log("live_assistant_turn_complete", ["text": lastOutputTranscript.trimmingCharacters(in: .whitespacesAndNewlines)])
                    lastOutputTranscript = ""
                }
                onStatus?("Live ready.")
                log("live_turn_complete")
            }
        } else if let update = json["sessionResumptionUpdate"] as? [String: Any] {
            if
                (update["resumable"] as? Bool) == true,
                let handle = update["newHandle"] as? String,
                !handle.isEmpty
            {
                sessionResumptionHandle = handle
                onStatus?("Live session checkpoint saved.")
                log("live_session_checkpoint", ["handle_length": handle.count])
            }
        } else if let goAway = json["goAway"] as? [String: Any] {
            let timeLeft = goAway["timeLeft"] as? String ?? "soon"
            onStatus?("Live server will rotate this socket \(timeLeft). Keep talking; reconnect is prepared.")
            log("live_goaway", ["time_left": timeLeft])
        } else if let toolCall = json["toolCall"] as? [String: Any] {
            handleToolCall(toolCall)
        } else if let cancellation = json["toolCallCancellation"] as? [String: Any] {
            let ids = cancellation["ids"] as? [String] ?? []
            var cancelledIDs: [String] = []
            var ignoredIDs: [String] = []
            for id in ids {
                if toolCallNamesByID[id] == "run_computer_use_task" {
                    ignoredIDs.append(id)
                    continue
                }
                cancelledToolCallIDs.insert(id)
                cancelledIDs.append(id)
                toolCallTasksByID[id]?.cancel()
                toolCallTasksByID.removeValue(forKey: id)
                toolCallNamesByID.removeValue(forKey: id)
            }
            if !cancelledIDs.isEmpty {
                onStatus?("Live cancelled \(cancelledIDs.count) tool call\(cancelledIDs.count == 1 ? "" : "s").")
            }
            if !ignoredIDs.isEmpty {
                onStatus?("Computer Use is still running.")
            }
            log("live_tool_cancelled", ["ids": cancelledIDs, "ignored_ids": ignoredIDs])
        }
    }

    private func handleToolCall(_ toolCall: [String: Any]) {
        guard let onToolCall else {
            onError?("Live requested a tool, but no tool executor is configured.")
            return
        }

        let calls = (toolCall["functionCalls"] as? [[String: Any]] ?? []).compactMap { raw -> LiveToolFunctionCall? in
            guard
                let id = raw["id"] as? String,
                let name = raw["name"] as? String
            else {
                return nil
            }

            let args = raw["args"] as? [String: Any] ?? [:]
            return LiveToolFunctionCall(id: id, name: name, args: args)
        }

        guard !calls.isEmpty else { return }
        isToolActive = true
        onStatus?("Live requested \(calls.count) tool call\(calls.count == 1 ? "" : "s").")
        log("live_tool_call", [
            "count": calls.count,
            "calls": calls.map { ["id": $0.id, "name": $0.name, "args": $0.args] }
        ])

        let task = Task { @MainActor in
            defer {
                for call in calls {
                    self.toolCallTasksByID.removeValue(forKey: call.id)
                    self.toolCallNamesByID.removeValue(forKey: call.id)
                }
            }
            guard !Task.isCancelled else {
                self.isToolActive = false
                return
            }
            let responses = await onToolCall(calls)
                .filter { !self.cancelledToolCallIDs.contains($0.id) }
            guard !responses.isEmpty else {
                self.isToolActive = false
                return
            }

            do {
                try await self.sendToolResponses(responses)
                self.onStatus?("Live tool response sent.")
                self.log("live_tool_response_sent", [
                    "count": responses.count,
                    "responses": responses.map { ["id": $0.id, "name": $0.name, "response": $0.response] }
                ])
            } catch {
                self.onError?("Live tool response failed: \(error.localizedDescription)")
                self.log("live_tool_response_failed", ["error": error.localizedDescription])
            }
            self.isToolActive = false
        }
        for call in calls {
            toolCallTasksByID[call.id] = task
            toolCallNamesByID[call.id] = call.name
        }
    }

    private func sendToolResponses(_ responses: [LiveToolFunctionResponse]) async throws {
        try await sendJSON([
            "toolResponse": [
                "functionResponses": responses.map { response in
                    [
                        "id": response.id,
                        "name": response.name,
                        "response": response.response
                    ] as [String: Any]
                }
            ]
        ])
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket else {
            throw GeminiError.badResponse("Live socket is not open.")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        log("live_outbound", summarizeOutbound(object))
        try await webSocket.send(.string(text))
    }

    private func waitForSetupComplete(sendSetup: @escaping () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setupContinuation = continuation
            Task { @MainActor in
                do {
                    try await sendSetup()
                } catch {
                    self.failPendingSetup(error)
                }
            }
        }
    }

    private func failPendingSetup(_ error: Error) {
        setupContinuation?.resume(throwing: error)
        setupContinuation = nil
    }

    private func startKeepAlive() {
        stopKeepAlive()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                } catch {
                    return
                }

                await MainActor.run {
                    guard let self, self.isConnected, let webSocket = self.webSocket else { return }
                    let idleSeconds = Date().timeIntervalSince(self.lastServerEventAt)
                    self.log("live_keepalive_ping", ["idle_seconds": idleSeconds])
                    webSocket.sendPing { error in
                        Task { @MainActor in
                            if let error {
                                self.log("live_keepalive_failed", ["error": error.localizedDescription])
                                self.onError?("Live keepalive failed: \(error.localizedDescription)")
                                self.disconnect()
                            } else {
                                self.log("live_keepalive_pong", ["idle_seconds": idleSeconds])
                            }
                        }
                    }
                }
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    private func log(_ event: String, _ payload: [String: Any] = [:]) {
        onLog?(event, payload)
    }

    private func summarizeInbound(_ object: [String: Any]) -> [String: Any] {
        [
            "keys": Array(object.keys).sorted(),
            "summary": summarizeJSON(object)
        ]
    }

    private func summarizeOutbound(_ object: [String: Any]) -> [String: Any] {
        [
            "keys": Array(object.keys).sorted(),
            "summary": summarizeJSON(object)
        ]
    }

    private func summarizeJSON(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                if item.key == "data", let string = item.value as? String, string.count > 512 {
                    result[item.key] = "[base64 \(string.count) chars]"
                } else {
                    result[item.key] = summarizeJSON(item.value)
                }
            }
        }

        if let array = value as? [Any] {
            return array.map(summarizeJSON)
        }

        if let string = value as? String, string.count > 1_000 {
            return String(string.prefix(1_000)) + "...[truncated]"
        }

        return value
    }
}

private final class LiveWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onClose: ((String) -> Void)?

    private let lock = NSLock()
    private var isOpen = false
    private var openContinuation: CheckedContinuation<Void, Error>?

    func prepareForOpen() {
        lock.lock()
        isOpen = false
        openContinuation = nil
        lock.unlock()
    }

    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                openContinuation = continuation
                lock.unlock()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        isOpen = true
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
        let message = "Live socket closed: \(closeCode) (\(reasonText))"

        lock.lock()
        isOpen = false
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()

        continuation?.resume(throwing: GeminiError.badResponse(message))
        onClose?(message)
    }
}

private enum LiveAudioTap {
    nonisolated static func makeBlock(sender: LiveAudioSender) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let pcm = convertToPCM16Mono16k(buffer), !pcm.isEmpty else { return }
            sender.sendAudioChunk(pcm)
        }
    }

    nonisolated private static func convertToPCM16Mono16k(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        let ratio = 16_000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio + 32))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
            return nil
        }

        let inputState = ConverterInputState()
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if inputState.didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            inputState.didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, let channel = outputBuffer.int16ChannelData?.pointee else {
            return nil
        }

        return Data(bytes: channel, count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
    }
}

private final class LiveAudioSender: @unchecked Sendable {
    var webSocket: URLSessionWebSocketTask?
    var onChunkSent: ((Int) -> Void)?
    private var chunkCount = 0

    func sendAudioChunk(_ pcm: Data) {
        guard let webSocket else { return }
        let object: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": pcm.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        webSocket.send(.string(text)) { [weak self] error in
            guard error == nil, let self else { return }
            self.chunkCount += 1
            self.onChunkSent?(self.chunkCount)
        }
    }

    func sendAudioStreamEnd() {
        guard let webSocket else { return }
        let object: [String: Any] = [
            "realtimeInput": [
                "audioStreamEnd": true
            ]
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        webSocket.send(.string(text)) { _ in }
    }

    func reset() {
        chunkCount = 0
    }
}

private final class ConverterInputState: @unchecked Sendable {
    var didProvideInput = false
}

enum LiveAudioError: LocalizedError {
    case microphonePermissionDenied
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone permission is not enabled. Open System Settings > Privacy & Security > Microphone and allow April AI."
        case .invalidInputFormat:
            "The microphone input format is invalid. Check that a working input device is selected in macOS Sound settings."
        }
    }
}
