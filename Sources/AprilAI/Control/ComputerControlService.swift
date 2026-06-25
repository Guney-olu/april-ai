import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ComputerControlService {
    private var latestScreenFrameGeometry: ScreenFrameGeometry?
    private let shortcutEngine = ShortcutExecutionEngine()

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func updateLatestScreenFrameGeometry(_ geometry: ScreenFrameGeometry) {
        latestScreenFrameGeometry = geometry
    }

    func screenGeometry() -> ComputerControlResult {
        var metadata = (latestScreenFrameGeometry ?? fallbackGeometry()).toolMetadata
        let mouse = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        metadata["has_live_frame"] = latestScreenFrameGeometry != nil
        metadata["current_mouse"] = ["x": mouse.x, "y": mouse.y]
        metadata["active_display_id"] = activeDisplayID(for: mouse)
        metadata["displays"] = displayMetadata()
        metadata["coordinate_rules"] = [
            "normalized": "x/y must be 0.0...1.0 relative to the main display.",
            "image_pixels": "Use coordinate_space=image_pixels with image_x/image_y from the latest captured grid image."
        ]
        return ComputerControlResult(ok: true, message: "Screen geometry ready.", metadata: metadata)
    }

    func moveMouse(
        x: Double?,
        y: Double?,
        coordinateSpace: String,
        imageX: Double?,
        imageY: Double?,
        imageWidth: Double?,
        imageHeight: Double?
    ) -> ComputerControlResult {
        guard ensureAccessibility() else { return accessibilityFailure() }
        let resolution = resolvePoint(
            x: x,
            y: y,
            coordinateSpace: coordinateSpace,
            imageX: imageX,
            imageY: imageY,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        guard resolution.result.ok else {
            return resolution.result
        }
        let intendedPoint = resolution.point
        let before = currentMouseLocation()
        moveCursor(to: intendedPoint, button: .left)
        Thread.sleep(forTimeInterval: 0.035)
        let after = currentMouseLocation()
        var metadata = resolution.metadata
        metadata.merge(mouseMoveMetadata(before: before, intended: intendedPoint, after: after)) { _, new in new }
        return ComputerControlResult(ok: true, message: "Mouse moved.", metadata: metadata)
    }

    func clickMouse(
        x: Double?,
        y: Double?,
        coordinateSpace: String,
        imageX: Double?,
        imageY: Double?,
        imageWidth: Double?,
        imageHeight: Double?,
        button: String,
        count: Int,
        moveBeforeClick: Bool = true
    ) -> ComputerControlResult {
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
        let hasRequestedPoint = x != nil || y != nil || !coordinateSpace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageX != nil || imageY != nil
        var metadata: [String: Any] = [
            "button": normalizedButton.isEmpty ? "left" : normalizedButton,
            "count": safeCount,
            "move_before_click": moveBeforeClick
        ]
        guard (x == nil && y == nil) || (x != nil && y != nil) else {
            return ComputerControlResult(ok: false, message: "Provide both x and y, or omit both to click the current cursor location.")
        }
        if hasRequestedPoint {
            let resolution = resolvePoint(
                x: x,
                y: y,
                coordinateSpace: coordinateSpace,
                imageX: imageX,
                imageY: imageY,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
            guard resolution.result.ok else {
                return resolution.result
            }
            point = resolution.point
            metadata["intended_point"] = pointMetadata(resolution.point)
            metadata.merge(resolution.metadata) { _, new in new }
        } else {
            point = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
            metadata["coordinate_space"] = "current_cursor"
            metadata["resolved_point"] = ["x": point.x, "y": point.y]
        }

        let before = currentMouseLocation()
        if hasRequestedPoint && moveBeforeClick {
            moveCursor(to: point, button: mouseButton)
            Thread.sleep(forTimeInterval: 0.035)
        }
        let afterMove = currentMouseLocation()
        for _ in 0..<safeCount {
            CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton)?
                .post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton)?
                .post(tap: .cghidEventTap)
        }
        var clickMetadata: [String: Any] = [
            "before_mouse": pointMetadata(before),
            "target_point": pointMetadata(point),
            "after_move_mouse": pointMetadata(afterMove),
            "event_post_strategy": moveBeforeClick ? "move_then_click" : "direct_click_without_pre_move"
        ]
        if hasRequestedPoint && moveBeforeClick {
            clickMetadata["move_error_distance"] = distance(point, afterMove)
        }
        metadata.merge(clickMetadata) { _, new in new }
        return ComputerControlResult(ok: true, message: "Mouse click executed.", metadata: metadata)
    }

    func scrollMouse(deltaX: Double, deltaY: Double) -> ComputerControlResult {
        guard ensureAccessibility() else { return accessibilityFailure() }
        let clampedX = max(-200, min(200, Int(deltaX)))
        let clampedY = max(-200, min(200, Int(deltaY)))
        guard clampedX != 0 || clampedY != 0 else {
            return ComputerControlResult(ok: false, message: "Scroll delta cannot be zero.")
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

        if shouldPaste(text) {
            await pasteWithClipboardRestore(text)
            return ComputerControlResult(ok: true, message: "Text pasted with clipboard restore.", metadata: ["characters": text.count, "method": "paste_restore"])
        }

        typeUnicodeKeystrokes(text)
        return ComputerControlResult(ok: true, message: "Text typed.", metadata: ["characters": text.count, "method": "keystrokes"])
    }

    func pressKey(_ key: String, modifiers: [String]) -> ComputerControlResult {
        guard ensureAccessibility() else { return accessibilityFailure() }
        guard let shortcut = shortcutFromKey(key, modifiers: modifiers) else {
            return ComputerControlResult(ok: false, message: "Unsupported key/modifier combination.")
        }

        let execution = shortcutEngine.post(shortcut)
        return ComputerControlResult(ok: true, message: "Key pressed.", metadata: execution.metadata.merging(["key": key, "modifiers": shortcut.modifierNames]) { _, new in new })
    }

    func keyboardShortcut(_ action: String, key: String = "", modifiers: [String] = []) -> ComputerControlResult {
        guard ensureAccessibility() else { return accessibilityFailure() }
        let normalized = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let shortcut = shortcut(for: normalized)
            ?? shortcutFromActionPhrase(action)
            ?? shortcutFromKey(key, modifiers: modifiers)

        guard let shortcut else {
            return ComputerControlResult(
                ok: false,
                message: "Unsupported shortcut. Use a named action or provide key plus safe modifiers."
            )
        }

        let execution = shortcutEngine.post(shortcut)
        return ComputerControlResult(
            ok: true,
            message: "Shortcut executed.",
            metadata: execution.metadata.merging([
                "action": normalized,
                "key": shortcut.keyName,
                "key_code": shortcut.keyCode,
                "modifiers": shortcut.modifierNames
            ]) { _, new in new }
        )
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
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return ComputerControlResult(ok: true, message: "Application opened.", metadata: ["app": url.lastPathComponent, "path": url.path])
        }
    }

    func activateApplication(_ app: String) -> ComputerControlResult {
        guard let runningApp = resolveRunningApplication(app) else {
            return ComputerControlResult(ok: false, message: "No running application matched \(app).")
        }
        let ok = runningApp.activate(options: [.activateIgnoringOtherApps])
        return ComputerControlResult(
            ok: ok,
            message: ok ? "Application activated." : "Application activation failed.",
            metadata: runningAppMetadata(runningApp)
        )
    }

    func quitApplication(_ app: String) -> ComputerControlResult {
        let query = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ComputerControlResult(ok: false, message: "Application name or bundle id is required.")
        }
        guard let runningApp = resolveRunningApplication(query) else {
            return ComputerControlResult(ok: false, message: "No running application matched \(query).")
        }
        let ok = runningApp.terminate()
        return ComputerControlResult(
            ok: ok,
            message: ok ? "Application quit requested." : "Application quit request failed.",
            metadata: runningAppMetadata(runningApp)
        )
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

    private func resolvePoint(
        x: Double?,
        y: Double?,
        coordinateSpace: String,
        imageX: Double?,
        imageY: Double?,
        imageWidth: Double?,
        imageHeight: Double?
    ) -> (point: CGPoint, metadata: [String: Any], result: ComputerControlResult) {
        let normalizedSpace = coordinateSpace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inferredImagePixels = normalizedSpace == "image_pixels" || normalizedSpace == "image-pixels" || normalizedSpace == "image"
        if inferredImagePixels {
            return pointFromImagePixels(
                imageX: imageX ?? x,
                imageY: imageY ?? y,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
        }

        guard let x, let y else {
            return failure("x and y are required for normalized mouse coordinates.")
        }
        guard (0...1).contains(x), (0...1).contains(y) else {
            return failure("Invalid normalized mouse coordinates. Use x/y from 0.0 to 1.0, or set coordinate_space to image_pixels with image_x/image_y.")
        }

        let geometry = latestScreenFrameGeometry ?? fallbackGeometry()
        let bounds = geometry.logicalBounds
        let point = CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
        var metadata = geometry.toolMetadata
        metadata["coordinate_space"] = "normalized"
        metadata["input"] = ["x": x, "y": y]
        metadata["resolved_point"] = ["x": point.x, "y": point.y]
        return (point, metadata, ComputerControlResult(ok: true, message: "Resolved point."))
    }

    private func pointFromImagePixels(
        imageX: Double?,
        imageY: Double?,
        imageWidth: Double?,
        imageHeight: Double?
    ) -> (point: CGPoint, metadata: [String: Any], result: ComputerControlResult) {
        guard let geometry = latestScreenFrameGeometry else {
            return failure("No Live screen frame geometry is available yet. Share screen first, then use image_pixels coordinates.")
        }
        guard let imageX, let imageY else {
            return failure("image_x and image_y are required when coordinate_space is image_pixels.")
        }

        let width = imageWidth ?? Double(geometry.sentImageWidth)
        let height = imageHeight ?? Double(geometry.sentImageHeight)
        guard width > 0, height > 0 else {
            return failure("image_width and image_height must be greater than zero.")
        }
        guard (0...width).contains(imageX), (0...height).contains(imageY) else {
            return failure("image_x/image_y are outside the latest Live image bounds. Call screen_geometry and use coordinates from the sent image size.")
        }

        let bounds = geometry.logicalBounds
        let point = CGPoint(
            x: bounds.minX + (imageX * bounds.width / width),
            y: bounds.minY + (imageY * bounds.height / height)
        )
        var metadata = geometry.toolMetadata
        metadata["coordinate_space"] = "image_pixels"
        metadata["input"] = [
            "image_x": imageX,
            "image_y": imageY,
            "image_width": width,
            "image_height": height
        ]
        metadata["coordinate_mapper"] = [
            "mapping_mode": "direct_ratio",
            "formula": "logical = logical_bounds.origin + image_point * logical_bounds.size / image_size",
            "resolved_point": ["x": point.x, "y": point.y]
        ]
        metadata["resolved_point"] = ["x": point.x, "y": point.y]
        return (point, metadata, ComputerControlResult(ok: true, message: "Resolved point."))
    }

    private func fallbackGeometry() -> ScreenFrameGeometry {
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let screen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        } ?? NSScreen.main
        return ScreenFrameGeometry(
            displayID: displayID,
            capturePixelWidth: Int(bounds.width),
            capturePixelHeight: Int(bounds.height),
            sentImageWidth: Int(bounds.width),
            sentImageHeight: Int(bounds.height),
            logicalBounds: bounds,
            backingScaleFactor: Double(screen?.backingScaleFactor ?? 1),
            capturedAt: Date()
        )
    }

    private func failure(_ message: String) -> (point: CGPoint, metadata: [String: Any], result: ComputerControlResult) {
        (.zero, [:], ComputerControlResult(ok: false, message: message))
    }

    private func moveCursor(to point: CGPoint, button: CGMouseButton) {
        CGWarpMouseCursorPosition(point)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
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
        _ = shortcutEngine.post(KeyboardShortcut(keyName: "v", keyCode: 9, flags: .maskCommand, modifierNames: ["cmd"]))
        try? await Task.sleep(nanoseconds: 250_000_000)
        pasteboard.clearContents()
        pasteboard.writeObjects(oldItems)
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private func shortcut(for action: String) -> KeyboardShortcut? {
        switch action {
        case "copy": return shortcutFromKey("c", modifiers: ["cmd"])
        case "paste": return shortcutFromKey("v", modifiers: ["cmd"])
        case "cut": return shortcutFromKey("x", modifiers: ["cmd"])
        case "select_all": return shortcutFromKey("a", modifiers: ["cmd"])
        case "undo": return shortcutFromKey("z", modifiers: ["cmd"])
        case "redo": return shortcutFromKey("z", modifiers: ["cmd", "shift"])
        case "find", "search": return shortcutFromKey("f", modifiers: ["cmd"])
        case "spotlight", "cmd_space", "command_space": return shortcutFromKey("space", modifiers: ["cmd"])
        case "open_location", "address_bar": return shortcutFromKey("l", modifiers: ["cmd"])
        case "new_tab": return shortcutFromKey("t", modifiers: ["cmd"])
        case "close_tab", "close_window": return shortcutFromKey("w", modifiers: ["cmd"])
        case "window_next", "next_window", "app_window_next": return shortcutFromKey("`", modifiers: ["cmd"])
        case "next_tab": return shortcutFromKey("tab", modifiers: ["control"])
        case "previous_tab": return shortcutFromKey("tab", modifiers: ["control", "shift"])
        case "quit_app": return shortcutFromKey("q", modifiers: ["cmd"])
        case "space_left", "screen_left": return shortcutFromKey("left", modifiers: ["control"])
        case "space_right", "screen_right": return shortcutFromKey("right", modifiers: ["control"])
        case "page_down", "pagedown": return shortcutFromKey("pagedown", modifiers: [])
        case "page_up", "pageup": return shortcutFromKey("pageup", modifiers: [])
        case "home": return shortcutFromKey("home", modifiers: [])
        case "end": return shortcutFromKey("end", modifiers: [])
        case "space": return shortcutFromKey("space", modifiers: [])
        case "return", "enter": return shortcutFromKey("return", modifiers: [])
        case "tab": return shortcutFromKey("tab", modifiers: [])
        case "escape", "esc": return shortcutFromKey("escape", modifiers: [])
        case "delete", "backspace": return shortcutFromKey("delete", modifiers: [])
        case "left", "arrow_left", "left_arrow": return shortcutFromKey("left", modifiers: [])
        case "right", "arrow_right", "right_arrow": return shortcutFromKey("right", modifiers: [])
        case "down", "arrow_down", "down_arrow": return shortcutFromKey("down", modifiers: [])
        case "up", "arrow_up", "up_arrow": return shortcutFromKey("up", modifiers: [])
        default: return nil
        }
    }

    private func shortcutFromActionPhrase(_ phrase: String) -> KeyboardShortcut? {
        let cleaned = phrase
            .lowercased()
            .replacingOccurrences(of: " plus ", with: "+")
            .replacingOccurrences(of: " key", with: "")
            .replacingOccurrences(of: "arrow", with: "")
            .replacingOccurrences(of: "command", with: "cmd")
            .replacingOccurrences(of: "control", with: "ctrl")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "+")
        let parts = cleaned
            .split(separator: "+")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard parts.count >= 2, let key = parts.last else { return nil }
        return shortcutFromKey(key, modifiers: Array(parts.dropLast()))
    }

    private func shortcutFromKey(_ key: String, modifiers: [String]) -> KeyboardShortcut? {
        let normalizedKey = normalizedKeyName(key)
        let normalizedModifiers = normalizedModifierNames(modifiers)
        guard let keyCode = keyCode(for: normalizedKey) else { return nil }
        guard shortcutIsAllowed(key: normalizedKey, modifiers: normalizedModifiers) else { return nil }
        return KeyboardShortcut(
            keyName: normalizedKey,
            keyCode: keyCode,
            flags: eventFlags(for: Set(normalizedModifiers)),
            modifierNames: normalizedModifiers
        )
    }

    private func normalizedKeyName(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "arrow", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func normalizedModifierNames(_ modifiers: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for modifier in modifiers {
            let normalized: String
            switch modifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "cmd", "command", "⌘": normalized = "cmd"
            case "ctrl", "control", "⌃": normalized = "control"
            case "shift", "⇧": normalized = "shift"
            case "option", "alt", "⌥": normalized = "option"
            default: continue
            }
            if !seen.contains(normalized) {
                seen.insert(normalized)
                output.append(normalized)
            }
        }
        return output
    }

    private func shortcutIsAllowed(key: String, modifiers: [String]) -> Bool {
        let modifierSet = Set(modifiers)
        guard modifierSet.isSubset(of: ["cmd", "control", "shift", "option"]) else { return false }
        if ["delete", "backspace"].contains(key), !modifierSet.isEmpty {
            return false
        }
        if ["return", "enter"].contains(key), modifierSet.contains("cmd") || modifierSet.contains("control") {
            return false
        }
        return keyCode(for: key) != nil
    }

    private func keyCode(for key: String) -> CGKeyCode? {
        let table: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
            "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51,
            "backspace": 51, "escape": 53, "esc": 53, "home": 115, "pageup": 116, "end": 119,
            "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126
        ]
        return table[key]
    }

    private func modifierKeyCode(_ name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "cmd", "command": return 55
        case "shift": return 56
        case "control", "ctrl": return 59
        case "option", "alt": return 58
        default: return nil
        }
    }

    private func modifierFlag(_ name: String) -> CGEventFlags? {
        switch name.lowercased() {
        case "cmd", "command": return .maskCommand
        case "shift": return .maskShift
        case "control", "ctrl": return .maskControl
        case "option", "alt": return .maskAlternate
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

    private func currentMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
    }

    private func mouseMoveMetadata(
        before: CGPoint,
        intended: CGPoint,
        after: CGPoint
    ) -> [String: Any] {
        [
            "before_mouse": pointMetadata(before),
            "intended_point": pointMetadata(intended),
            "target_point": pointMetadata(intended),
            "actual_mouse": pointMetadata(after),
            "move_error_distance": distance(intended, after)
        ]
    }

    private func pointMetadata(_ point: CGPoint) -> [String: Double] {
        ["x": point.x, "y": point.y]
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    private func activeDisplayID(for point: CGPoint) -> UInt32 {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            if screen.frame.contains(point) {
                return number.uint32Value
            }
        }
        return CGMainDisplayID()
    }

    private func displayMetadata() -> [[String: Any]] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return [
                "display_id": number.uint32Value,
                "frame": [
                    "x": screen.frame.origin.x,
                    "y": screen.frame.origin.y,
                    "width": screen.frame.width,
                    "height": screen.frame.height
                ],
                "backing_scale_factor": screen.backingScaleFactor
            ] as [String: Any]
        }
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

    private func resolveRunningApplication(_ app: String) -> NSRunningApplication? {
        let query = app.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return NSWorkspace.shared.frontmostApplication
        }

        let matches = NSWorkspace.shared.runningApplications.filter { runningApp in
            let bundleID = runningApp.bundleIdentifier ?? ""
            let name = runningApp.localizedName ?? ""
            return bundleID.localizedCaseInsensitiveCompare(query) == .orderedSame
                || name.localizedCaseInsensitiveCompare(query) == .orderedSame
                || bundleID.localizedCaseInsensitiveContains(query)
                || name.localizedCaseInsensitiveContains(query)
        }

        if matches.count == 1 {
            return matches[0]
        }
        return matches.first(where: { $0.isActive }) ?? matches.first
    }

    private func runningAppMetadata(_ app: NSRunningApplication) -> [String: Any] {
        [
            "app": app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            "bundle_id": app.bundleIdentifier ?? "",
            "pid": app.processIdentifier
        ]
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

}

