import AppKit
import Foundation

@MainActor
final class ComputerUseAgentService {
    private let gemini: GeminiClient
    private let computerControl: ComputerControlService
    private let logsURL: URL
    private let fileManager = FileManager.default
    private let dateFormatter = ISO8601DateFormatter()

    init(
        gemini: GeminiClient,
        computerControl: ComputerControlService,
        logsURL: URL
    ) {
        self.gemini = gemini
        self.computerControl = computerControl
        self.logsURL = logsURL
    }

    func run(
        task: String,
        mode: ComputerUseMode = .desktop,
        maxSteps requestedMaxSteps: Int = AppSettings.defaultComputerUseMaxSteps,
        controller: ComputerUseRunController? = nil,
        progress: ((ComputerUseProgressEvent) -> Void)? = nil
    ) async -> ComputerControlResult {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else {
            return ComputerControlResult(ok: false, message: "Computer Use task is required.")
        }

        let maxSteps = max(1, min(requestedMaxSteps, 25))
        let runID = UUID()
        let logURL: URL
        do {
            logURL = try makeLogURL(runID: runID)
        } catch {
            return ComputerControlResult(ok: false, message: "Could not create Computer Use log: \(error.localizedDescription)")
        }

        log(to: logURL, "run_start", [
            "run_id": runID.uuidString,
            "task": trimmedTask,
            "mode": mode.rawValue,
            "max_steps": maxSteps,
            "model": AppSettings.defaultComputerUseModel,
            "policy": "run_until_risky"
        ])

        var previousInteractionID = ""
        var stepSummaries: [[String: Any]] = []
        var input: [[String: Any]]

        do {
            let captureStarted = Date()
            let frame = try await captureFrame()
            let captureLatency = Date().timeIntervalSince(captureStarted)
            input = initialInput(task: trimmedTask, frame: frame, mode: mode, maxSteps: maxSteps)
            log(to: logURL, "initial_screenshot", [
                "geometry": frame.geometry.toolMetadata,
                "capture_latency_seconds": captureLatency
            ])
            emitProgress(
                progress,
                runID: runID,
                step: 0,
                phase: .looking,
                message: "Autopilot is awake. First screenshot captured.",
                latency: captureLatency
            )
        } catch {
            log(to: logURL, "run_failed", ["error": error.localizedDescription])
            return ComputerControlResult(ok: false, message: "Computer Use could not capture the screen: \(error.localizedDescription)", metadata: ["log_file": logURL.path])
        }

        for step in 1...maxSteps {
            if controller?.shouldStop == true {
                log(to: logURL, "run_cancelled_by_user", ["step": step])
                return ComputerControlResult(
                    ok: false,
                    message: "Computer Use stopped by user direction.",
                    metadata: ["status": ComputerUseRunStatus.cancelled.rawValue, "log_file": logURL.path, "steps": stepSummaries]
                )
            }

            guard !Task.isCancelled else {
                log(to: logURL, "run_cancelled", ["step": step])
                return ComputerControlResult(
                    ok: false,
                    message: "Computer Use run cancelled.",
                    metadata: ["status": ComputerUseRunStatus.cancelled.rawValue, "log_file": logURL.path, "steps": stepSummaries]
                )
            }

            do {
                if let directive = controller?.consumeDirective() {
                    let captureStarted = Date()
                    let frame = try await captureFrame()
                    let captureLatency = Date().timeIntervalSince(captureStarted)
                    if inputContainsFunctionResults(input) {
                        input = input.map { appendSteeringDirective(directive, to: $0) }
                    } else {
                        input = steeringInput(directive: directive, frame: frame, mode: mode, step: step)
                    }
                    log(to: logURL, "steering_instruction", [
                        "step": step,
                        "directive": directive,
                        "geometry": frame.geometry.toolMetadata,
                        "capture_latency_seconds": captureLatency
                    ])
                    emitProgress(
                        progress,
                        runID: runID,
                        step: step,
                        phase: .steering,
                        message: "Got your correction. Steering the next move now.",
                        latency: captureLatency
                    )
                }

                emitProgress(
                    progress,
                    runID: runID,
                    step: step,
                    phase: .looking,
                    message: "Looking at the screen for move \(step).",
                    latency: nil
                )
                let modelStarted = Date()
                let heartbeat = startHeartbeat(
                    progress: progress,
                    runID: runID,
                    step: step,
                    phase: .looking
                )
                defer { heartbeat?.cancel() }
                let interaction = try await gemini.runComputerUseInteraction(
                    input: input,
                    mode: mode,
                    previousInteractionID: previousInteractionID
                )
                let modelLatency = Date().timeIntervalSince(modelStarted)
                if !interaction.id.isEmpty {
                    previousInteractionID = interaction.id
                }
                log(to: logURL, "model_response", [
                    "step": step,
                    "interaction_id": interaction.id,
                    "model_latency_seconds": modelLatency,
                    "output_text": interaction.outputText,
                    "function_calls": interaction.functionCalls.map { callSummary($0) }
                ])

                if interaction.functionCalls.isEmpty {
                    let final = interaction.outputText.isEmpty ? "Computer Use finished without more actions." : interaction.outputText
                    log(to: logURL, "run_complete", ["final_message": final, "steps": stepSummaries.count])
                    emitProgress(
                        progress,
                        runID: runID,
                        step: step,
                        phase: .finished,
                        message: "Autopilot finished. \(shortMessage(final))",
                        latency: modelLatency
                    )
                    return ComputerControlResult(
                        ok: true,
                        message: final,
                        metadata: [
                            "status": ComputerUseRunStatus.completed.rawValue,
                            "log_file": logURL.path,
                            "steps": stepSummaries,
                            "interaction_id": previousInteractionID
                        ]
                    )
                }

                var functionResults: [[String: Any]] = []
                for call in interaction.functionCalls {
                    let safety = safetyDecision(for: call)
                    if safety.blocked {
                        let summary = stepRecord(step: step, call: call, result: safety.message, safety: "paused")
                        stepSummaries.append(summary)
                        log(to: logURL, "paused_for_safety", summary)
                        emitProgress(
                            progress,
                            runID: runID,
                            step: step,
                            phase: .finished,
                            message: "Paused before a risky action. I am not touching that without you.",
                            latency: nil
                        )
                        return ComputerControlResult(
                            ok: false,
                            message: safety.message,
                            metadata: [
                                "status": ComputerUseRunStatus.pausedForSafety.rawValue,
                                "log_file": logURL.path,
                                "steps": stepSummaries,
                                "blocked_action": callSummary(call)
                            ]
                        )
                    }

                    let actionPhase = progressPhase(for: call)
                    emitProgress(
                        progress,
                        runID: runID,
                        step: step,
                        phase: actionPhase,
                        message: progressStartMessage(for: call, phase: actionPhase),
                        latency: nil
                    )
                    let actionStarted = Date()
                    let execution = await execute(call)
                    let actionLatency = Date().timeIntervalSince(actionStarted)
                    let summary = stepRecord(step: step, call: call, result: execution.message, safety: "allowed")
                        .merging([
                            "execution": execution.toolResponse,
                            "action_latency_seconds": actionLatency
                        ]) { _, new in new }
                    stepSummaries.append(summary)
                    log(to: logURL, "action_executed", summary)
                    emitProgress(
                        progress,
                        runID: runID,
                        step: step,
                        phase: actionPhase,
                        message: progressFinishMessage(for: call, execution: execution),
                        latency: actionLatency
                    )

                    emitProgress(
                        progress,
                        runID: runID,
                        step: step,
                        phase: .checkingResult,
                        message: "Checking what changed on screen.",
                        latency: nil
                    )
                    let captureStarted = Date()
                    let frame = try await captureFrame()
                    let captureLatency = Date().timeIntervalSince(captureStarted)
                    log(to: logURL, "post_action_screenshot", [
                        "step": step,
                        "action": call.name,
                        "capture_latency_seconds": captureLatency,
                        "geometry": frame.geometry.toolMetadata
                    ])
                    emitProgress(
                        progress,
                        runID: runID,
                        step: step,
                        phase: .checkingResult,
                        message: "Screen refreshed. Deciding the next move.",
                        latency: captureLatency
                    )
                    functionResults.append(functionResult(for: call, execution: execution, frame: frame))
                }
                input = functionResults
            } catch {
                log(to: logURL, "run_failed", ["step": step, "error": error.localizedDescription])
                return ComputerControlResult(
                    ok: false,
                    message: "Computer Use failed: \(error.localizedDescription)",
                    metadata: [
                        "status": ComputerUseRunStatus.failed.rawValue,
                        "log_file": logURL.path,
                        "steps": stepSummaries
                    ]
                )
            }
        }

        log(to: logURL, "max_steps_reached", ["max_steps": maxSteps, "steps": stepSummaries.count])
        return ComputerControlResult(
            ok: false,
            message: "Computer Use reached the max step limit before finishing.",
            metadata: [
                "status": ComputerUseRunStatus.maxStepsReached.rawValue,
                "log_file": logURL.path,
                "steps": stepSummaries
            ]
        )
    }

