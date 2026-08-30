#!/usr/bin/env swift
import Foundation

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func source(_ relativePath: String) -> String {
    let url = root.appending(path: relativePath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        fputs("FAIL: could not read \(relativePath)\n", stderr)
        exit(1)
    }
    return text
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let models = source("Sources/AprilAI/App/Models.swift")
let localServices = source("Sources/AprilAI/Local/LocalServices.swift")
let appState = source("Sources/AprilAI/App/AppState.swift")
let localView = source("Sources/AprilAI/UI/LocalView.swift")

require(models.contains("case local = \"Local\""), "Local workspace tab is missing")
require(models.contains("http://127.0.0.1:8888/v1"), "Unsloth default endpoint is missing")
require(models.contains("sonic-3.6"), "Cartesia Sonic default model is missing")
require(localServices.contains("chat/completions"), "OpenAI-compatible chat endpoint is missing")
require(localServices.contains("api.cartesia.ai/tts/bytes"), "Cartesia TTS endpoint is missing")
require(localServices.contains("Cartesia-Version"), "Cartesia API version header is missing")
require(localServices.contains("SFSpeechRecognizer"), "macOS Speech transcription is missing")
require(localServices.contains("\"web_search\", \"python\", \"terminal\""), "Unsloth tools are not enabled")
require(appState.contains("func sendLocal("), "Local chat state handler is missing")
require(appState.contains("func startOrStopLocalVoice()"), "Local voice state handler is missing")
require(appState.contains("func speakWithCartesia("), "Cartesia playback path is missing")
require(localView.contains("Test services"), "Local UI service testing is missing")

print("PASS: Local mode contract smoke checks passed.")
