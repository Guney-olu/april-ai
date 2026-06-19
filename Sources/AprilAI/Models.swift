import CoreGraphics
import Foundation

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case context = "Context"
    case research = "Research"
    case memory = "Memory"
    case settings = "Settings"

    var id: String { rawValue }
}

enum ChatRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatRole
    let content: String
    let spokenSummary: String
    let references: [ContextReference]
    let createdAt: Date

    init(role: ChatRole, content: String, spokenSummary: String = "", references: [ContextReference] = []) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.spokenSummary = spokenSummary
        self.references = references
        self.createdAt = Date()
    }
}

struct ContextReference: Identifiable, Codable, Equatable {
    let id: UUID
    let source: String
    let snippet: String

    init(source: String, snippet: String) {
        self.id = UUID()
        self.source = source
        self.snippet = snippet
    }
}

enum MemoryKind: String, Codable, CaseIterable, Identifiable {
    case episodic
    case semantic
    case preference
    case procedural
    case prospective

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }
}

struct MemoryItem: Identifiable, Codable, Equatable {
    let id: String
    var type: MemoryKind
    var content: String
    var summary: String
    var source: String
    var confidence: Double
    var importance: Double
    var createdAt: Date
    var updatedAt: Date
    var status: String
}

struct MemorySearchResult: Identifiable, Codable, Equatable {
    let id: String
    let item: MemoryItem
    let score: Double

    init(item: MemoryItem, score: Double) {
        self.id = item.id
        self.item = item
        self.score = score
    }
}

struct MemoryCandidate: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: MemoryKind
    var content: String
    var summary: String
    var evidence: String
    var sensitivity: String
    var confidence: Double
    var importance: Double
    var reason: String
    var isSelected = true

    init(
        id: UUID = UUID(),
        type: MemoryKind,
        content: String,
        summary: String,
        evidence: String,
        sensitivity: String,
        confidence: Double,
        importance: Double,
        reason: String,
        isSelected: Bool = true
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.summary = summary
        self.evidence = evidence
        self.sensitivity = sensitivity
        self.confidence = confidence
        self.importance = importance
        self.reason = reason
        self.isSelected = isSelected
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case content
        case summary
        case evidence
        case sensitivity
        case confidence
        case importance
        case reason
        case isSelected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let rawType = try container.decodeIfPresent(String.self, forKey: .type) ?? MemoryKind.semantic.rawValue
        self.type = MemoryKind(rawValue: rawType) ?? .semantic
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        self.sensitivity = try container.decodeIfPresent(String.self, forKey: .sensitivity) ?? "low"
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.6
        self.importance = try container.decodeIfPresent(Double.self, forKey: .importance) ?? 0.5
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        self.isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? true
    }
}

struct SessionMemoryReview: Codable, Equatable {
    var title: String
    var summary: String
    var candidates: [MemoryCandidate]
}

struct IndexedDocument: Identifiable, Codable, Equatable {
    let id: Int64
    let path: String
    let title: String
    let modifiedAt: Date
    let indexedAt: Date
    let chunkCount: Int
}

struct MemoryRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let content: String
    let createdAt: Date

    init(content: String) {
        self.id = UUID()
        self.content = content
        self.createdAt = Date()
    }
}

struct ResearchReport: Identifiable, Codable, Equatable {
    let id: UUID
    let topic: String
    let path: String
    let createdAt: Date

    init(topic: String, path: String) {
        self.id = UUID()
        self.topic = topic
        self.path = path
        self.createdAt = Date()
    }
}

struct LiveToolFunctionCall {
    let id: String
    let name: String
    let args: [String: Any]
}

struct LiveToolFunctionResponse {
    let id: String
    let name: String
    let response: [String: Any]
}

struct GroundedSearchSource: Codable, Equatable {
    let title: String
    let uri: String
}

struct GroundedSearchResult: Codable, Equatable {
    let answer: String
    let queries: [String]
    let sources: [GroundedSearchSource]
}

struct ComputerControlResult {
    let ok: Bool
    let message: String
    let denied: Bool
    let metadata: [String: Any]

    init(ok: Bool, message: String, denied: Bool = false, metadata: [String: Any] = [:]) {
        self.ok = ok
        self.message = message
        self.denied = denied
        self.metadata = metadata
    }

    var toolResponse: [String: Any] {
        var response = metadata
        response["ok"] = ok
        response["message"] = message
        if denied {
            response["denied"] = true
        }
        return response
    }
}