    private func captureFrame() async throws -> ScreenFrame {
        let frame = try await ScreenCaptureService.captureMainDisplayPNGFrame(maxDimension: 1280)
        computerControl.updateLatestScreenFrameGeometry(frame.geometry)
        return frame
    }

    private func initialInput(task: String, frame: ScreenFrame, mode: ComputerUseMode, maxSteps: Int) -> [[String: Any]] {
        return [
            [
                "type": "text",
                "text": """
                You are April AI's Computer Use autopilot.
                Complete the user's task with reversible UI actions only.
                Stop before sending, buying, deleting, submitting final forms, accepting legal terms, changing security/privacy settings, or typing secrets.
                If the next action is risky, explain what needs user confirmation instead of doing it.
                If the user asks to run, execute, apply, open, search, or otherwise complete a visible workflow, infer the correct next UI action from the screenshot and task context.
                Prefer visible controls and standard app shortcuts over repeated exploratory clicks.
                Do not re-click controls that are already active just to "ensure" they opened; verify from the fresh screenshot and move on.
                Mode: \(mode.rawValue)
                Max steps: \(maxSteps)

                User task:
                \(task)
                """
            ],
            imagePart(frame.data)
        ]
    }

    private func inputContainsFunctionResults(_ input: [[String: Any]]) -> Bool {
        input.contains { ($0["type"] as? String) == "function_result" }
    }

