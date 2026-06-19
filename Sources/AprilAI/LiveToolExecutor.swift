import Foundation

@MainActor
final class LiveToolExecutor {
    private let context: ContextLibrary
    private let computerControl: ComputerControlService
    private let accessibilityControl: AccessibilityControlService
    private let gemini: () -> GeminiClient
    private let settings: () -> AppSettings
    private let onMemoryChanged: () async -> Void

    init(
        context: ContextLibrary,
        computerControl: ComputerControlService,
        accessibilityControl: AccessibilityControlService,
        gemini: @escaping () -> GeminiClient,
        settings: @escaping () -> AppSettings,
        onMemoryChanged: @escaping () async -> Void
    ) {
        self.context = context
        self.computerControl = computerControl
        self.accessibilityControl = accessibilityControl
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
            "name": "mouse_calibration",
            "description": "Inspect, reset, or sample the mouse calibration state used for coordinate correction. Use status before mouse fallback when targeting looks off.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "description": "status, reset, or sample_center."]
                ]
            ]
        ],
        [
            "name": "move_mouse",
            "description": "Move the mouse cursor. Use normalized x/y only for 0.0...1.0, or coordinate_space=image_pixels with image_x/image_y from the latest Live frame. Requires Accessibility permission and executes without a per-action confirmation.",
            "parameters": [
                "type": "object",
                "properties": [
                    "coordinate_space": ["type": "string", "description": "Use normalized for x/y 0.0...1.0, or image_pixels for image_x/image_y from the latest Live screen frame."],
                    "x": ["type": "number", "description": "Horizontal normalized coordinate from 0.0 left to 1.0 right. Only use for normalized coordinates."],
                    "y": ["type": "number", "description": "Vertical normalized coordinate from 0.0 top to 1.0 bottom. Only use for normalized coordinates."],
                    "image_x": ["type": "number", "description": "Horizontal pixel coordinate in the latest Live screen image."],
                    "image_y": ["type": "number", "description": "Vertical pixel coordinate in the latest Live screen image."],
                    "image_width": ["type": "number", "description": "Optional width of the image coordinate space if known."],
                    "image_height": ["type": "number", "description": "Optional height of the image coordinate space if known."]
                ]
            ]
        ],
        [
            "name": "click_mouse",
            "description": "Click, double-click, or right-click the mouse. Prefer AX tools first. Use normalized x/y only for 0.0...1.0, or coordinate_space=image_pixels with image_x/image_y from the latest Live frame. Requires Accessibility permission and executes without a per-click confirmation.",
            "parameters": [
                "type": "object",
                "properties": [
                    "coordinate_space": ["type": "string", "description": "Use normalized for x/y 0.0...1.0, image_pixels for image_x/image_y from the latest Live screen frame, or omit coordinates to click current cursor location."],
                    "x": ["type": "number", "description": "Optional horizontal normalized coordinate from 0.0 to 1.0."],
                    "y": ["type": "number", "description": "Optional vertical normalized coordinate from 0.0 to 1.0."],
                    "image_x": ["type": "number", "description": "Optional horizontal pixel coordinate in the latest Live screen image."],
                    "image_y": ["type": "number", "description": "Optional vertical pixel coordinate in the latest Live screen image."],
                    "image_width": ["type": "number", "description": "Optional width of the image coordinate space if known."],
                    "image_height": ["type": "number", "description": "Optional height of the image coordinate space if known."],
                    "button": ["type": "string", "description": "left or right."],
                    "count": ["type": "integer", "description": "1 for click, 2 for double-click."]
                ]
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
            let response: [String: Any]
            do {
                switch call.name {
                case "search_memory":
                    response = try await searchMemory(args: call.args)
                case "save_memory":
                    response = try await saveMemory(args: call.args)
                case "google_search":
                    response = try await googleSearch(args: call.args)
                case "teacher_plan_control":
                    response = try await teacherPlanControl(args: call.args)
                case "screen_geometry":
                    response = computerControl.screenGeometry().toolResponse
                case "mouse_calibration":
                    response = computerControl.mouseCalibration(action: stringArg("action", in: call.args)).toolResponse
                case "move_mouse":
                    response = computerControl.moveMouse(
                        x: doubleArg("x", in: call.args),
                        y: doubleArg("y", in: call.args),
                        coordinateSpace: stringArg("coordinate_space", in: call.args),
                        imageX: doubleArg("image_x", in: call.args),
                        imageY: doubleArg("image_y", in: call.args),
                        imageWidth: doubleArg("image_width", in: call.args),
                        imageHeight: doubleArg("image_height", in: call.args)
                    ).toolResponse
                case "click_mouse":
                    response = computerControl.clickMouse(
                        x: doubleArg("x", in: call.args),
                        y: doubleArg("y", in: call.args),
                        coordinateSpace: stringArg("coordinate_space", in: call.args),
                        imageX: doubleArg("image_x", in: call.args),
                        imageY: doubleArg("image_y", in: call.args),
                        imageWidth: doubleArg("image_width", in: call.args),
                        imageHeight: doubleArg("image_height", in: call.args),
                        button: stringArg("button", in: call.args).isEmpty ? "left" : stringArg("button", in: call.args),
                        count: intArg("count", in: call.args) ?? 1
                    ).toolResponse
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

    private func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
