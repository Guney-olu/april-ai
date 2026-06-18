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
