import AppKit
import CoreGraphics
import Foundation

private struct MouseTargetLocation {
    let frame: ScreenFrame
    let griddedPNG: Data
    let visionRaw: String
    let parsed: [String: Any]
    let imageX: Double
    let imageY: Double
    let boundingBox: [String: Double]
    let confidence: Double
}

private enum MouseTargetLocationError: LocalizedError {
    case invalidTeacherJSON(String)
    case missingCoordinates(String)

    var errorDescription: String? {
        switch self {
        case .invalidTeacherJSON(let raw):
            "Vision locator did not return parseable JSON for mouse target location. Raw: \(raw)"
        case .missingCoordinates(let parsed):
            "Vision locator JSON was missing numeric image_x/image_y: \(parsed)"
        }
    }
}

@MainActor
final class LiveToolExecutor {
    private let context: ContextLibrary
    private let computerControl: ComputerControlService
    private let accessibilityControl: AccessibilityControlService
    private let gemini: () -> GeminiClient
    private let settings: () -> AppSettings
    private let activeMemorySessionIDs: () -> Set<String>
    private let onMemoryChanged: () async -> Void
    private var mouseToolInFlight = false

    init(
        context: ContextLibrary,
        computerControl: ComputerControlService,
        accessibilityControl: AccessibilityControlService,
        gemini: @escaping () -> GeminiClient,
        settings: @escaping () -> AppSettings,
        activeMemorySessionIDs: @escaping () -> Set<String>,
        onMemoryChanged: @escaping () async -> Void
    ) {
        self.context = context
        self.computerControl = computerControl
        self.accessibilityControl = accessibilityControl
        self.gemini = gemini
        self.settings = settings
        self.activeMemorySessionIDs = activeMemorySessionIDs
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
            "name": "start_agent_task",
            "description": "Start an explicit heavyweight remote sandbox task using Gemini Managed Agents. Use only when the user specifically asks for sandbox, agent, long research, compute, code/data analysis, or artifact generation.",
            "parameters": [
                "type": "object",
                "properties": [
                    "task": ["type": "string", "description": "The full task for the remote sandbox agent."],
                    "kind": ["type": "string", "description": "antigravity or deep_research. Use antigravity for compute/code/files, deep_research for cited research."],
                    "download_snapshot": ["type": "boolean", "description": "Whether to download the sandbox tar snapshot after completion. Use true only when the user asks for files/artifacts."]
                ],
                "required": ["task"]
            ]
        ],
        [
            "name": "teacher_plan_control",
            "description": "Ask the stronger teacher model to plan a complex or failed local-control task. The teacher does not execute actions; it returns a safe tool-use plan.",
            "parameters": [
                "type": "object",
                "properties": [
                    "task": ["type": "string", "description": "The local-control task or recovery problem to plan."],
                    "context": ["type": "string", "description": "Optional current screen/app/conversation context."],
                    "available_tools": ["type": "array", "items": ["type": "string"], "description": "Optional tool names April is considering."],
                    "last_error": ["type": "string", "description": "Optional failed tool result or error to recover from."]
                ],
                "required": ["task"]
            ]
        ],
        [
            "name": "screen_geometry",
            "description": "Return the latest Live screen frame geometry, display bounds, backing scale factor, and current mouse position. Call this before mouse fallback when coordinate accuracy is uncertain.",
            "parameters": [
                "type": "object",
                "properties": [:]
            ]
        ],
        [
            "name": "move_mouse_to_target",
            "description": "The only Live mouse movement tool. Captures the screen, overlays a grid, asks gemini-3-flash-preview for the target image coordinates, then moves the cursor there. It does not click and does not save screenshots.",
            "parameters": [
                "type": "object",
                "properties": [
                    "target_description": ["type": "string", "description": "Visible target to move to, e.g. the Leo AI option, the Brave address bar, the blue Send button."]
                ],
                "required": ["target_description"]
            ]
        ],
        [
            "name": "scroll_mouse",
            "description": "Scroll the active UI by pixel deltas. Requires Accessibility permission and executes without a per-action confirmation.",
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
            "description": "Legacy limited key tool. Prefer keyboard_shortcut. Requires Accessibility permission. Allowed keys: return, tab, escape, delete, arrow keys, and cmd+l.",
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
            "name": "keyboard_shortcut",
            "description": "Run one safe keyboard shortcut without an extra approval dialog. Use a named action or provide key plus modifiers. Use only for reversible local UI control.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "description": "Optional named action: copy, paste, cut, select_all, undo, redo, find, spotlight, cmd_space, open_location, new_tab, close_tab, next_tab, previous_tab, close_window, quit_app, space_left, space_right, return, tab, escape, delete, left, right, up, down."],
                    "key": ["type": "string", "description": "Optional key name for a dynamic shortcut, such as right, left, space, tab, a, c, l."],
                    "modifiers": ["type": "array", "items": ["type": "string"], "description": "Optional modifiers for key: cmd, control, shift, option."]
                ]
            ]
        ],
        [
            "name": "open_application",
            "description": "Open an installed macOS application by exact app name or bundle id without a per-action confirmation. Ambiguous names return candidate matches.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "Application name, e.g. Brave Browser, or bundle id."]
                ],
                "required": ["app"]
            ]
        ],
        [
            "name": "activate_application",
            "description": "Activate a running macOS application by app name or bundle id without moving the cursor.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "Application name, e.g. Brave Browser, or bundle id. Omit only when the frontmost app is intended."]
                ],
                "required": ["app"]
            ]
        ],
        [
            "name": "quit_application",
            "description": "Request a running macOS application to quit by app name or bundle id. Do not use when unsaved work or irreversible consequences are likely.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "Application name or bundle id."]
                ],
                "required": ["app"]
            ]
        ],
        [
            "name": "close_window",
            "description": "Close the frontmost window of the frontmost or named app using AX menu action when available. Do not use for destructive confirmation dialogs.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "Optional app name or bundle id. Omit for frontmost app."]
                ]
            ]
        ],
        [
            "name": "ax_snapshot",
            "description": "Snapshot the frontmost or named native macOS app Accessibility tree. Use this before AX press/set/focus so native apps can be controlled without moving the cursor.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "Optional app name or bundle id. Omit for the frontmost app."]
                ]
            ]
        ],
        [
            "name": "ax_find",
            "description": "Find native macOS Accessibility elements by label/value/role without moving the cursor. Use before semantic AX actions when the target is described in natural language.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Visible label, title, value, or description to find."],
                    "app": ["type": "string", "description": "Optional app name or bundle id. Omit for frontmost app."],
                    "roles": ["type": "array", "items": ["type": "string"], "description": "Optional AX roles to prefer, such as AXButton, AXTextField, AXSearchField, AXMenuItem."],
                    "limit": ["type": "integer", "description": "Maximum matches to return, 1-12."]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "ax_click",
            "description": "Find and press a native macOS Accessibility element by label/role without moving the cursor.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Visible label, title, value, or description to click."],
                    "app": ["type": "string", "description": "Optional app name or bundle id. Omit for frontmost app."],
                    "role": ["type": "string", "description": "Optional AX role to prefer, such as AXButton."]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "ax_focus_match",
            "description": "Find and focus a native macOS Accessibility element by label/role without moving the cursor.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Visible label, title, value, or description to focus."],
                    "app": ["type": "string", "description": "Optional app name or bundle id. Omit for frontmost app."],
                    "role": ["type": "string", "description": "Optional AX role to prefer, such as AXTextField or AXSearchField."]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "ax_set_value_match",
            "description": "Find a native macOS text/value element and set its value without moving the cursor. Do not use for secrets, passwords, or payment data.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Visible label, title, value, or description of the target field."],
                    "value": ["type": "string", "description": "Text/value to set."],
                    "app": ["type": "string", "description": "Optional app name or bundle id. Omit for frontmost app."],
                    "role": ["type": "string", "description": "Optional AX role to prefer, such as AXTextField or AXSearchField."]
                ],
                "required": ["query", "value"]
            ]
        ],
        [
            "name": "ax_menu_action",
            "description": "Run a native app menu action through Accessibility without moving the cursor, such as File > Close Window or Edit > Copy.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "Optional app name or bundle id. Omit for frontmost app."],
                    "menu_path": ["type": "string", "description": "Menu path separated by >, for example File > Close Window."]
                ],
                "required": ["menu_path"]
            ]
        ],
        [
            "name": "ax_press",
            "description": "Perform AXPress on an element id from the latest ax_snapshot without moving the cursor.",
            "parameters": [
                "type": "object",
                "properties": [
                    "element_id": ["type": "string", "description": "Element id from ax_snapshot, such as ax_12."]
                ],
                "required": ["element_id"]
            ]
        ],
        [
            "name": "ax_set_value",
            "description": "Set AXValue on an element id from the latest ax_snapshot without moving the cursor. Do not use for secrets, passwords, or payment data.",
            "parameters": [
                "type": "object",
                "properties": [
                    "element_id": ["type": "string", "description": "Element id from ax_snapshot, such as ax_12."],
                    "value": ["type": "string", "description": "Text or value to set."]
                ],
                "required": ["element_id", "value"]
            ]
        ],
        [
            "name": "ax_focus",
            "description": "Focus an element id from the latest ax_snapshot without moving the cursor.",
            "parameters": [
                "type": "object",
                "properties": [
                    "element_id": ["type": "string", "description": "Element id from ax_snapshot, such as ax_12."]
                ],
                "required": ["element_id"]
            ]
        ]
    ]

    func execute(_ calls: [LiveToolFunctionCall]) async -> [LiveToolFunctionResponse] {
        var responses: [LiveToolFunctionResponse] = []
        for call in calls {
            if Task.isCancelled {
                responses.append(LiveToolFunctionResponse(
                    id: call.id,
                    name: call.name,
                    response: ["ok": false, "cancelled": true, "message": "Tool call cancelled before execution."]
                ))
                continue
            }
            let response: [String: Any]
            do {
                switch call.name {
                case "search_memory":
                    response = try await searchMemory(args: call.args)
                case "save_memory":
                    response = try await saveMemory(args: call.args)
                case "google_search":
                    response = try await googleSearch(args: call.args)
                case "start_agent_task":
                    response = try await startAgentTask(args: call.args)
                case "teacher_plan_control":
                    response = try await teacherPlanControl(args: call.args)
                case "screen_geometry":
                    response = computerControl.screenGeometry().toolResponse
                case "move_mouse_to_target":
                    guard beginMouseTool(call.name) else {
                        response = Self.mouseToolBusyRefusal(call.name)
                        break
                    }
                    defer { endMouseTool() }
                    response = try await moveMouseToTarget(args: call.args)
                case "scroll_mouse":
                    response = computerControl.scrollMouse(
                        deltaX: doubleArg("delta_x", in: call.args) ?? 0,
                        deltaY: doubleArg("delta_y", in: call.args) ?? 0
                    ).toolResponse
                case "type_text":
                    response = await computerControl.typeText(rawStringArg("text", in: call.args)).toolResponse
                case "press_key":
                    response = computerControl.pressKey(
                        stringArg("key", in: call.args),
                        modifiers: stringArrayArg("modifiers", in: call.args)
                    ).toolResponse
                case "keyboard_shortcut":
                    response = computerControl.keyboardShortcut(
                        stringArg("action", in: call.args),
                        key: stringArg("key", in: call.args),
                        modifiers: stringArrayArg("modifiers", in: call.args)
                    ).toolResponse
                case "open_application":
                    response = computerControl.openApplication(stringArg("app", in: call.args)).toolResponse
                case "activate_application":
                    response = computerControl.activateApplication(stringArg("app", in: call.args)).toolResponse
                case "quit_application":
                    response = computerControl.quitApplication(stringArg("app", in: call.args)).toolResponse
                case "close_window":
                    let app = stringArg("app", in: call.args)
                    let closeResult = accessibilityControl.menuAction(app: app, menuPath: "File > Close Window")
                    if closeResult.ok {
                        response = closeResult.toolResponse
                    } else if app.isEmpty {
                        response = computerControl.keyboardShortcut("close_window")
                            .mergingMetadata(["ax_menu_result": closeResult.toolResponse])
                            .toolResponse
                    } else {
                        response = closeResult.toolResponse
                    }
                case "ax_snapshot":
                    response = accessibilityControl.snapshot(app: stringArg("app", in: call.args)).toolResponse
                case "ax_find":
                    response = accessibilityControl.find(
                        query: stringArg("query", in: call.args),
                        app: stringArg("app", in: call.args),
                        roles: stringArrayArg("roles", in: call.args),
                        limit: intArg("limit", in: call.args) ?? 6
                    ).toolResponse
                case "ax_click":
                    response = accessibilityControl.clickMatch(
                        query: stringArg("query", in: call.args),
                        app: stringArg("app", in: call.args),
                        role: stringArg("role", in: call.args)
                    ).toolResponse
                case "ax_focus_match":
                    response = accessibilityControl.focusMatch(
                        query: stringArg("query", in: call.args),
                        app: stringArg("app", in: call.args),
                        role: stringArg("role", in: call.args)
                    ).toolResponse
                case "ax_set_value_match":
                    response = accessibilityControl.setValueMatch(
                        query: stringArg("query", in: call.args),
                        value: rawStringArg("value", in: call.args),
                        app: stringArg("app", in: call.args),
                        role: stringArg("role", in: call.args)
                    ).toolResponse
                case "ax_menu_action":
                    response = accessibilityControl.menuAction(
                        app: stringArg("app", in: call.args),
                        menuPath: stringArg("menu_path", in: call.args)
                    ).toolResponse
                case "ax_press":
                    response = accessibilityControl.press(elementID: stringArg("element_id", in: call.args)).toolResponse
                case "ax_set_value":
                    response = accessibilityControl.setValue(
                        elementID: stringArg("element_id", in: call.args),
                        value: rawStringArg("value", in: call.args)
                    ).toolResponse
                case "ax_focus":
                    response = accessibilityControl.focus(elementID: stringArg("element_id", in: call.args)).toolResponse
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

        let sessionIDs = activeMemorySessionIDs()
        var results = context.searchMemories(
            query,
            embedding: embedding,
            limit: limit * 2,
            sessionIDs: sessionIDs
        )
        if !requestedTypes.isEmpty {
            results = results.filter { requestedTypes.contains($0.item.type) }
        }
        results = Array(results.prefix(limit))

        return [
            "ok": true,
            "query": query,
            "active_session_count": sessionIDs.count,
            "active_session_ids": Array(sessionIDs),
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

    private func startAgentTask(args: [String: Any]) async throws -> [String: Any] {
        let taskPrompt = rawStringArg("task", in: args).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskPrompt.isEmpty else {
            return ["ok": false, "error": "task is required"]
        }

        let kindRaw = stringArg("kind", in: args).lowercased()
        let kind: AgentTaskKind = kindRaw.contains("deep") ? .deepResearch : .antigravity
        var task = AgentTask(
            topic: String(taskPrompt.prefix(90)),
            prompt: taskPrompt,
            kind: kind,
            status: .running
        )
        try context.saveAgentTask(task)

        do {
            let interaction = try await gemini().runManagedAgent(
                prompt: liveAgentPrompt(taskPrompt, kind: kind),
                systemInstruction: liveAgentSystemInstruction(kind: kind)
            )
            task.status = interaction.status == "requires_action" ? .requiresAction : .completed
            task.interactionID = interaction.id
            task.environmentID = interaction.environmentID
            task.outputText = interaction.outputText
            let markdown = liveAgentMarkdown(task: task, interaction: interaction)
            task = try context.saveAgentTaskOutput(task, markdown: markdown)

            let shouldDownload = boolArg("download_snapshot", in: args) ?? false
            if shouldDownload, !interaction.environmentID.isEmpty {
                let snapshot = try await gemini().downloadEnvironmentSnapshot(environmentID: interaction.environmentID)
                task = try context.saveAgentEnvironmentSnapshot(task: task, tarData: snapshot)
            }

            try context.saveAgentTask(task)
            return [
                "ok": true,
                "task_id": task.id.uuidString,
                "kind": task.kind.rawValue,
                "status": task.status.rawValue,
                "interaction_id": task.interactionID,
                "environment_id": task.environmentID,
                "report_path": task.path,
                "artifact_path": task.artifactPath,
                "output": task.outputText
            ]
        } catch {
            task.status = .failed
            task.error = error.localizedDescription
            task.updatedAt = Date()
            try? context.saveAgentTask(task)
            throw error
        }
    }

    private func liveAgentSystemInstruction(kind: AgentTaskKind) -> String {
        switch kind {
        case .deepResearch:
            return "You are April AI's remote deep research worker. Plan, search, verify, cite sources, and return a clear Markdown report. Save useful artifacts in the sandbox."
        case .antigravity, .localResearch:
            return "You are April AI's remote sandbox worker. Use code execution, files, and web access when useful. Return concise results and mention generated file paths."
        }
    }

    private func liveAgentPrompt(_ prompt: String, kind: AgentTaskKind) -> String {
        switch kind {
        case .deepResearch:
            return """
            Run this as a deep research-style task. Use web search and URL reading where useful, cite important sources, and produce a final Markdown report.

            Task:
            \(prompt)
            """
        case .antigravity, .localResearch:
            return prompt
        }
    }

    private func liveAgentMarkdown(task: AgentTask, interaction: ManagedAgentInteraction) -> String {
        """
        # \(task.topic)

        - Kind: \(task.kind.label)
        - Status: \(task.status.label)
        - Interaction: \(interaction.id.isEmpty ? "unknown" : interaction.id)
        - Environment: \(interaction.environmentID.isEmpty ? "unknown" : interaction.environmentID)
        - Created: \(task.createdAt)

        ## Prompt
        \(task.prompt)

        ## Output
        \(interaction.outputText.isEmpty ? "_No output text returned._" : interaction.outputText)

        ## Steps
        \(interaction.stepSummaries.isEmpty ? "_No step summaries returned._" : interaction.stepSummaries.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private func teacherPlanControl(args: [String: Any]) async throws -> [String: Any] {
        let task = rawStringArg("task", in: args).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            return ["ok": false, "error": "task is required"]
        }

        let context = rawStringArg("context", in: args)
        let lastError = rawStringArg("last_error", in: args)
        let availableTools = stringArrayArg("available_tools", in: args)
        var teacher = gemini()
        teacher.model = AppSettings.defaultTeacherModel

        let prompt = """
        You are April AI's teacher model for local-control planning. You do not execute tools.
        Return only strict JSON, no markdown.

        Task:
        \(task)

        Context:
        \(context.isEmpty ? "None." : context)

        Available tools:
        \(availableTools.isEmpty ? "Use April AI's existing memory, search, AX, keyboard, mouse, and screen_geometry tools." : availableTools.joined(separator: ", "))

        Last error:
        \(lastError.isEmpty ? "None." : lastError)

        JSON schema:
        {
          "intent_summary": "short",
          "recommended_sequence": [
            {"tool": "tool_name", "reason": "why", "arguments": {"example": "value"}}
          ],
          "coordinate_strategy": "how to avoid bad mouse coordinates",
          "shortcut_strategy": "keyboard approach or macOS limitation",
          "risk_notes": ["short risk notes"],
          "ask_user_if": ["conditions requiring clarification"]
        }
        """

        let raw = try await teacher.generateText(
            system: "Plan safe local-control tool usage. Return strict JSON only.",
            prompt: prompt
        )
        let parsed = Self.parseJSONObject(raw)

        return [
            "ok": true,
            "model": AppSettings.defaultTeacherModel,
            "task": task,
            "plan": parsed ?? ["raw": raw],
            "parsed_json": parsed != nil
        ]
    }

    private func moveMouseToTarget(args: [String: Any]) async throws -> [String: Any] {
        let target = rawStringArg("target_description", in: args).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return ["ok": false, "error": "target_description is required"]
        }

        let location = try await locateMouseTarget(target)
        guard !Task.isCancelled else {
            return Self.cancelledMouseToolResponse("move_mouse_to_target")
        }
        let confidence = location.confidence
        guard confidence >= 0.35 else {
            return [
                "ok": false,
                "error": "Target location confidence too low; not moving cursor.",
                "vision_model": AppSettings.defaultVisionModel,
                "target_description": target,
                "location": location.parsed,
                "screenshot_geometry": location.frame.geometry.toolMetadata
            ]
        }

        let move = computerControl.moveMouse(
            x: nil,
            y: nil,
            coordinateSpace: "image_pixels",
            imageX: location.imageX,
            imageY: location.imageY,
            imageWidth: Double(location.frame.geometry.sentImageWidth),
            imageHeight: Double(location.frame.geometry.sentImageHeight)
        )

        return [
            "ok": move.ok,
            "message": move.message,
            "target_description": target,
            "vision_model": AppSettings.defaultVisionModel,
            "location": location.parsed,
            "vision_raw": location.visionRaw,
            "resolved_image_pixels": [
                "x": location.imageX,
                "y": location.imageY,
                "width": location.frame.geometry.sentImageWidth,
                "height": location.frame.geometry.sentImageHeight
            ],
            "move": move.toolResponse,
            "screenshot_geometry": location.frame.geometry.toolMetadata
        ]
    }

    private func locateMouseTarget(_ target: String) async throws -> MouseTargetLocation {
        let frame = try await ScreenCaptureService.captureMainDisplayPNGFrame(maxDimension: 1280)
        computerControl.updateLatestScreenFrameGeometry(frame.geometry)
        let griddedPNG = try GridOverlayRenderer.renderPNG(basePNG: frame.data)

        var teacher = gemini()
        teacher.model = AppSettings.defaultVisionModel
        let prompt = Self.visionLocatorPrompt(
            target: target,
            width: frame.geometry.sentImageWidth,
            height: frame.geometry.sentImageHeight
        )

        let raw = try await teacher.generateText(
            system: "You are a precise screen target locator. Return strict JSON only. Do not describe actions and do not click.",
            prompt: prompt,
            imagePNG: griddedPNG
        )

        guard var parsed = Self.parseJSONObject(raw) else {
            throw MouseTargetLocationError.invalidTeacherJSON(raw)
        }

        let resolution = try Self.resolveTargetPoint(from: parsed, frame: frame)
        if let bboxCenter = resolution.centerFromBBox {
            parsed["computed_center_from_bbox"] = ["x": bboxCenter.x, "y": bboxCenter.y]
        }
        parsed["resolved_point_source"] = resolution.source

        return MouseTargetLocation(
            frame: frame,
            griddedPNG: griddedPNG,
            visionRaw: raw,
            parsed: parsed,
            imageX: resolution.point.x,
            imageY: resolution.point.y,
            boundingBox: resolution.bbox,
            confidence: Self.doubleValue(parsed["confidence"]) ?? 0
        )
    }

    private static func visionLocatorPrompt(
        target: String,
        width: Int,
        height: Int
    ) -> String {
        """
        Locate the requested target in this screenshot. A faint precision grid is overlaid to help you reason, but return exact image pixel coordinates in this exact image.

        Target:
        \(target)

        Image coordinate system:
        - Width: \(width) pixels
        - Height: \(height) pixels
        - Origin: top-left
        - x increases right
        - y increases down
        - The major grid is 12 columns by 8 rows. Cell A1 is top-left. Cell L8 is bottom-right.
        - Cell width is approximately \(String(format: "%.2f", Double(width) / 12.0)) pixels.
        - Cell height is approximately \(String(format: "%.2f", Double(height) / 8.0)) pixels.

        Return strict JSON only:
        {
          "image_x": 0,
          "image_y": 0,
          "bbox": {"x_min": 0, "y_min": 0, "x_max": 0, "y_max": 0},
          "grid_cell": "A1",
          "target_type": "button|icon|tab|menu_item|text_field|card|row|link|checkbox|other",
          "visible_text": "exact visible label/text used to identify the target, or empty string",
          "visual_anchor": "what visible object proves this is the requested target",
          "click_point": "icon_center|label_center|control_center|field_center|safe_interior_point",
          "local_position": "center of the target within A1",
          "confidence": 0.0,
          "reason": "brief visual evidence"
        }

        Rules:
        - The grid is only a transparent coordinate aid. Never choose a grid label, ruler label, tick mark, or grid line as the target.
        - Use the in-cell labels like D2/E3 for rough location, the faint sub-grid for local position, and the cyan edge rulers for pixel scale.
        - Fill grid_cell with the actual cell containing image_x/image_y. Do not let grid_cell contradict image_x/image_y.
        - First identify the target using visible_text and visual_anchor. Only then choose coordinates.
        - Return bbox around the visible clickable UI target, not around unrelated whitespace, neighboring controls, or the text label alone unless the text itself is the clickable target.
        - Put image_x/image_y on the safest clickable interior point for the target. For icons/cards/buttons, prefer the visual center of the clickable object. For text fields, prefer the center-left interior. For tabs/menu items/rows, prefer the center of the row/control.
        - If the target is described by a label, use the label to identify the correct object, then click the associated control/card/icon center. Do not click the label's first letter unless that is the only clickable area.
        - Keep bbox tight but complete enough that image_x/image_y is inside it.
        - Before returning, verify: image_x/image_y is inside bbox, image_x/image_y is inside grid_cell, and visual_anchor names the same target the user requested.
        - If multiple targets match, choose the one whose visible text/anchor best matches the request and mention the ambiguity in reason.
        - If the target is not visible, set confidence below 0.35 and explain why.
        """
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

    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.hasPrefix("```") {
            candidate = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if
            let start = trimmed.firstIndex(of: "{"),
            let end = trimmed.lastIndex(of: "}"),
            start <= end
        {
            candidate = String(trimmed[start...end])
        } else {
            candidate = trimmed
        }

        guard
            let data = candidate.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func resolveTargetPoint(
        from object: [String: Any],
        frame: ScreenFrame
    ) throws -> (
        point: CGPoint,
        bbox: [String: Double],
        centerFromBBox: CGPoint?,
        source: String
    ) {
        guard let rawImageX = doubleValue(object["image_x"]), let rawImageY = doubleValue(object["image_y"]) else {
            throw MouseTargetLocationError.missingCoordinates(String(describing: object))
        }

        let width = Double(max(1, frame.geometry.sentImageWidth))
        let height = Double(max(1, frame.geometry.sentImageHeight))
        let rawPoint = CGPoint(
            x: min(max(rawImageX, 0), width - 1),
            y: min(max(rawImageY, 0), height - 1)
        )
        let bbox = boundingBox(from: object)
        let centerFromBBox = center(from: bbox)
        let bboxContainsRaw = point(rawPoint, isInside: bbox, tolerance: 2)

        let point: CGPoint
        let source: String
        if !bbox.isEmpty, !bboxContainsRaw, let centerFromBBox {
            point = centerFromBBox
            source = "bbox_center_because_image_point_was_outside_bbox"
        } else {
            point = rawPoint
            source = rawPoint.x == rawImageX && rawPoint.y == rawImageY ? "vision_image_point" : "clamped_vision_image_point"
        }

        return (point, bbox, centerFromBBox, source)
    }

    private static func boundingBox(from object: [String: Any]) -> [String: Double] {
        guard let raw = object["bbox"] as? [String: Any] else { return [:] }
        let keys = ["x_min", "y_min", "x_max", "y_max"]
        var output: [String: Double] = [:]
        for key in keys {
            if let value = doubleValue(raw[key]) {
                output[key] = value
            }
        }
        guard keys.allSatisfy({ output[$0] != nil }) else { return [:] }
        guard
            let xMin = output["x_min"],
            let yMin = output["y_min"],
            let xMax = output["x_max"],
            let yMax = output["y_max"],
            xMax > xMin,
            yMax > yMin,
            (xMax - xMin) >= 3,
            (yMax - yMin) >= 3
        else {
            return [:]
        }
        return output
    }

    private static func center(from bbox: [String: Double]) -> CGPoint? {
        guard
            let xMin = bbox["x_min"],
            let yMin = bbox["y_min"],
            let xMax = bbox["x_max"],
            let yMax = bbox["y_max"]
        else {
            return nil
        }
        return CGPoint(x: (xMin + xMax) / 2, y: (yMin + yMax) / 2)
    }

    private static func point(_ point: CGPoint, isInside bbox: [String: Double], tolerance: Double) -> Bool {
        guard
            let xMin = bbox["x_min"],
            let yMin = bbox["y_min"],
            let xMax = bbox["x_max"],
            let yMax = bbox["y_max"]
        else {
            return false
        }
        return Double(point.x) >= xMin - tolerance
            && Double(point.x) <= xMax + tolerance
            && Double(point.y) >= yMin - tolerance
            && Double(point.y) <= yMax + tolerance
    }

    private static func mouseToolBusyRefusal(_ tool: String) -> [String: Any] {
        [
            "ok": false,
            "blocked": true,
            "tool": tool,
            "message": "A mouse-control tool is already running. Wait for its tool response before starting another mouse action."
        ]
    }

    private static func cancelledMouseToolResponse(_ tool: String) -> [String: Any] {
        [
            "ok": false,
            "cancelled": true,
            "tool": tool,
            "message": "Mouse tool was cancelled before moving or clicking."
        ]
    }

    private func beginMouseTool(_ tool: String) -> Bool {
        guard !mouseToolInFlight else { return false }
        mouseToolInFlight = true
        return true
    }

    private func endMouseTool() {
        mouseToolInFlight = false
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

    private func rawStringArg(_ key: String, in args: [String: Any]) -> String {
        if let value = args[key] as? String {
            return value
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

    private func boolArg(_ key: String, in args: [String: Any]) -> Bool? {
        if let value = args[key] as? Bool { return value }
        if let value = args[key] as? NSNumber { return value.boolValue }
        if let value = args[key] as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
