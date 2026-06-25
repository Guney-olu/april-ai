#!/usr/bin/env swift
import Foundation

struct Shortcut {
    let keyName: String
    let keyCode: Int
    let modifiers: [String]

    var strategy: String {
        let set = Set(modifiers)
        if (keyName == "left" || keyName == "right") && set == ["control"] {
            return "session_tap_for_global_shortcut"
        }
        if keyName == "space" && set == ["cmd"] {
            return "session_tap_for_global_shortcut"
        }
        return "hid_tap"
    }
}

func shortcut(for action: String) -> Shortcut? {
    switch action {
    case "spotlight", "cmd_space", "command_space":
        return shortcutFromKey("space", modifiers: ["cmd"])
    case "space_right", "screen_right":
        return shortcutFromKey("right", modifiers: ["control"])
    case "space_left", "screen_left":
        return shortcutFromKey("left", modifiers: ["control"])
    case "window_next", "next_window":
        return shortcutFromKey("`", modifiers: ["cmd"])
    case "page_down", "pagedown":
        return shortcutFromKey("pagedown", modifiers: [])
    case "page_up", "pageup":
        return shortcutFromKey("pageup", modifiers: [])
    case "space":
        return shortcutFromKey("space", modifiers: [])
    default:
        return nil
    }
}

func shortcutFromKey(_ key: String, modifiers: [String]) -> Shortcut? {
    let table = ["space": 49, "right": 124, "left": 123, "tab": 48, "c": 8, "`": 50, "l": 37, "pageup": 116, "pagedown": 121]
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
assertShortcut("window_next", keyName: "`", keyCode: 50, modifiers: ["cmd"])
assertShortcut("page_down", keyName: "pagedown", keyCode: 121, modifiers: [])
assertShortcut("page_up", keyName: "pageup", keyCode: 116, modifiers: [])
assertShortcut("space", keyName: "space", keyCode: 49, modifiers: [])
assertDynamic("right", modifiers: ["control"], keyCode: 124)
assertDynamic("space", modifiers: ["cmd"], keyCode: 49)
assertDynamic("l", modifiers: ["cmd"], keyCode: 37)

guard shortcut(for: "space_right")?.strategy == "session_tap_for_global_shortcut" else {
    fputs("FAIL space_right should use global shortcut strategy\n", stderr)
    exit(1)
}
guard shortcutFromKey("c", modifiers: ["cmd"])?.strategy == "hid_tap" else {
    fputs("FAIL regular app shortcuts should use HID strategy\n", stderr)
    exit(1)
}

print("PASS: shortcut smoke checks passed.")
