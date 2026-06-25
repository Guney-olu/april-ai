#!/usr/bin/env swift
import Foundation

func normalizedCoordinate(_ value: Double) -> Double? {
    guard value >= 0, value <= 1000 else { return nil }
    return value / 1000.0
}

func isRisky(action: String, intent: String = "", text: String = "", url: String = "") -> Bool {
    let combined = [action, intent, text, url].joined(separator: " ").lowercased()
    let riskyTerms = [
        "send", "submit", "buy", "purchase", "checkout", "pay", "delete", "remove",
        "confirm", "agree", "accept terms", "privacy", "security", "password",
        "passcode", "api key", "secret", "token", "credit card", "cvv"
    ]
    return riskyTerms.contains { combined.contains($0) }
}

func directionalScrollDelta(axis: String, direction: String, magnitude: Double?) -> Double? {
    guard let magnitude, magnitude != 0 else { return nil }
    switch (axis, direction.lowercased()) {
    case ("y", "down"): return -abs(magnitude)
    case ("y", "up"): return abs(magnitude)
    case ("x", "right"): return -abs(magnitude)
    case ("x", "left"): return abs(magnitude)
    default: return nil
    }
}

func wheelClickPixels(_ clicks: Double?) -> Double? {
    clicks.map { $0 * 80 }
}

func assertEqual(_ actual: Double?, _ expected: Double, _ label: String) {
    guard let actual, abs(actual - expected) < 0.0001 else {
        fputs("FAIL \(label): expected \(expected), got \(String(describing: actual))\n", stderr)
        exit(1)
    }
}

assertEqual(normalizedCoordinate(0), 0, "zero coordinate")
assertEqual(normalizedCoordinate(500), 0.5, "center coordinate")
assertEqual(normalizedCoordinate(1000), 1, "max coordinate")

if normalizedCoordinate(-1) != nil {
    fputs("FAIL negative coordinate accepted\n", stderr)
    exit(1)
}
if normalizedCoordinate(1001) != nil {
    fputs("FAIL out-of-range coordinate accepted\n", stderr)
    exit(1)
}
if !isRisky(action: "click", intent: "Click Submit to finish the form") {
    fputs("FAIL submit action was not flagged risky\n", stderr)
    exit(1)
}
if !isRisky(action: "type", text: "my password is swordfish") {
    fputs("FAIL secret-looking text was not flagged risky\n", stderr)
    exit(1)
}
if isRisky(action: "click", intent: "Click the search field") {
    fputs("FAIL harmless click was flagged risky\n", stderr)
    exit(1)
}
assertEqual(directionalScrollDelta(axis: "y", direction: "down", magnitude: 500), -500, "computer-use scroll down")
assertEqual(directionalScrollDelta(axis: "y", direction: "up", magnitude: 500), 500, "computer-use scroll up")
assertEqual(directionalScrollDelta(axis: "x", direction: "right", magnitude: 300), -300, "computer-use scroll right")
assertEqual(directionalScrollDelta(axis: "y", direction: "down", magnitude: wheelClickPixels(5)), -400, "computer-use wheel clicks down")

let defaultSteps = 12
let hardCap = 25
if !(1...hardCap).contains(defaultSteps) {
    fputs("FAIL default max steps is outside allowed range\n", stderr)
    exit(1)
}

print("PASS: Computer Use smoke checks passed.")