extension ComputerControlResult {
    func mergingMetadata(_ extra: [String: Any]) -> ComputerControlResult {
        ComputerControlResult(
            ok: ok,
            message: message,
            denied: denied,
            metadata: metadata.merging(extra) { _, new in new }
        )
    }
}

struct ScreenFrameGeometry: Equatable {
    let displayID: UInt32
    let capturePixelWidth: Int
    let capturePixelHeight: Int
    let sentImageWidth: Int
    let sentImageHeight: Int
    let logicalBounds: CGRect
    let backingScaleFactor: Double
    let capturedAt: Date

    var toolMetadata: [String: Any] {
        [
            "display_id": displayID,
            "captured_at": ISO8601DateFormatter().string(from: capturedAt),
            "frame_age_seconds": Date().timeIntervalSince(capturedAt),
            "capture_pixels": [
                "width": capturePixelWidth,
                "height": capturePixelHeight
            ],
            "sent_image_pixels": [
                "width": sentImageWidth,
                "height": sentImageHeight
            ],
            "logical_bounds": [
                "x": logicalBounds.origin.x,
                "y": logicalBounds.origin.y,
                "width": logicalBounds.width,
                "height": logicalBounds.height
            ],
            "backing_scale_factor": backingScaleFactor
        ]
    }
}

struct ScreenFrame {
    let data: Data
    let geometry: ScreenFrameGeometry
}

struct AppSettings: Codable, Equatable {
    static let defaultTextModel = "gemini-3.5-flash"
    static let defaultLiveModel = "gemini-3.1-flash-live-preview"
    static let defaultTeacherModel = "gemini-3.5-flash"
    static let defaultTTSModel = "gemini-3.1-flash-tts-preview"
    static let defaultTTSVoice = "Aoede"
    static let defaultEmbeddingModel = "gemini-embedding-2"
    static let defaultEmbeddingDimensions = 768

    var model: String = Self.defaultTextModel
    var liveModel: String = Self.defaultLiveModel
    var ttsModel: String = Self.defaultTTSModel
    var ttsVoice: String = Self.defaultTTSVoice
    var embeddingModel: String = Self.defaultEmbeddingModel
    var embeddingDimensions: Int = Self.defaultEmbeddingDimensions
    var apiKeyStored: Bool = false
    var contextFolderPath: String = ""
    var speakReplies: Bool = true
    var useGoogleSearchForResearch: Bool = true

    private static let storageKey = "AprilAI.AppSettings"
    private static let legacyStorageKey = "PolymathAssistant.AppSettings"
    private enum CodingKeys: String, CodingKey {
        case model
        case liveModel
        case ttsModel
        case ttsVoice
        case embeddingModel
        case embeddingDimensions
        case apiKeyStored
        case contextFolderPath
        case speakReplies
        case useGoogleSearchForResearch
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedModel = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultTextModel
        self.model = storedModel == "gemini-2.5-flash" ? Self.defaultTextModel : storedModel
        self.liveModel = try container.decodeIfPresent(String.self, forKey: .liveModel) ?? Self.defaultLiveModel
        self.ttsModel = try container.decodeIfPresent(String.self, forKey: .ttsModel) ?? Self.defaultTTSModel
        self.ttsVoice = try container.decodeIfPresent(String.self, forKey: .ttsVoice) ?? Self.defaultTTSVoice
        self.embeddingModel = try container.decodeIfPresent(String.self, forKey: .embeddingModel) ?? Self.defaultEmbeddingModel
        self.embeddingDimensions = try container.decodeIfPresent(Int.self, forKey: .embeddingDimensions) ?? Self.defaultEmbeddingDimensions
        self.apiKeyStored = try container.decodeIfPresent(Bool.self, forKey: .apiKeyStored) ?? false
        self.contextFolderPath = try container.decodeIfPresent(String.self, forKey: .contextFolderPath) ?? ""
        self.speakReplies = try container.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? true
        self.useGoogleSearchForResearch = try container.decodeIfPresent(Bool.self, forKey: .useGoogleSearchForResearch) ?? true
    }

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        if
            let data = defaults.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            return settings
        }

        if
            let legacyData = defaults.data(forKey: legacyStorageKey),
            let legacySettings = try? JSONDecoder().decode(AppSettings.self, from: legacyData)
        {
            return legacySettings
        }

        return AppSettings()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
