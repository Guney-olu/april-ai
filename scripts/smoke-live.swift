#!/usr/bin/env swift
import Foundation

func log(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

final class Delegate: NSObject, URLSessionWebSocketDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var lastCloseMessage = "no close message"

    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        continuation?.resume()
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
        lastCloseMessage = "\(closeCode) \(reasonText)"
        if let continuation {
            continuation.resume(throwing: NSError(
                domain: "LiveSmoke",
                code: Int(closeCode.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Socket closed before open: \(lastCloseMessage)"]
            ))
            self.continuation = nil
        }
    }
}

func keyFromKeychain(service: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = [
        "find-generic-password",
        "-s", service,
        "-a", "default",
        "-w"
    ]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let key = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard process.terminationStatus == 0 else {
        return ""
    }
    return key
}

func keyFromEnvironmentOrKeychain() throws -> String {
    if let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty {
        return key
    }
    if let key = ProcessInfo.processInfo.environment["GOOGLE_API_KEY"], !key.isEmpty {
        return key
    }

    let keychainServices = [
        "AprilAI.GeminiAPIKey",
        "PolymathAssistant.GeminiAPIKey"
    ]
    for service in keychainServices {
        let key = try keyFromKeychain(service: service)
        if !key.isEmpty {
            return key
        }
    }

    throw NSError(
        domain: "LiveSmoke",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No Gemini key found in GEMINI_API_KEY, GOOGLE_API_KEY, or April AI Keychain item."]
    )
}

func receiveJSON(from socket: URLSessionWebSocketTask, delegate: Delegate, timeoutSeconds: Double = 12) async throws -> [String: Any] {
    try await withThrowingTaskGroup(of: [String: Any].self) { group in
        group.addTask {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                throw NSError(
                    domain: "LiveSmoke",
                    code: 91,
                    userInfo: [NSLocalizedDescriptionKey: "Receive failed: \(error.localizedDescription). Close reason: \(delegate.lastCloseMessage)"]
                )
            }
            let text: String
            switch message {
            case .string(let value):
                text = value
            case .data(let data):
                text = String(data: data, encoding: .utf8) ?? ""
            @unknown default:
                text = ""
            }

            guard
                let data = text.data(using: .utf8),
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw NSError(domain: "LiveSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Non-JSON response: \(text.prefix(400))"])
            }
            return json
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            throw NSError(domain: "LiveSmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Live API response."])
        }

        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

func sendJSON(_ object: [String: Any], to socket: URLSessionWebSocketTask, delegate: Delegate, label: String) async throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    do {
        try await socket.send(.string(String(data: data, encoding: .utf8)!))
    } catch {
        throw NSError(
            domain: "LiveSmoke",
            code: 90,
            userInfo: [NSLocalizedDescriptionKey: "Send failed during \(label): \(error.localizedDescription). Close reason: \(delegate.lastCloseMessage)"]
        )
    }
}

func receiveToolCall(from socket: URLSessionWebSocketTask, delegate: Delegate, timeoutSeconds: Double = 12) async throws -> [[String: Any]] {
    for _ in 0..<10 {
        let response = try await receiveJSON(from: socket, delegate: delegate, timeoutSeconds: timeoutSeconds)
        if let error = response["error"] {
            throw NSError(domain: "LiveSmoke", code: 20, userInfo: [NSLocalizedDescriptionKey: "Live API tool-call error: \(error)"])
        }
        if
            let toolCall = response["toolCall"] as? [String: Any],
            let functionCalls = toolCall["functionCalls"] as? [[String: Any]],
            !functionCalls.isEmpty
        {
            return functionCalls
        }
    }

    throw NSError(domain: "LiveSmoke", code: 21, userInfo: [NSLocalizedDescriptionKey: "Did not receive toolCall."])
}

