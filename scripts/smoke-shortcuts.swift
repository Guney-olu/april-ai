#!/usr/bin/env swift
import Foundation

struct Shortcut {
    let keyName: String
    let keyCode: Int
    let modifiers: [String]
}

func shortcut(for action: String) -> Shortcut? {
    switch action {
    case "spotlight", "cmd_space", "command_space":
        return shortcutFromKey("space", modifiers: ["cmd"])
    case "space_right", "screen_right":
        return shortcutFromKey("right", modifiers: ["control"])
    case "space_left", "screen_left":
        return shortcutFromKey("left", modifiers: ["control"])
    default:
        return nil
    }
}

func shortcutFromKey(_ key: String, modifiers: [String]) -> Shortcut? {
    let table = ["space": 49, "right": 124, "left": 123, "tab": 48, "c": 8]
    guard let keyCode = table[key] else { return nil }
    return Shortcut(keyName: key, keyCode: keyCode, modifiers: modifiers)
}

func assertShortcut(_ action: String, keyName: String, keyCode: Int, modifiers: [String]) {
    guard let shortcut = shortcut(for: action) else {
        fputs("FAIL missing shortcut \(action)\n", stderr)
        exit(1)
    }
    guard shortcut.keyName == keyName, shortcut.keyCode == keyCode, shortcut.modifiers == modifiers else {
        fputs("FAIL \(action): expected \(keyName) \(keyCode) \(modifiers), got \(shortcut.keyName) \(shortcut.keyCode) \(shortcut.modifiers)\n", stderr)
        exit(1)
    }
}

func assertDynamic(_ key: String, modifiers: [String], keyCode: Int) {
    guard let shortcut = shortcutFromKey(key, modifiers: modifiers) else {
        fputs("FAIL missing dynamic shortcut \(key)\n", stderr)
        exit(1)
    }
    guard shortcut.keyCode == keyCode, shortcut.modifiers == modifiers else {
        fputs("FAIL dynamic \(key): expected \(keyCode) \(modifiers), got \(shortcut.keyCode) \(shortcut.modifiers)\n", stderr)
        exit(1)
    }
}

assertShortcut("spotlight", keyName: "space", keyCode: 49, modifiers: ["cmd"])
assertShortcut("cmd_space", keyName: "space", keyCode: 49, modifiers: ["cmd"])
assertShortcut("space_right", keyName: "right", keyCode: 124, modifiers: ["control"])
assertShortcut("space_left", keyName: "left", keyCode: 123, modifiers: ["control"])
assertDynamic("right", modifiers: ["control"], keyCode: 124)
assertDynamic("space", modifiers: ["cmd"], keyCode: 49)

print("PASS: shortcut smoke checks passed.")
