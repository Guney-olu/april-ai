import Foundation

@MainActor
final class LiveToolExecutor {
    private let context: ContextLibrary
    private let computerControl: ComputerControlService
    private let gemini: () -> GeminiClient
    private let settings: () -> AppSettings
    private let onMemoryChanged: () async -> Void

    init(
        context: ContextLibrary,
        computerControl: ComputerControlService,
        gemini: @escaping () -> GeminiClient,
        settings: @escaping () -> AppSettings,
        onMemoryChanged: @escaping () async -> Void
    ) {
        self.context = context
        self.computerControl = computerControl
        self.gemini = gemini
        self.settings = settings
        self.onMemoryChanged = onMemoryChanged
    }

    static let toolDeclarations: [[String: Any]] = [
        [
            "name": "search_memory",
            "description": "Search April AI's approved local memories when the user asks about personal preferences, goals, project history, decisions, or prior context.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The memory search query."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of memories to return. Use 3-8."
                    ],
                    "types": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Optional memory types to prefer: episodic, semantic, preference, procedural, prospective."
                    ]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "save_memory",
            "description": "Save a safe, durable local memory about the user's preferences, goals, project decisions, or reusable workflows. Do not use for secrets, credentials, payment data, or sensitive personal facts.",
            "parameters": [
                "type": "object",
                "properties": [
                    "type": [
                        "type": "string",
                        "description": "Memory type: episodic, semantic, preference, procedural, or prospective."
                    ],
                    "content": [
                        "type": "string",
                        "description": "The durable memory to save."
                    ],
                    "summary": [
                        "type": "string",
                        "description": "Short label for the memory."
                    ],
                    "confidence": [
                        "type": "number",
                        "description": "Confidence from 0.0 to 1.0."
                    ],
                    "importance": [
                        "type": "number",
                        "description": "Importance from 0.0 to 1.0."
                    ],
                    "evidence": [
                        "type": "string",
                        "description": "Brief evidence from the conversation."
                    ],
                    "sensitivity": [
                        "type": "string",
                        "description": "Sensitivity: low, medium, or high."
                    ]
                ],
                "required": ["content"]
            ]
        ],
        [
            "name": "google_search",
            "description": "Search the web with Google grounding for current facts, factual verification, or information outside local memory.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The search question or topic."
                    ],
                    "context": [
                        "type": "string",
                        "description": "Optional context from the current conversation to focus the search."
                    ]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "move_mouse",
            "description": "Move the mouse cursor to normalized main-display coordinates. Requires a visible one-time user confirmation and Accessibility permission.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "number", "description": "Horizontal coordinate from 0.0 left to 1.0 right."],
                    "y": ["type": "number", "description": "Vertical coordinate from 0.0 top to 1.0 bottom."]
                ],
                "required": ["x", "y"]
            ]
        ],
        [
            "name": "click_mouse",
            "description": "Click, double-click, or right-click the mouse. Optional normalized x/y moves before clicking. Requires Accessibility permission and executes without a per-click confirmation.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "number", "description": "Optional horizontal coordinate from 0.0 to 1.0."],
                    "y": ["type": "number", "description": "Optional vertical coordinate from 0.0 to 1.0."],
                    "button": ["type": "string", "description": "left or right."],
                    "count": ["type": "integer", "description": "1 for click, 2 for double-click."]
                ]
            ]
        ],
        [
            "name": "scroll_mouse",
            "description": "Scroll the active UI by pixel deltas. Requires visible one-time confirmation and Accessibility permission.",
            "parameters": [
                "type": "object",
                "properties": [
                    "delta_x": ["type": "number", "description": "Horizontal scroll delta, clamped to -200...200."],
                    "delta_y": ["type": "number", "description": "Vertical scroll delta, clamped to -200...200."]
                ],
                "required": ["delta_y"]
            ]
        ],
        [
            "name": "type_text",
            "description": "Type or paste text into the currently focused field without a per-action confirmation. Requires Accessibility permission. Do not use for passwords, secrets, purchases, sending messages, or irreversible workflows.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The exact text to type."]
                ],
                "required": ["text"]
            ]
        ],
        [
            "name": "press_key",
            "description": "Press one allowed key without a per-action confirmation. Requires Accessibility permission. Allowed keys: return, tab, escape, delete, arrow keys, and cmd+l.",
            "parameters": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "return, tab, escape, delete, left, right, up, down, or l with cmd."],
                    "modifiers": ["type": "array", "items": ["type": "string"], "description": "Optional modifiers. Only cmd/command is useful for l."]
                ],
                "required": ["key"]
            ]
        ],
        [
            "name": "open_application",
            "description": "Open an installed macOS application by exact app name or bundle id after visible one-time confirmation. Ambiguous names return candidate matches.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "Application name, e.g. Brave Browser, or bundle id."]
                ],
                "required": ["app"]
            ]
        ]
    ]

    func execute(_ calls: [LiveToolFunctionCall]) async -> [LiveToolFunctionResponse] {
        var responses: [LiveToolFunctionResponse] = []
        for call in calls {
            let response: [String: Any]
            do {
                switch call.name {
                case "search_memory":
                    response = try await searchMemory(args: call.args)
                case "save_memory":
                    response = try await saveMemory(args: call.args)
                case "google_search":
                    response = try await googleSearch(args: call.args)
                case "move_mouse":
                    response = computerControl.moveMouse(
                        x: doubleArg("x", in: call.args) ?? -1,
                        y: doubleArg("y", in: call.args) ?? -1
                    ).toolResponse
                case "click_mouse":
                    response = computerControl.clickMouse(
                        x: doubleArg("x", in: call.args),
                        y: doubleArg("y", in: call.args),
                        button: stringArg("button", in: call.args).isEmpty ? "left" : stringArg("button", in: call.args),
                        count: intArg("count", in: call.args) ?? 1
                    ).toolResponse
                case "scroll_mouse":
                    response = computerControl.scrollMouse(
                        deltaX: doubleArg("delta_x", in: call.args) ?? 0,
                        deltaY: doubleArg("delta_y", in: call.args) ?? 0
                    ).toolResponse
                case "type_text":
                    response = await computerControl.typeText(stringArg("text", in: call.args)).toolResponse
                case "press_key":
                    response = computerControl.pressKey(
                        stringArg("key", in: call.args),
                        modifiers: stringArrayArg("modifiers", in: call.args)
                    ).toolResponse
                case "open_application":
                    response = computerControl.openApplication(stringArg("app", in: call.args)).toolResponse
                default:
                    response = [
                        "ok": false,
                        "error": "Unknown tool: \(call.name)"
                    ]
                }
            } catch {
                response = [
                    "ok": false,
                    "error": error.localizedDescription
                ]
            }

            responses.append(LiveToolFunctionResponse(
                id: call.id,
                name: call.name,
                response: response
            ))
        }
        return responses
    }

    private func searchMemory(args: [String: Any]) async throws -> [String: Any] {
        let query = stringArg("query", in: args)
        guard !query.isEmpty else {
            return ["ok": false, "error": "query is required"]
        }

        let limit = max(1, min(intArg("limit", in: args) ?? 6, 10))
        let requestedTypes = Set(stringArrayArg("types", in: args).compactMap { MemoryKind(rawValue: $0.lowercased()) })
        let embedding = try? await gemini().embedText(
            query,
            title: "Live memory tool query",
            isQuery: true,
            embeddingModel: settings().embeddingModel,
            dimensions: settings().embeddingDimensions
        )

        var results = context.searchMemories(query, embedding: embedding, limit: limit * 2)
        if !requestedTypes.isEmpty {
            results = results.filter { requestedTypes.contains($0.item.type) }
        }
        results = Array(results.prefix(limit))

        return [
            "ok": true,
            "query": query,
            "matches": results.map { result in
                [
                    "id": result.item.id,
                    "type": result.item.type.rawValue,
                    "content": result.item.content,
                    "summary": result.item.summary,
                    "source": result.item.source,
                    "confidence": result.item.confidence,
                    "importance": result.item.importance,
                    "score": result.score
                ] as [String: Any]
            }
        ]
    }

    private func saveMemory(args: [String: Any]) async throws -> [String: Any] {
        let content = stringArg("content", in: args)
        guard !content.isEmpty else {
            return ["ok": false, "error": "content is required"]
        }

        let sensitivity = stringArg("sensitivity", in: args).lowercased()
        guard sensitivity != "high", !looksSensitive(content) else {
            return [
                "ok": false,
                "saved": false,
                "reason": "Rejected because the memory looks sensitive or secret-like."
            ]
        }

        let type = MemoryKind(rawValue: stringArg("type", in: args).lowercased()) ?? .semantic
        let candidate = MemoryCandidate(
            type: type,
            content: content,
            summary: stringArg("summary", in: args).isEmpty ? content : stringArg("summary", in: args),
            evidence: stringArg("evidence", in: args),
            sensitivity: sensitivity.isEmpty ? "low" : sensitivity,
            confidence: clamped(doubleArg("confidence", in: args) ?? 0.75),
            importance: clamped(doubleArg("importance", in: args) ?? 0.7),
            reason: "Saved by Live memory tool.",
            isSelected: true
        )

        let embedding = try? await gemini().embedText(
            candidate.content,
            title: "\(candidate.type.label) memory",
            isQuery: false,
            embeddingModel: settings().embeddingModel,
            dimensions: settings().embeddingDimensions
        )

        try context.saveReviewedMemories(
            candidates: [candidate],
            sessionTitle: "Live memory tool",
            sessionSummary: "Memory saved from a Gemini Live tool call.",
            embeddings: embedding.map { [candidate.id: $0] } ?? [:],
            embeddingModel: settings().embeddingModel,
            dimensions: settings().embeddingDimensions
        )
        await onMemoryChanged()

        return [
            "ok": true,
            "saved": true,
            "type": candidate.type.rawValue,
            "content": candidate.content,
            "embedded": embedding != nil
        ]
    }

    private func googleSearch(args: [String: Any]) async throws -> [String: Any] {
        let query = stringArg("query", in: args)
        guard !query.isEmpty else {
            return ["ok": false, "error": "query is required"]
        }

        let context = stringArg("context", in: args)
        let result: GroundedSearchResult
        do {
            result = try await gemini().generateGroundedSearch(query: query, context: context)
        } catch {
            var fallback = gemini()
            fallback.model = "gemini-3.1-flash-lite"
            result = try await fallback.generateGroundedSearch(query: query, context: context)
        }

        return [
            "ok": true,
            "query": query,
            "answer": result.answer,
            "queries": result.queries,
            "sources": result.sources.map { ["title": $0.title, "uri": $0.uri] }
        ]
    }

    private func looksSensitive(_ text: String) -> Bool {
        let lower = text.lowercased()
        let blockedTerms = [
            "api key", "apikey", "password", "passcode", "private key", "secret",
            "token", "credit card", "debit card", "cvv", "ssn", "social security"
        ]
        if blockedTerms.contains(where: { lower.contains($0) }) {
            return true
        }

        let patterns = [
            #"AIza[0-9A-Za-z_-]{20,}"#,
            #"(?i)bearer\s+[0-9a-z._-]{20,}"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"\b(?:\d[ -]*?){13,19}\b"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private func stringArg(_ key: String, in args: [String: Any]) -> String {
        if let value = args[key] as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = args[key] as? NSNumber {
            return value.stringValue
        }
        return ""
    }

    private func stringArrayArg(_ key: String, in args: [String: Any]) -> [String] {
        (args[key] as? [String]) ?? []
    }

    private func intArg(_ key: String, in args: [String: Any]) -> Int? {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? NSNumber { return value.intValue }
        if let value = args[key] as? String { return Int(value) }
        return nil
    }

    private func doubleArg(_ key: String, in args: [String: Any]) -> Double? {
        if let value = args[key] as? Double { return value }
        if let value = args[key] as? NSNumber { return value.doubleValue }
        if let value = args[key] as? String { return Double(value) }
        return nil
    }

    private func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