func runGroundedSearchSmoke(apiKey: String) async throws {
    let model = ProcessInfo.processInfo.environment["SEARCH_MODEL"] ?? "gemini-3.5-flash"
    let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    let payload: [String: Any] = [
        "contents": [
            [
                "role": "user",
                "parts": [
                    [
                        "text": "Answer briefly: what is Gemini Live API tool use? Include current source grounding."
                    ]
                ]
            ]
        ],
        "tools": [
            ["google_search": [:]]
        ]
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "no response body"
        throw NSError(domain: "LiveSmoke", code: 25, userInfo: [NSLocalizedDescriptionKey: "Grounded Search failed: \(body.prefix(500))"])
    }

    guard
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let candidates = json["candidates"] as? [[String: Any]],
        let metadata = candidates.first?["groundingMetadata"] as? [String: Any],
        let chunks = metadata["groundingChunks"] as? [[String: Any]],
        !chunks.isEmpty
    else {
        throw NSError(domain: "LiveSmoke", code: 26, userInfo: [NSLocalizedDescriptionKey: "Grounded Search returned no grounding chunks."])
    }
}

let key = try keyFromEnvironmentOrKeychain()
let model = ProcessInfo.processInfo.environment["LIVE_MODEL"] ?? "gemini-3.1-flash-live-preview"
let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(key)")!
let delegate = Delegate()
let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
let socket = session.webSocketTask(with: url)
socket.resume()
try await delegate.waitForOpen()
log("phase: opened")

let toolDeclarations: [[String: Any]] = [
    [
        "name": "search_memory",
        "description": "Search approved local memories.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": ["type": "string"],
                "limit": ["type": "integer"],
                "types": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["query"]
        ]
    ],
    [
        "name": "save_memory",
        "description": "Save a safe durable memory.",
        "parameters": [
            "type": "object",
            "properties": [
                "type": ["type": "string"],
                "content": ["type": "string"],
                "summary": ["type": "string"],
                "confidence": ["type": "number"],
                "importance": ["type": "number"],
                "evidence": ["type": "string"],
                "sensitivity": ["type": "string"]
            ],
            "required": ["content"]
        ]
    ],
    [
        "name": "google_search",
        "description": "Run a custom grounded Google Search.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": ["type": "string"],
                "context": ["type": "string"]
            ],
            "required": ["query"]
        ]
    ],
    [
        "name": "move_mouse",
        "description": "Move the mouse using normalized coordinates or latest Live image pixels.",
        "parameters": [
            "type": "object",
            "properties": [
                "coordinate_space": ["type": "string"],
                "x": ["type": "number"],
                "y": ["type": "number"],
                "image_x": ["type": "number"],
                "image_y": ["type": "number"],
                "image_width": ["type": "number"],
                "image_height": ["type": "number"]
            ]
        ]
    ],
    [
        "name": "click_mouse",
        "description": "Click the mouse after Accessibility permission.",
        "parameters": [
            "type": "object",
            "properties": [
                "coordinate_space": ["type": "string"],
                "x": ["type": "number"],
                "y": ["type": "number"],
                "image_x": ["type": "number"],
                "image_y": ["type": "number"],
                "image_width": ["type": "number"],
                "image_height": ["type": "number"],
                "button": ["type": "string"],
                "count": ["type": "integer"]
            ]
        ]
    ],
    [
        "name": "scroll_mouse",
        "description": "Scroll the mouse after Accessibility permission.",
        "parameters": [
            "type": "object",
            "properties": [
                "delta_x": ["type": "number"],
                "delta_y": ["type": "number"]
            ],
            "required": ["delta_y"]
        ]
    ],
    [
        "name": "type_text",
        "description": "Type text after Accessibility permission.",
        "parameters": [
            "type": "object",
            "properties": [
                "text": ["type": "string"]
            ],
            "required": ["text"]
        ]
    ],
    [
        "name": "press_key",
        "description": "Press an allowed key after Accessibility permission.",
        "parameters": [
            "type": "object",
            "properties": [
                "key": ["type": "string"],
                "modifiers": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["key"]
        ]
    ],
    [
        "name": "open_application",
        "description": "Open an installed application.",
        "parameters": [
            "type": "object",
            "properties": [
                "app": ["type": "string"]
            ],
            "required": ["app"]
        ]
    ],
    [
        "name": "ax_snapshot",
        "description": "Snapshot native macOS Accessibility elements.",
        "parameters": [
            "type": "object",
            "properties": [
                "app": ["type": "string"]
            ]
        ]
    ],
    [
        "name": "ax_press",
        "description": "Press an Accessibility element by id.",
        "parameters": [
            "type": "object",
            "properties": [
                "element_id": ["type": "string"]
            ],
            "required": ["element_id"]
        ]
    ],
    [
        "name": "ax_set_value",
        "description": "Set an Accessibility element value by id.",
        "parameters": [
            "type": "object",
            "properties": [
                "element_id": ["type": "string"],
                "value": ["type": "string"]
            ],
            "required": ["element_id", "value"]
        ]
    ],
    [
        "name": "ax_focus",
        "description": "Focus an Accessibility element by id.",
        "parameters": [
            "type": "object",
            "properties": [
                "element_id": ["type": "string"]
            ],
            "required": ["element_id"]
        ]
    ]
]