    private func appendSteeringDirective(_ directive: String, to functionResult: [String: Any]) -> [String: Any] {
        var updated = functionResult
        guard var result = updated["result"] as? [[String: Any]] else { return functionResult }
        for index in result.indices {
            guard
                (result[index]["type"] as? String) == "text",
                let text = result[index]["text"] as? String
            else {
                continue
            }
            var payload = jsonObject(from: text) ?? ["previous_result_text": text]
            payload["user_steering_instruction"] = directive
            payload["steering_instruction_note"] = "Apply this user correction on the next step instead of blindly continuing the previous plan."
            result[index]["text"] = jsonString(payload)
            updated["result"] = result
            return updated
        }
        return functionResult
    }

    private func steeringInput(directive: String, frame: ScreenFrame, mode: ComputerUseMode, step: Int) -> [[String: Any]] {
        [
            [
                "type": "text",
                "text": """
                User steering instruction received while autopilot is already running.
                Immediately update the plan. Do not continue the previous goal if this instruction changes it.
                If the instruction asks to stop/pause/cancel, return a final answer and no function calls.
                Stay within reversible UI actions and stop before risky final actions.
                Mode: \(mode.rawValue)
                Current step: \(step)

                New user instruction:
                \(directive)
                """
            ],
            imagePart(frame.data)
        ]
    }