private struct KeyboardShortcut {
    var keyName = ""
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let modifierNames: [String]

    var isGlobalSystemShortcut: Bool {
        let modifiers = Set(modifierNames)
        return (keyName == "left" || keyName == "right") && modifiers == ["control"]
            || keyName == "space" && modifiers == ["cmd"]
    }
}

private enum AppResolution {
    case found(URL)
    case ambiguous([URL])
    case notFound
}

private struct ShortcutExecutionResult {
    let metadata: [String: Any]
}

private final class ShortcutExecutionEngine {
    func post(_ shortcut: KeyboardShortcut) -> ShortcutExecutionResult {
        let strategy = shortcut.isGlobalSystemShortcut ? "session_tap_for_global_shortcut" : "hid_tap"
        let tap: CGEventTapLocation = shortcut.isGlobalSystemShortcut ? .cgSessionEventTap : .cghidEventTap
        let holdDelay = shortcut.isGlobalSystemShortcut ? 0.09 : 0.035
        let source = CGEventSource(stateID: .hidSystemState)
        var activeFlags: CGEventFlags = []

        for modifier in shortcut.modifierNames {
            guard let code = modifierKeyCode(modifier), let flag = modifierFlag(modifier) else { continue }
            activeFlags.insert(flag)
            postKeyEvent(source: source, keyCode: code, keyDown: true, flags: activeFlags, tap: tap)
        }

        Thread.sleep(forTimeInterval: shortcut.modifierNames.isEmpty ? 0 : holdDelay)
        postKeyEvent(source: source, keyCode: shortcut.keyCode, keyDown: true, flags: shortcut.flags, tap: tap)
        Thread.sleep(forTimeInterval: holdDelay)
        postKeyEvent(source: source, keyCode: shortcut.keyCode, keyDown: false, flags: shortcut.flags, tap: tap)
        Thread.sleep(forTimeInterval: shortcut.modifierNames.isEmpty ? 0 : holdDelay)

        for modifier in shortcut.modifierNames.reversed() {
            guard let code = modifierKeyCode(modifier), let flag = modifierFlag(modifier) else { continue }
            activeFlags.remove(flag)
            postKeyEvent(source: source, keyCode: code, keyDown: false, flags: activeFlags, tap: tap)
        }

        var metadata: [String: Any] = [
            "strategy": strategy,
            "tap": shortcut.isGlobalSystemShortcut ? "cgSessionEventTap" : "cghidEventTap",
            "hold_delay_seconds": holdDelay,
            "key": shortcut.keyName,
            "key_code": shortcut.keyCode,
            "modifiers": shortcut.modifierNames
        ]
        if shortcut.isGlobalSystemShortcut {
            metadata["warning"] = "macOS global shortcuts such as Space switching or Spotlight must be enabled in System Settings. Synthetic events can be accepted by April AI but ignored by macOS policy."
        }
        return ShortcutExecutionResult(metadata: metadata)
    }

    private func postKeyEvent(
        source: CGEventSource?,
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        tap: CGEventTapLocation
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: tap)
    }

    private func modifierKeyCode(_ name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "cmd", "command": return 55
        case "shift": return 56
        case "control", "ctrl": return 59
        case "option", "alt": return 58
        default: return nil
        }
    }

    private func modifierFlag(_ name: String) -> CGEventFlags? {
        switch name.lowercased() {
        case "cmd", "command": return .maskCommand
        case "shift": return .maskShift
        case "control", "ctrl": return .maskControl
        case "option", "alt": return .maskAlternate
        default: return nil
        }
    }
}
