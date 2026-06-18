import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ComputerControlService {
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func moveMouse(x: Double, y: Double) -> ComputerControlResult {
        guard ensureAccessibility() else { return accessibilityFailure() }
        guard let point = pointFromNormalized(x: x, y: y) else {
            return ComputerControlResult(ok: false, message: "Invalid mouse coordinates. Use x/y from 0.0 to 1.0.")
        }
        let action = "Move mouse to x \(format(x)), y \(format(y))"
        guard confirm(action: action, detail: "April AI wants to move your cursor.") else {
            return denied(action)
        }

        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        return ComputerControlResult(ok: true, message: "Mouse moved.", metadata: ["x": x, "y": y])
    }

    func clickMouse(x: Double?, y: Double?, button: String, count: Int) -> ComputerControlResult {
        guard ensureAccessibility() else { return accessibilityFailure() }
        let safeCount = max(1, min(count, 2))
        let normalizedButton = button.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedButton.isEmpty || normalizedButton == "left" || normalizedButton == "right" else {
            return ComputerControlResult(ok: false, message: "Unsupported mouse button. Allowed: left or right.")
        }
        let mouseButton = normalizedButton == "right" ? CGMouseButton.right : CGMouseButton.left
        let downType: CGEventType = mouseButton == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = mouseButton == .right ? .rightMouseUp : .leftMouseUp

        let point: CGPoint
        guard (x == nil && y == nil) || (x != nil && y != nil) else {
            return ComputerControlResult(ok: false, message: "Provide both x and y, or omit both to click the current cursor location.")
        }
        if let x, let y {
            guard let requestedPoint = pointFromNormalized(x: x, y: y) else {
                return ComputerControlResult(ok: false, message: "Invalid click coordinates. Use x/y from 0.0 to 1.0.")
            }
            point = requestedPoint
        } else {
            point = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        }

        let action = "\(safeCount == 2 ? "Double-click" : "Click") \(normalizedButton == "right" ? "right" : "left") mouse"
        guard confirm(action: action, detail: "April AI wants to click at screen point \(Int(point.x)), \(Int(point.y)).") else {
            return denied(action)
        }

        if x != nil, y != nil {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: mouseButton)?
                .post(tap: .cghidEventTap)
        }
        for _ in 0..<safeCount {
            CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton)?
                .post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton)?
                .post(tap: .cghidEventTap)
        }
        return ComputerControlResult(ok: true, message: "Mouse click executed.", metadata: ["button": button, "count": safeCount])
    }

    func scrollMouse(deltaX: Double, deltaY: Double) -> ComputerControlResult {
        guard ensureAccessibility() else { return accessibilityFailure() }
        let clampedX = max(-200, min(200, Int(deltaX)))
        let clampedY = max(-200, min(200, Int(deltaY)))
        guard clampedX != 0 || clampedY != 0 else {
            return ComputerControlResult(ok: false, message: "Scroll delta cannot be zero.")
        }

        let action = "Scroll mouse"
        guard confirm(action: action, detail: "April AI wants to scroll by dx \(clampedX), dy \(clampedY).") else {
            return denied(action)
        }

        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clampedY),
            wheel2: Int32(clampedX),
            wheel3: 0
        )?.post(tap: .cghidEventTap)
        return ComputerControlResult(ok: true, message: "Scroll executed.", metadata: ["delta_x": clampedX, "delta_y": clampedY])
    }

    func typeText(_ text: String) async -> ComputerControlResult {
        guard ensureAccessibility() else { return accessibilityFailure() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ComputerControlResult(ok: false, message: "Text cannot be empty.")
        }

        let preview = text.count > 500 ? String(text.prefix(500)) + "..." : text
        guard confirm(action: "Type text", detail: preview) else {
            return denied("Type text")
        }

        if shouldPaste(text) {
            await pasteWithClipboardRestore(text)
            return ComputerControlResult(ok: true, message: "Text pasted with clipboard restore.", metadata: ["characters": text.count, "method": "paste_restore"])
        }

        typeUnicodeKeystrokes(text)
        return ComputerControlResult(ok: true, message: "Text typed.", metadata: ["characters": text.count, "method": "keystrokes"])
    }

    func pressKey(_ key: String, modifiers: [String]) -> ComputerControlResult {
        guard ensureAccessibility() else { return accessibilityFailure() }
        guard let keyCode = keyCode(for: key, modifiers: modifiers) else {
            return ComputerControlResult(ok: false, message: "Unsupported key. Allowed: return, tab, escape, delete, arrows, and cmd+l.")
        }

        let normalizedModifiers = Set(modifiers.map { $0.lowercased() })
        let flags = eventFlags(for: normalizedModifiers)
        let action = "Press \(normalizedModifiers.isEmpty ? "" : normalizedModifiers.sorted().joined(separator: "+") + "+")\(key)"
        guard confirm(action: action, detail: "April AI wants to press this key once.") else {
            return denied(action)
        }

        postKey(keyCode, flags: flags)
        return ComputerControlResult(ok: true, message: "Key pressed.", metadata: ["key": key, "modifiers": Array(normalizedModifiers).sorted()])
    }

    func openApplication(_ app: String) -> ComputerControlResult {
        let query = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ComputerControlResult(ok: false, message: "Application name or bundle id is required.")
        }

        let resolution = resolveApplication(query)
        switch resolution {
        case .notFound:
            return ComputerControlResult(ok: false, message: "No matching application found.", metadata: ["query": query])
        case .ambiguous(let candidates):
            return ComputerControlResult(
                ok: false,
                message: "Application name is ambiguous. Try a bundle id or exact app name.",
                metadata: ["candidates": candidates.map(\.lastPathComponent)]
            )
        case .found(let url):
            guard confirm(action: "Open application", detail: "April AI wants to open \(url.lastPathComponent).") else {
                return denied("Open application")
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return ComputerControlResult(ok: true, message: "Application opened.", metadata: ["app": url.lastPathComponent, "path": url.path])
        }
    }

    private func ensureAccessibility() -> Bool {
        isAccessibilityTrusted
    }

    private func accessibilityFailure() -> ComputerControlResult {
        ComputerControlResult(
            ok: false,
            message: "Accessibility permission is required for keyboard and mouse control. Open Settings and click Request Accessibility Permission."
        )
    }

    private func denied(_ action: String) -> ComputerControlResult {
        ComputerControlResult(ok: false, message: "User denied action: \(action).", denied: true)
    }

    private func confirm(action: String, detail: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = action
        alert.informativeText = detail
        alert.addButton(withTitle: "Approve Once")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func pointFromNormalized(x: Double, y: Double) -> CGPoint? {
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
    }

    private func shouldPaste(_ text: String) -> Bool {
        text.count > 32 || text.contains(where: { $0.isNewline || !$0.isASCII })
    }

    private func typeUnicodeKeystrokes(_ text: String) {
        for scalar in text.unicodeScalars {
            var value = UniChar(scalar.value)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func pasteWithClipboardRestore(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let oldItems = pasteboard.pasteboardItems ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postKey(9, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 250_000_000)
        pasteboard.clearContents()
        pasteboard.writeObjects(oldItems)
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private func keyCode(for key: String, modifiers: [String]) -> CGKeyCode? {
        let normalized = key.lowercased()
        let modifierSet = Set(modifiers.map { $0.lowercased() })
        switch normalized {
        case "return", "enter": return modifierSet.isEmpty ? 36 : nil
        case "tab": return modifierSet.isEmpty ? 48 : nil
        case "escape", "esc": return modifierSet.isEmpty ? 53 : nil
        case "delete", "backspace": return modifierSet.isEmpty ? 51 : nil
        case "left", "arrowleft", "left_arrow": return modifierSet.isEmpty ? 123 : nil
        case "right", "arrowright", "right_arrow": return modifierSet.isEmpty ? 124 : nil
        case "down", "arrowdown", "down_arrow": return modifierSet.isEmpty ? 125 : nil
        case "up", "arrowup", "up_arrow": return modifierSet.isEmpty ? 126 : nil
        case "l" where modifierSet == ["cmd"] || modifierSet == ["command"]: return 37
        default: return nil
        }
    }

    private func eventFlags(for modifiers: Set<String>) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains("cmd") || modifiers.contains("command") { flags.insert(.maskCommand) }
        if modifiers.contains("shift") { flags.insert(.maskShift) }
        if modifiers.contains("option") || modifiers.contains("alt") { flags.insert(.maskAlternate) }
        if modifiers.contains("control") || modifiers.contains("ctrl") { flags.insert(.maskControl) }
        return flags
    }

    private func resolveApplication(_ query: String) -> AppResolution {
        if query.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            return .found(url)
        }

        let exactName = query.hasSuffix(".app") ? query : "\(query).app"
        let candidates = applicationDirectories()
            .flatMap { applications(in: $0) }
            .filter { url in
                let filename = url.lastPathComponent
                let displayName = url.deletingPathExtension().lastPathComponent
                return filename.localizedCaseInsensitiveCompare(exactName) == .orderedSame
                    || displayName.localizedCaseInsensitiveCompare(query) == .orderedSame
            }

        if candidates.count == 1 {
            return .found(candidates[0])
        }
        if candidates.count > 1 {
            return .ambiguous(candidates)
        }

        let fuzzy = applicationDirectories()
            .flatMap { applications(in: $0) }
            .filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) }
            .prefix(8)
        if fuzzy.count == 1, let url = fuzzy.first {
            return .found(url)
        }
        if fuzzy.count > 1 {
            return .ambiguous(Array(fuzzy))
        }
        return .notFound
    }

    private func applicationDirectories() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")
        ]
    }

    private func applications(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "app" else { return nil }
            return url
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private enum AppResolution {
    case found(URL)
    case ambiguous([URL])
    case notFound
}