    private func execute(_ call: ComputerUseFunctionCall) async -> ComputerControlResult {
        let name = normalized(call.name)
        switch name {
        case "click", "click_at":
            return computerControl.clickMouse(
                x: normalizedCoordinate("x", in: call.arguments),
                y: normalizedCoordinate("y", in: call.arguments),
                coordinateSpace: "",
                imageX: nil,
                imageY: nil,
                imageWidth: nil,
                imageHeight: nil,
                button: "left",
                count: 1
            )
        case "double_click", "double_click_at":
            return computerControl.clickMouse(
                x: normalizedCoordinate("x", in: call.arguments),
                y: normalizedCoordinate("y", in: call.arguments),
                coordinateSpace: "",
                imageX: nil,
                imageY: nil,
                imageWidth: nil,
                imageHeight: nil,
                button: "left",
                count: 2
            )
        case "right_click", "right_click_at":
            return computerControl.clickMouse(
                x: normalizedCoordinate("x", in: call.arguments),
                y: normalizedCoordinate("y", in: call.arguments),
                coordinateSpace: "",
                imageX: nil,
                imageY: nil,
                imageWidth: nil,
                imageHeight: nil,
                button: "right",
                count: 1
            )
        case "move", "move_to":
            return computerControl.moveMouse(
                x: normalizedCoordinate("x", in: call.arguments),
                y: normalizedCoordinate("y", in: call.arguments),
                coordinateSpace: "",
                imageX: nil,
                imageY: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        case "scroll", "scroll_at":
            return executeScroll(call)
        case "take_screenshot", "screenshot":
            return ComputerControlResult(
                ok: true,
                message: "Screenshot request acknowledged. April captures the next screen state automatically after every Computer Use action.",
                metadata: ["action": name]
            )
        case "type", "type_text", "type_text_at":
            if let x = normalizedCoordinate("x", in: call.arguments), let y = normalizedCoordinate("y", in: call.arguments) {
                let click = computerControl.clickMouse(
                    x: x,
                    y: y,
                    coordinateSpace: "",
                    imageX: nil,
                    imageY: nil,
                    imageWidth: nil,
                    imageHeight: nil,
                    button: "left",
                    count: 1
                )
                guard click.ok else { return click }
            }
            let text = string("text", in: call.arguments)
            let typed = await computerControl.typeText(text)
            if bool("press_enter", in: call.arguments) == true {
                let shortcut = computerControl.keyboardShortcut("return")
                return typed.mergingMetadata(["press_enter": shortcut.toolResponse])
            }
            return typed
        case "wait":
            let seconds = max(0.2, min(double("seconds", in: call.arguments) ?? 1.0, 5.0))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ComputerControlResult(ok: true, message: "Waited \(String(format: "%.1f", seconds)) seconds.", metadata: ["seconds": seconds])
        case "navigate":
            let urlString = string("url", in: call.arguments)
            guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
                return ComputerControlResult(ok: false, message: "Could not navigate to URL.", metadata: ["url": urlString])
            }
            return ComputerControlResult(ok: true, message: "URL opened.", metadata: ["url": urlString])
        case "go_back", "back":
            return computerControl.keyboardShortcut("", key: "left", modifiers: ["cmd"])
        case "go_forward", "forward":
            return computerControl.keyboardShortcut("", key: "right", modifiers: ["cmd"])
        default:
            return ComputerControlResult(ok: false, message: "Unsupported Computer Use action: \(call.name).", metadata: callSummary(call))
        }
    }

    private func emitProgress(
        _ progress: ((ComputerUseProgressEvent) -> Void)?,
        runID: UUID,
        step: Int,
        phase: ComputerUseProgressPhase,
        message: String,
        latency: Double?
    ) {
        progress?(ComputerUseProgressEvent(
            runID: runID,
            step: step,
            phase: phase,
            message: message,
            latency: latency
        ))
    }

