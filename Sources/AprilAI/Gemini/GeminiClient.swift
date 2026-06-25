import Foundation

struct GeminiClient {
    var apiKey: String
    var model: String

    func generateText(
        system: String,
        prompt: String,
        imagePNG: Data? = nil,
        audioMIMEType: String? = nil,
        audioData: Data? = nil,
        useGoogleSearch: Bool = false
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var parts: [[String: Any]] = [["text": prompt]]

        if let imagePNG {
            parts.append([
                "inline_data": [
                    "mime_type": "image/png",
                    "data": imagePNG.base64EncodedString()
                ]
            ])
        }

        if let audioMIMEType, let audioData {
            parts.append([
                "inline_data": [
                    "mime_type": audioMIMEType,
                    "data": audioData.base64EncodedString()
                ]
            ])
        }

        var payload: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "temperature": 0.8,
                "topP": 0.95
            ]
        ]

        if useGoogleSearch {
            payload["tools"] = [["google_search": [:]]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.badResponse("Gemini returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractError(from: data) ?? "Gemini HTTP \(http.statusCode)"
            throw GeminiError.badResponse(message)
        }

        guard let text = Self.extractText(from: data), !text.isEmpty else {
            throw GeminiError.badResponse("Gemini returned no text.")
        }
        return text
    }

    func generateSpeech(
        text: String,
        ttsModel: String = AppSettings.defaultTTSModel,
        voiceName: String = AppSettings.defaultTTSVoice
    ) async throws -> Data {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(ttsModel):generateContent")!
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": text]]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": voiceName
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.badResponse("Gemini TTS returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractError(from: data) ?? "Gemini TTS HTTP \(http.statusCode)"
            throw GeminiError.badResponse(message)
        }

        guard let pcm = Self.extractAudioPCM(from: data) else {
            throw GeminiError.badResponse("Gemini TTS returned no audio.")
        }
        return Self.wavData(fromPCM: pcm, sampleRate: 24_000, channels: 1, bitsPerSample: 16)
    }

    func embedText(
        _ text: String,
        title: String,
        isQuery: Bool,
        embeddingModel: String = AppSettings.defaultEmbeddingModel,
        dimensions: Int = AppSettings.defaultEmbeddingDimensions
    ) async throws -> [Float] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let formatted = isQuery
            ? "task: question answering | query: \(text)"
            : "title: \(title.isEmpty ? "none" : title) | text: \(text)"

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(embeddingModel):embedContent")!
        let payload: [String: Any] = [
            "model": "models/\(embeddingModel)",
            "content": [
                "parts": [["text": formatted]]
            ],
            "output_dimensionality": dimensions
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.badResponse("Gemini embeddings returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractError(from: data) ?? "Gemini embeddings HTTP \(http.statusCode)"
            throw GeminiError.badResponse(message)
        }

        guard let embedding = Self.extractEmbedding(from: data), !embedding.isEmpty else {
            throw GeminiError.badResponse("Gemini embeddings returned no vector.")
        }
        return embedding
    }

    func generateGroundedSearch(query: String, context: String = "") async throws -> GroundedSearchResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let prompt = """
        Answer this question using Google Search grounding when useful.

        Question:
        \(query)

        Conversation context:
        \(context.isEmpty ? "None." : context)

        Keep the answer concise for a live voice assistant. Include concrete facts and avoid filler.
        """

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt]]
                ]
            ],
            "tools": [
                ["google_search": [:]]
            ],
            "generationConfig": [
                "temperature": 0.35,
                "topP": 0.9
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.badResponse("Gemini Search returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractError(from: data) ?? "Gemini Search HTTP \(http.statusCode)"
            throw GeminiError.badResponse(message)
        }

        guard let answer = Self.extractText(from: data), !answer.isEmpty else {
            throw GeminiError.badResponse("Gemini Search returned no answer.")
        }

        let grounding = Self.extractGrounding(from: data)
        return GroundedSearchResult(
            answer: answer,
            queries: grounding.queries,
            sources: grounding.sources
        )
    }

    func runManagedAgent(
        prompt: String,
        agent: String = "antigravity-preview-05-2026",
        systemInstruction: String = "",
        previousInteractionID: String = "",
        environmentID: String = "",
        tools: [[String: Any]] = [
            ["type": "code_execution"],
            ["type": "google_search"],
            ["type": "url_context"]
        ]
    ) async throws -> ManagedAgentInteraction {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        var payload: [String: Any] = [
            "agent": agent,
            "input": [
                [
                    "type": "text",
                    "text": prompt
                ]
            ],
            "environment": environmentID.isEmpty ? ["type": "remote"] : environmentID,
            "tools": tools
        ]

        if !systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["system_instruction"] = systemInstruction
        }
        if !previousInteractionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["previous_interaction_id"] = previousInteractionID
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.badResponse("Managed agent returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractError(from: data) ?? "Managed agent HTTP \(http.statusCode)"
            throw GeminiError.badResponse(message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.badResponse("Managed agent returned invalid JSON.")
        }

        return ManagedAgentInteraction(json: json)
    }

    func downloadEnvironmentSnapshot(environmentID: String) async throws -> Data {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.missingAPIKey
        }
        guard !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.badResponse("Environment id is required to download sandbox files.")
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/files/environment-\(environmentID):download?alt=media")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.badResponse("Environment download returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractError(from: data) ?? "Environment download HTTP \(http.statusCode)"
            throw GeminiError.badResponse(message)
        }

        return data
    }

    @MainActor
    func runComputerUseInteraction(
        input: [[String: Any]],
        mode: ComputerUseMode,
        previousInteractionID: String = ""
    ) async throws -> ComputerUseInteraction {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        var payload: [String: Any] = [
            "model": AppSettings.defaultComputerUseModel,
            "input": input,
            "tools": [
                [
                    "type": "computer_use",
                    "environment": mode.rawValue,
                    "enable_prompt_injection_detection": true
                ]
            ]
        ]

        if !previousInteractionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["previous_interaction_id"] = previousInteractionID
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.badResponse("Computer Use returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractError(from: data) ?? "Computer Use HTTP \(http.statusCode)"
            throw GeminiError.badResponse(message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.badResponse("Computer Use returned invalid JSON.")
        }

        return ComputerUseInteraction(json: json)
    }

    private static func extractText(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            return nil
        }

        return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractError(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return String(data: data, encoding: .utf8)
        }
        return message
    }

    private static func extractAudioPCM(from data: Data) -> Data? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            return nil
        }

        for part in parts {
            let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
            if let base64 = inline?["data"] as? String, let audio = Data(base64Encoded: base64) {
                return audio
            }
        }
        return nil
    }

    private static func extractEmbedding(from data: Data) -> [Float]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if
            let embeddings = json["embeddings"] as? [[String: Any]],
            let values = embeddings.first?["values"] as? [NSNumber]
        {
            return values.map { $0.floatValue }
        }

        if
            let embedding = json["embedding"] as? [String: Any],
            let values = embedding["values"] as? [NSNumber]
        {
            return values.map { $0.floatValue }
        }

        return nil
    }

    private static func extractGrounding(from data: Data) -> (queries: [String], sources: [GroundedSearchSource]) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let metadata = candidates.first?["groundingMetadata"] as? [String: Any]
        else {
            return ([], [])
        }

        let queries = metadata["webSearchQueries"] as? [String] ?? []
        let chunks = metadata["groundingChunks"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        let sources = chunks.compactMap { chunk -> GroundedSearchSource? in
            guard
                let web = chunk["web"] as? [String: Any],
                let uri = web["uri"] as? String,
                !uri.isEmpty
            else {
                return nil
            }

            guard !seen.contains(uri) else { return nil }
            seen.insert(uri)

            let title = (web["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return GroundedSearchSource(title: title?.isEmpty == false ? title! : uri, uri: uri)
        }

        return (queries, sources)
    }

    static func wavData(fromPCM pcm: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
        var data = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let subchunk2Size = UInt32(pcm.count)
        let chunkSize = 36 + subchunk2Size

        data.appendASCII("RIFF")
        data.appendLittleEndian(chunkSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(subchunk2Size)
        data.append(pcm)
        return data
    }
}

extension ComputerUseInteraction {
    init(json: [String: Any]) {
        self.rawJSON = json
        self.id = Self.firstString(json, keys: ["id", "name", "interaction_id"])
        self.outputText = Self.outputText(from: json)
        self.functionCalls = Self.functionCalls(from: json)
    }

    private static func firstString(_ json: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let string = json[key] as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }
        return ""
    }

    private static func outputText(from json: [String: Any]) -> String {
        if let text = json["output_text"] as? String { return text }
        if let text = json["outputText"] as? String { return text }
        if let text = json["output"] as? String { return text }
        if let output = json["output"] as? [String: Any], let text = output["text"] as? String { return text }
        let texts = steps(from: json).compactMap { step -> String? in
            if step["type"] as? String == "model_output" {
                return text(from: step)
            }
            return nil
        }
        return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func functionCalls(from json: [String: Any]) -> [ComputerUseFunctionCall] {
        steps(from: json).compactMap { step in
            let type = (step["type"] as? String)?.lowercased() ?? ""
            let hasCallShape = step["functionCall"] != nil || step["function_call"] != nil
            guard type == "function_call" || hasCallShape else { return nil }

            let call = (step["functionCall"] as? [String: Any])
                ?? (step["function_call"] as? [String: Any])
                ?? step
            let name = firstString(call, keys: ["name", "function", "tool"])
            guard !name.isEmpty else { return nil }
            let arguments = (call["arguments"] as? [String: Any])
                ?? (call["args"] as? [String: Any])
                ?? (step["arguments"] as? [String: Any])
                ?? [:]
            let id = firstString(call, keys: ["id", "call_id", "callId"])
                .ifEmpty(UUID().uuidString)
            return ComputerUseFunctionCall(id: id, name: name, arguments: arguments)
        }
    }

    private static func steps(from json: [String: Any]) -> [[String: Any]] {
        if let steps = json["steps"] as? [[String: Any]] { return steps }
        if let output = json["output"] as? [String: Any], let steps = output["steps"] as? [[String: Any]] { return steps }
        return []
    }

    private static func text(from step: [String: Any]) -> String {
        if let text = step["text"] as? String { return text }
        if let text = step["content"] as? String { return text }
        if let content = step["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }
}

struct ManagedAgentInteraction: Equatable {
    let id: String
    let environmentID: String
    let status: String
    let outputText: String
    let stepSummaries: [String]
    let rawJSON: [String: Any]

    init(json: [String: Any]) {
        self.rawJSON = json
        self.id = Self.firstString(json, keys: ["id", "name", "interaction_id"])
        self.environmentID = Self.firstString(json, keys: ["environment_id", "environmentId"])
        self.status = Self.firstString(json, keys: ["status", "state"])
        self.outputText = Self.outputText(from: json)
        self.stepSummaries = Self.stepSummaries(from: json)
    }

    static func == (lhs: ManagedAgentInteraction, rhs: ManagedAgentInteraction) -> Bool {
        lhs.id == rhs.id
            && lhs.environmentID == rhs.environmentID
            && lhs.status == rhs.status
            && lhs.outputText == rhs.outputText
            && lhs.stepSummaries == rhs.stepSummaries
    }

    private static func firstString(_ json: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let string = json[key] as? String, !string.isEmpty {
                return string
            }
        }
        return ""
    }

    private static func outputText(from json: [String: Any]) -> String {
        if let text = json["output_text"] as? String {
            return text
        }
        if let text = json["outputText"] as? String {
            return text
        }
        if let output = json["output"] as? String {
            return output
        }
        if let output = json["output"] as? [String: Any],
           let text = output["text"] as? String {
            return text
        }
        return ""
    }

    private static func stepSummaries(from json: [String: Any]) -> [String] {
        guard let steps = json["steps"] as? [[String: Any]] else { return [] }
        return steps.prefix(20).map { step in
            let type = firstString(step, keys: ["type", "kind"])
            let name = firstString(step, keys: ["name", "tool", "title"])
            let text = firstString(step, keys: ["text", "summary", "content"])
            return [type, name, text]
                .filter { !$0.isEmpty }
                .joined(separator: ": ")
        }
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your Gemini API key in Settings first."
        case .badResponse(let message):
            message
        }
    }
}
