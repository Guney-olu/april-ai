import Foundation
import Speech

enum LocalServiceError: LocalizedError {
    case invalidURL(String)
    case unavailable(String)
    case badResponse(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): "Invalid local service URL: \(value)"
        case .unavailable(let message), .badResponse(let message): message
        case .emptyResponse: "The local model returned no text."
        }
    }
}

struct LocalChatTurn: Codable, Equatable {
    let role: String
    let content: String
}

enum LocalStreamEvent: Equatable {
    case text(String)
    case toolActivity(String)
}

struct LocalAIClient {
    let baseURL: String
    let apiKey: String
    let model: String

    func streamChat(system: String, prompt: String, history: [LocalChatTurn]) -> AsyncThrowingStream<LocalStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = try endpoint("chat/completions")
                    var messages: [[String: String]] = [["role": "system", "content": system]]
                    messages.append(contentsOf: history.suffix(16).map { ["role": $0.role, "content": $0.content] })
                    messages.append(["role": "user", "content": prompt])

                    let payload: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "stream": true,
                        "enable_tools": true,
                        "enabled_tools": ["web_search", "python", "terminal"]
                    ]
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LocalServiceError.unavailable("Unsloth returned a non-HTTP response.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw LocalServiceError.badResponse("Unsloth HTTP \(http.statusCode): \(try await Self.responseText(bytes))")
                    }

                    var emittedText = false
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        let activity = Self.toolActivity(from: object)
                        if !activity.isEmpty {
                            continuation.yield(.toolActivity(activity))
                        }
                        let text = Self.deltaText(from: object)
                        if !text.isEmpty {
                            emittedText = true
                            continuation.yield(.text(text))
                        }
                    }
                    guard emittedText else { throw LocalServiceError.emptyResponse }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func complete(system: String, prompt: String, history: [LocalChatTurn] = []) async throws -> String {
        var collected = ""
        for try await event in streamChat(system: system, prompt: prompt, history: history) {
            if case .text(let text) = event { collected += text }
        }
        let result = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw LocalServiceError.emptyResponse }
        return result
    }

    func testConnection() async -> LocalServiceHealth {
        await Self.testHTTPServer(service: .unsloth, baseURL: baseURL, apiKey: apiKey)
    }

    private func endpoint(_ path: String) throws -> URL {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(normalized)/\(path)") else { throw LocalServiceError.invalidURL(baseURL) }
        return url
    }

    private static func responseText(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var text = ""
        for try await line in bytes.lines.prefix(8) { text += line }
        return text.isEmpty ? "Unknown server error." : String(text.prefix(500))
    }

    private static func deltaText(from object: [String: Any]) -> String {
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return "" }
        let delta = choice["delta"] as? [String: Any]
        return (delta?["content"] as? String) ?? ""
    }

    private static func toolActivity(from object: [String: Any]) -> String {
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
              let delta = choice["delta"] as? [String: Any],
              let calls = delta["tool_calls"] as? [[String: Any]]
        else { return "" }
        let names = calls.compactMap { call -> String? in
            if let function = call["function"] as? [String: Any], let name = function["name"] as? String { return name }
            return call["name"] as? String
        }
        return names.isEmpty ? "Local server tool activity." : "Local server using \(names.joined(separator: ", "))."
    }

    static func testHTTPServer(service: LocalServiceKind, baseURL: String, apiKey: String = "") async -> LocalServiceHealth {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            return LocalServiceHealth(service: service, detail: "Invalid URL.", checkedAt: Date())
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return LocalServiceHealth(service: service, detail: "No HTTP response.", checkedAt: Date())
            }
            return LocalServiceHealth(
                service: service,
                isReachable: http.statusCode < 500,
                detail: "Server responded with HTTP \(http.statusCode).",
                checkedAt: Date()
            )
        } catch {
            return LocalServiceHealth(service: service, detail: error.localizedDescription, checkedAt: Date())
        }
    }
}

struct SystemTranscriptionClient {
    func transcribe(audioURL: URL) async throws -> String {
        let authorization = await requestAuthorization()
        guard authorization == .authorized else {
            throw LocalServiceError.unavailable("Speech Recognition permission is required for local voice input.")
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw LocalServiceError.unavailable("macOS Speech Recognition is unavailable. Check your language and network settings.")
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            let completion = SystemTranscriptionCompletion(continuation: continuation)
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    task?.cancel()
                    completion.succeed(with: result.bestTranscription.formattedString)
                } else if let error {
                    completion.fail(with: error)
                }
            }
        }
    }

    func status() async -> LocalServiceHealth {
        let authorization = await requestAuthorization()
        let isAvailable = SFSpeechRecognizer()?.isAvailable ?? false
        let ready = authorization == .authorized && isAvailable
        let detail = ready
            ? "macOS Speech Recognition is ready."
            : "Grant Speech Recognition permission in System Settings, then try again."
        return LocalServiceHealth(service: .speechRecognition, isReachable: ready, detail: detail, checkedAt: Date())
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private final class SystemTranscriptionCompletion {
    private let lock = NSLock()
    private var isFinished = false
    private let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func succeed(with text: String) {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        finish {
            result.isEmpty ? continuation.resume(throwing: LocalServiceError.emptyResponse) : continuation.resume(returning: result)
        }
    }

    func fail(with error: Error) {
        finish { continuation.resume(throwing: error) }
    }

    private func finish(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        operation()
    }
}

struct CartesiaSpeechClient {
    static let apiURL = URL(string: "https://api.cartesia.ai/tts/bytes")!
    static let apiVersion = "2026-08-14"

    let apiKey: String
    let model: String
    let voiceID: String

    func generateSpeech(text: String) async throws -> Data {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw LocalServiceError.unavailable("Add a Cartesia API key in Settings to use Sonic speech.")
        }
        let payload: [String: Any] = [
            "model_id": model,
            "transcript": text,
            "voice": voiceID,
            "output_format": [
                "container": "wav",
                "encoding": "pcm_s16le",
                "sample_rate": 44_100
            ],
            "locale": "en-US"
        ]
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown error."
            throw LocalServiceError.badResponse("Cartesia speech request failed: \(detail.prefix(300))")
        }
        guard !data.isEmpty else { throw LocalServiceError.emptyResponse }
        return data
    }

    func testConnection() async -> LocalServiceHealth {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return LocalServiceHealth(service: .cartesia, detail: "Add a Cartesia API key.", checkedAt: Date())
        }
        var request = URLRequest(url: URL(string: "https://api.cartesia.ai/voices?limit=1")!)
        request.timeoutInterval = 8
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return LocalServiceHealth(service: .cartesia, detail: "No HTTP response.", checkedAt: Date())
            }
            let ready = (200..<300).contains(http.statusCode)
            return LocalServiceHealth(
                service: .cartesia,
                isReachable: ready,
                detail: ready ? "Cartesia Sonic is ready." : "Cartesia HTTP \(http.statusCode). Check the API key.",
                checkedAt: Date()
            )
        } catch {
            return LocalServiceHealth(service: .cartesia, detail: error.localizedDescription, checkedAt: Date())
        }
    }
}