    private func startHeartbeat(
        progress: ((ComputerUseProgressEvent) -> Void)?,
        runID: UUID,
        step: Int,
        phase: ComputerUseProgressPhase
    ) -> Task<Void, Never>? {
        guard progress != nil else { return nil }
        return Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                while !Task.isCancelled {
                    emitProgress(
                        progress,
                        runID: runID,
                        step: step,
                        phase: phase,
                        message: "Still working. Gemini is thinking through the next UI move.",
                        latency: nil
                    )
                    try await Task.sleep(nanoseconds: 7_000_000_000)
                }
            } catch {
                return
            }
        }
    }

    private func progressPhase(for call: ComputerUseFunctionCall) -> ComputerUseProgressPhase {
        switch normalized(call.name) {
        case "click", "click_at", "double_click", "double_click_at", "right_click", "right_click_at", "move", "move_to":
            return .clicking
        case "type", "type_text", "type_text_at":
            return .typing
        case "scroll", "scroll_at", "wait":
            return .waiting
        default:
            return .checkingResult
        }
    }

    private func progressStartMessage(for call: ComputerUseFunctionCall, phase: ComputerUseProgressPhase) -> String {
        let intent = shortMessage(call.intent)
        switch phase {
        case .clicking:
            return intent.isEmpty ? "Moving the pointer for the next click." : "Clicking: \(intent)"
        case .typing:
            return intent.isEmpty ? "Typing into the focused field." : "Typing: \(intent)"
        case .waiting:
            return normalized(call.name) == "wait" ? "Waiting for the page to react." : "Scrolling the visible page."
        case .checkingResult:
            return "Handling \(call.name)."
        case .looking:
            return "Looking at the screen."
        case .steering:
            return "Applying your steering instruction."
        case .finished:
            return "Autopilot finished."
        }
    }

    private func progressFinishMessage(for call: ComputerUseFunctionCall, execution: ComputerControlResult) -> String {
        let action = normalized(call.name).replacingOccurrences(of: "_", with: " ")
        let outcome = execution.ok ? "Done" : "That failed"
        return "\(outcome): \(action). \(shortMessage(execution.message))"
    }

    private func shortMessage(_ text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 120 else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 117)
        return String(trimmed[..<index]) + "..."
    }

    private func executeScroll(_ call: ComputerUseFunctionCall) -> ComputerControlResult {
        var preMove: ComputerControlResult?
        if let x = normalizedCoordinate("x", in: call.arguments), let y = normalizedCoordinate("y", in: call.arguments) {
            preMove = computerControl.moveMouse(
                x: x,
                y: y,
                coordinateSpace: "",
                imageX: nil,
                imageY: nil,
                imageWidth: nil,
                imageHeight: nil
            )
            if preMove?.ok == false {
                return preMove ?? ComputerControlResult(ok: false, message: "Could not move cursor before scroll.")
            }
        }

        let deltaX = double("delta_x", in: call.arguments)
            ?? double("dx", in: call.arguments)
            ?? directionalScrollDelta(axis: "x", in: call.arguments)
            ?? 0
        let deltaY = double("delta_y", in: call.arguments)
            ?? double("dy", in: call.arguments)
            ?? directionalScrollDelta(axis: "y", in: call.arguments)
            ?? double("amount", in: call.arguments)
            ?? 0

        let scrolled = computerControl.scrollMouse(deltaX: deltaX, deltaY: deltaY)
        var metadata = scrolled.metadata
        metadata["computer_use_scroll_args"] = summarize(call.arguments)
        if let preMove {
            metadata["pre_scroll_move"] = preMove.toolResponse
        }
        return ComputerControlResult(ok: scrolled.ok, message: scrolled.message, metadata: metadata)
    }

    private func directionalScrollDelta(axis: String, in args: [String: Any]) -> Double? {
        let magnitude = double("magnitude_in_pixels", in: args)
            ?? double("magnitude", in: args)
            ?? double("pixels", in: args)
            ?? (double("magnitude_in_wheel_clicks", in: args).map { $0 * 80 })
            ?? (double("wheel_clicks", in: args).map { $0 * 80 })
        guard let magnitude, magnitude != 0 else { return nil }

        let direction = string("direction", in: args).lowercased()
        switch (axis, direction) {
        case ("y", "down"):
            return -abs(magnitude)
        case ("y", "up"):
            return abs(magnitude)
        case ("x", "right"):
            return -abs(magnitude)
        case ("x", "left"):
            return abs(magnitude)
        default:
            return nil
        }
    }

    private func functionResult(for call: ComputerUseFunctionCall, execution: ComputerControlResult, frame: ScreenFrame) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": execution.ok,
            "message": execution.message,
            "metadata": execution.metadata,
            "screen_geometry": frame.geometry.toolMetadata
        ]
        if call.arguments["safety_decision"] != nil {
            payload["safety_acknowledgement"] = true
        }

        return [
            "type": "function_result",
            "name": call.name,
            "call_id": call.id,
            "result": [
                [
                    "type": "text",
                    "text": jsonString(payload)
                ],
                imagePart(frame.data)
            ]
        ]
    }

    private func imagePart(_ data: Data) -> [String: Any] {
        [
            "type": "image",
            "data": data.base64EncodedString(),
            "mime_type": "image/png"
        ]
    }

    private func safetyDecision(for call: ComputerUseFunctionCall) -> (blocked: Bool, message: String) {
        let combined = [
            call.name,
            call.intent,
            string("text", in: call.arguments),
            string("url", in: call.arguments)
        ].joined(separator: " ").lowercased()

        let riskyTerms = [
            "send", "submit", "buy", "purchase", "checkout", "pay", "delete", "remove",
            "confirm", "agree", "accept terms", "privacy", "security", "password",
            "passcode", "api key", "secret", "token", "credit card", "cvv"
        ]
        let riskyAction = riskyTerms.contains { combined.contains($0) }
        if riskyAction {
            return (
                true,
                "Computer Use paused before a risky action: \(call.intent.isEmpty ? call.name : call.intent). Confirm manually or give a safer next instruction."
            )
        }
        return (false, "allowed")
    }

    private func makeLogURL(runID: UUID) throws -> URL {
        let folder = logsURL.appending(path: "computer-use")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return folder.appending(path: "\(formatter.string(from: Date()))-\(runID.uuidString.prefix(8))-computer-use.jsonl")
    }

    private func log(to url: URL, _ event: String, _ payload: [String: Any] = [:]) {
        var object = sanitize(payload) as? [String: Any] ?? [:]
        object["event"] = event
        object["timestamp"] = dateFormatter.string(from: Date())
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8),
            let lineData = (line + "\n").data(using: .utf8)
        else { return }

        if !fileManager.fileExists(atPath: url.path) {
            try? lineData.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: lineData)
    }

    private func stepRecord(step: Int, call: ComputerUseFunctionCall, result: String, safety: String) -> [String: Any] {
        [
            "step": step,
            "action": call.name,
            "intent": call.intent,
            "arguments": summarize(call.arguments),
            "result": result,
            "safety": safety
        ]
    }

    private func callSummary(_ call: ComputerUseFunctionCall) -> [String: Any] {
        [
            "id": call.id,
            "name": call.name,
            "intent": call.intent,
            "arguments": summarize(call.arguments)
        ]
    }

    private func normalizedCoordinate(_ key: String, in args: [String: Any]) -> Double? {
        guard let value = double(key, in: args) else { return nil }
        guard value >= 0, value <= 1000 else { return nil }
        return value / 1000.0
    }

    private func double(_ key: String, in args: [String: Any]) -> Double? {
        if let value = args[key] as? Double { return value }
        if let value = args[key] as? NSNumber { return value.doubleValue }
        if let value = args[key] as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func string(_ key: String, in args: [String: Any]) -> String {
        if let value = args[key] as? String { return value }
        if let value = args[key] as? NSNumber { return value.stringValue }
        return ""
    }

    private func bool(_ key: String, in args: [String: Any]) -> Bool? {
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

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func summarize(_ value: Any) -> Any {
        sanitize(value)
    }

    private func sanitize(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                if isSecretKey(item.key) {
                    result[item.key] = "[REDACTED]"
                } else {
                    result[item.key] = sanitize(item.value)
                }
            }
        }
        if let array = value as? [Any] {
            return array.map(sanitize)
        }
        if let string = value as? String {
            return string.count > 2_000 ? String(string.prefix(2_000)) + "...[truncated]" : string
        }
        if let date = value as? Date {
            return dateFormatter.string(from: date)
        }
        if let uuid = value as? UUID {
            return uuid.uuidString
        }
        return value
    }

    private func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("api_key")
            || lower.contains("apikey")
            || lower.contains("password")
            || lower.contains("secret")
            || lower.contains("token")
            || lower.contains("credential")
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let sanitized = sanitize(object)
        guard
            JSONSerialization.isValidJSONObject(sanitized),
            let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private func jsonObject(from string: String) -> [String: Any]? {
        guard
            let data = string.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}