let setup: [String: Any] = [
    "setup": [
        "model": "models/\(model)",
        "generationConfig": [
            "responseModalities": ["AUDIO"],
            "mediaResolution": "MEDIA_RESOLUTION_LOW",
            "speechConfig": [
                "voiceConfig": [
                    "prebuiltVoiceConfig": [
                        "voiceName": "Aoede"
                    ]
                ]
            ]
        ],
        "systemInstruction": [
            "parts": [["text": "You are a concise smoke-test assistant. When the user asks for tool smoke testing, call the requested tools before answering."]]
        ],
        "tools": [
            [
                "functionDeclarations": toolDeclarations
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
        "sessionResumption": [:],
        "inputAudioTranscription": [:],
        "outputAudioTranscription": [:]
    ]
]

try await sendJSON(setup, to: socket, delegate: delegate, label: "setup")
log("phase: setup sent")

var sawSetupComplete = false
for _ in 0..<4 {
    let response = try await receiveJSON(from: socket, delegate: delegate)
    if response["setupComplete"] != nil {
        sawSetupComplete = true
        break
    }
    if let error = response["error"] {
        throw NSError(domain: "LiveSmoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Live API setup error: \(error)"])
    }
}

guard sawSetupComplete else {
    throw NSError(domain: "LiveSmoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "Did not receive setupComplete."])
}
log("phase: setup complete")

try await sendJSON([
    "clientContent": [
        "turns": [
            [
                "role": "user",
                "parts": [
                    [
                        "text": "Approved long-term memory context for future live turns. Use this as background only; do not respond to this packet directly.\n\n- preference, confidence 0.90, source smoke test: User is testing live memory context injection."
                    ]
                ]
            ]
        ],
        "turnComplete": false
    ]
], to: socket, delegate: delegate, label: "memory clientContent")
log("phase: memory context sent")

try await sendJSON([
    "clientContent": [
        "turns": [
            [
                "role": "user",
                "parts": [
                    [
                        "text": "Tool smoke test: call these three tools now and do not answer until tool results arrive: search_memory with query 'live memory tool smoke', save_memory with content 'User is smoke testing Live custom tools' and sensitivity 'low', and google_search with query 'Gemini Live API tools'."
                    ]
                ]
            ]
        ],
        "turnComplete": true
    ]
], to: socket, delegate: delegate, label: "tool prompt")
log("phase: tool prompt sent")

let functionCalls = try await receiveToolCall(from: socket, delegate: delegate)
let toolNames = Set(functionCalls.compactMap { $0["name"] as? String })
let requiredToolNames: Set<String> = ["search_memory", "save_memory", "google_search"]
guard requiredToolNames.isSubset(of: toolNames) else {
    throw NSError(
        domain: "LiveSmoke",
        code: 22,
        userInfo: [NSLocalizedDescriptionKey: "Tool call missing expected tools. Saw \(Array(toolNames).sorted())."]
    )
}
log("phase: tool call received")

let functionResponses = functionCalls.compactMap { call -> [String: Any]? in
    guard
        let id = call["id"] as? String,
        let name = call["name"] as? String
    else {
        return nil
    }

    let response: [String: Any]
    switch name {
    case "search_memory":
        response = [
            "ok": true,
            "matches": [
                [
                    "id": "smoke-memory",
                    "type": "preference",
                    "content": "User is testing Live custom tools.",
                    "source": "smoke test",
                    "confidence": 1.0,
                    "importance": 0.5,
                    "score": 0.99
                ]
            ]
        ]
    case "save_memory":
        response = [
            "ok": true,
            "saved": true,
            "embedded": false
        ]
    case "google_search":
        response = [
            "ok": true,
            "answer": "Gemini Live supports custom function calling.",
            "queries": ["Gemini Live API tools"],
            "sources": [
                [
                    "title": "Gemini Live API tools",
                    "uri": "https://ai.google.dev/gemini-api/docs/live-api/tools"
                ]
            ]
        ]
    default:
        response = ["ok": false, "error": "Unexpected tool \(name)"]
    }

    return [
        "id": id,
        "name": name,
        "response": response
    ]
}

try await sendJSON([
    "toolResponse": [
        "functionResponses": functionResponses
    ]
], to: socket, delegate: delegate, label: "toolResponse")
log("phase: tool response sent")

var sawToolServerContent = false
for _ in 0..<8 {
    let response = try await receiveJSON(from: socket, delegate: delegate)
    if response["serverContent"] != nil {
        sawToolServerContent = true
        break
    }
    if let error = response["error"] {
        throw NSError(domain: "LiveSmoke", code: 23, userInfo: [NSLocalizedDescriptionKey: "Live API tool response error: \(error)"])
    }
}
guard sawToolServerContent else {
    throw NSError(domain: "LiveSmoke", code: 24, userInfo: [NSLocalizedDescriptionKey: "Did not receive serverContent after toolResponse."])
}
log("phase: tool response accepted")

let silentPCM16k = Data(repeating: 0, count: 16_000)
try await sendJSON([
    "realtimeInput": [
        "audio": [
            "data": silentPCM16k.base64EncodedString(),
            "mimeType": "audio/pcm;rate=16000"
        ]
    ]
], to: socket, delegate: delegate, label: "audio")
try await sendJSON(["realtimeInput": ["audioStreamEnd": true]], to: socket, delegate: delegate, label: "audioStreamEnd")
log("phase: audio sent")

do {
    let response = try await receiveJSON(from: socket, delegate: delegate, timeoutSeconds: 3)
    if let error = response["error"] {
        throw NSError(domain: "LiveSmoke", code: 6, userInfo: [NSLocalizedDescriptionKey: "Live API audio-shape error: \(error)"])
    }
} catch {
    let nsError = error as NSError
    if !(nsError.domain == "LiveSmoke" && nsError.code == 3) {
        throw error
    }
}
log("phase: audio accepted")

let text: [String: Any] = ["realtimeInput": ["text": "Say only: live smoke test passed."]]
try await sendJSON(text, to: socket, delegate: delegate, label: "text")
log("phase: text sent")

var sawServerContent = false
var sawTurnComplete = false
for _ in 0..<12 {
    let response = try await receiveJSON(from: socket, delegate: delegate)
    if response["serverContent"] != nil {
        sawServerContent = true
        if let serverContent = response["serverContent"] as? [String: Any],
           let turnComplete = serverContent["turnComplete"] as? Bool,
           turnComplete
        {
            sawTurnComplete = true
            break
        }
    }
    if let error = response["error"] {
        throw NSError(domain: "LiveSmoke", code: 6, userInfo: [NSLocalizedDescriptionKey: "Live API response error: \(error)"])
    }
}

guard sawServerContent else {
    throw NSError(domain: "LiveSmoke", code: 7, userInfo: [NSLocalizedDescriptionKey: "Did not receive serverContent after text input."])
}
log("phase: text response received")

let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9sXx2s8AAAAASUVORK5CYII=")!
try await sendJSON([
    "realtimeInput": [
        "video": [
            "data": tinyPNG.base64EncodedString(),
            "mimeType": "image/png"
        ]
    ]
], to: socket, delegate: delegate, label: "video")
log("phase: video sent")

do {
    let response = try await receiveJSON(from: socket, delegate: delegate, timeoutSeconds: sawTurnComplete ? 2 : 3)
    if let error = response["error"] {
        throw NSError(domain: "LiveSmoke", code: 8, userInfo: [NSLocalizedDescriptionKey: "Live API video-shape error: \(error)"])
    }
} catch {
    let nsError = error as NSError
    if !(nsError.domain == "LiveSmoke" && nsError.code == 3) {
        throw error
    }
}
log("phase: video accepted")

try await runGroundedSearchSmoke(apiKey: key)
log("phase: grounded search accepted")

socket.cancel(with: .normalClosure, reason: nil)
print("PASS: Live WebSocket opened, setupComplete received, custom toolCall/toolResponse worked, grounded Google Search returned sources, mic audio JSON was accepted, audioStreamEnd was accepted, video frame JSON was accepted, and serverContent was received for model \(model).")
