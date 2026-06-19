import AppKit
import ApplicationServices
import Foundation

@MainActor
final class AccessibilityControlService {
    private var elementMap: [String: AXUIElement] = [:]
    private var snapshotCounter = 0
    private let maxDepth = 6
    private let maxElements = 140

    func snapshot(app: String) -> ComputerControlResult {
        guard AXIsProcessTrusted() else { return accessibilityFailure() }
        guard let runningApp = resolveRunningApplication(app) else {
            return ComputerControlResult(ok: false, message: app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No frontmost application is available."
                : "No running application matched \(app).")
        }

        elementMap = [:]
        snapshotCounter = 0
        var visited: Set<UInt> = []
        var elements: [[String: Any]] = []
        let root = AXUIElementCreateApplication(runningApp.processIdentifier)
        collect(element: root, depth: 0, parentID: nil, visited: &visited, output: &elements)

        return ComputerControlResult(
            ok: true,
            message: "AX snapshot captured.",
            metadata: [
                "app": runningApp.localizedName ?? runningApp.bundleIdentifier ?? "Unknown",
                "bundle_id": runningApp.bundleIdentifier ?? "",
                "pid": runningApp.processIdentifier,
                "element_count": elements.count,
                "elements": elements
            ]
        )
    }

    func press(elementID: String) -> ComputerControlResult {
        guard AXIsProcessTrusted() else { return accessibilityFailure() }
        guard let element = elementMap[elementID] else {
            return missingElementFailure(elementID)
        }

        let error = AXUIElementPerformAction(element, "AXPress" as CFString)
        guard error == .success else {
            return ComputerControlResult(ok: false, message: "AX press failed: \(error.readableName).")
        }
        return ComputerControlResult(ok: true, message: "AX press executed.", metadata: ["element_id": elementID])
    }

    func setValue(elementID: String, value: String) -> ComputerControlResult {
        guard AXIsProcessTrusted() else { return accessibilityFailure() }
        guard let element = elementMap[elementID] else {
            return missingElementFailure(elementID)
        }

        let error = AXUIElementSetAttributeValue(element, "AXValue" as CFString, value as CFTypeRef)
        guard error == .success else {
            return ComputerControlResult(ok: false, message: "AX set value failed: \(error.readableName).")
        }
        return ComputerControlResult(ok: true, message: "AX value set.", metadata: ["element_id": elementID, "characters": value.count])
    }

    func focus(elementID: String) -> ComputerControlResult {
        guard AXIsProcessTrusted() else { return accessibilityFailure() }
        guard let element = elementMap[elementID] else {
            return missingElementFailure(elementID)
        }

        let error = AXUIElementSetAttributeValue(element, "AXFocused" as CFString, kCFBooleanTrue)
        guard error == .success else {
            return ComputerControlResult(ok: false, message: "AX focus failed: \(error.readableName).")
        }
        return ComputerControlResult(ok: true, message: "AX element focused.", metadata: ["element_id": elementID])
    }

    func find(query: String, app: String, roles: [String], limit: Int) -> ComputerControlResult {
        guard AXIsProcessTrusted() else { return accessibilityFailure() }
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else {
            return ComputerControlResult(ok: false, message: "AX query is required.")
        }

        let snapshot = captureSnapshot(app: app)
        guard snapshot.result.ok else { return snapshot.result }
        let roleFilter = Set(roles.map { normalized($0) }.filter { !$0.isEmpty })
        let matches = rankedMatches(
            query: normalizedQuery,
            elements: snapshot.elements,
            roleFilter: roleFilter,
            limit: max(1, min(limit, 12))
        )

        return ComputerControlResult(
            ok: true,
            message: matches.isEmpty ? "No AX elements matched." : "AX matches found.",
            metadata: [
                "query": query,
                "app": snapshot.appName,
                "bundle_id": snapshot.bundleID,
                "matches": matches
            ]
        )
    }

    func clickMatch(query: String, app: String, role: String) -> ComputerControlResult {
        let match = bestMatch(query: query, app: app, roles: role.isEmpty ? [] : [role])
        guard match.result.ok else { return match.result }
        return press(elementID: match.elementID)
            .mergingMetadata(["matched_element": match.metadata])
    }

    func focusMatch(query: String, app: String, role: String) -> ComputerControlResult {
        let match = bestMatch(query: query, app: app, roles: role.isEmpty ? [] : [role])
        guard match.result.ok else { return match.result }
        return focus(elementID: match.elementID)
            .mergingMetadata(["matched_element": match.metadata])
    }

    func setValueMatch(query: String, value: String, app: String, role: String) -> ComputerControlResult {
        let match = bestMatch(query: query, app: app, roles: role.isEmpty ? [] : [role])
        guard match.result.ok else { return match.result }
        let focusResult = focus(elementID: match.elementID)
        if !focusResult.ok {
            return focusResult.mergingMetadata(["matched_element": match.metadata])
        }
        return setValue(elementID: match.elementID, value: value)
            .mergingMetadata(["matched_element": match.metadata])
    }

    func menuAction(app: String, menuPath: String) -> ComputerControlResult {
        guard AXIsProcessTrusted() else { return accessibilityFailure() }
        guard let runningApp = resolveRunningApplication(app) else {
            return ComputerControlResult(ok: false, message: app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No frontmost application is available."
                : "No running application matched \(app).")
        }

        let parts = menuPath
            .replacingOccurrences(of: "/", with: ">")
            .split(separator: ">")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return ComputerControlResult(ok: false, message: "Menu path is required, for example File > Close Window.")
        }

        let root = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard let menuBarValue = copyAttribute("AXMenuBar", element: root) else {
            return ComputerControlResult(ok: false, message: "This app does not expose an AX menu bar.")
        }
        let menuBar = menuBarValue as! AXUIElement

        var current = menuBar
        var traversed: [String] = []
        for (index, part) in parts.enumerated() {
            guard let next = childElements(for: current).first(where: { elementMatchesMenuPart($0, part) }) else {
                return ComputerControlResult(ok: false, message: "Menu item not found: \(part).", metadata: ["traversed": traversed])
            }
            traversed.append(part)
            current = next
            if index < parts.count - 1 {
                _ = AXUIElementPerformAction(current, "AXPress" as CFString)
                Thread.sleep(forTimeInterval: 0.08)
            }
        }

        let error = AXUIElementPerformAction(current, "AXPress" as CFString)
        guard error == .success else {
            return ComputerControlResult(ok: false, message: "AX menu action failed: \(error.readableName).", metadata: ["menu_path": parts])
        }
        return ComputerControlResult(
            ok: true,
            message: "AX menu action executed.",
            metadata: [
                "app": runningApp.localizedName ?? runningApp.bundleIdentifier ?? "Unknown",
                "bundle_id": runningApp.bundleIdentifier ?? "",
                "menu_path": parts
            ]
        )
    }

    private func captureSnapshot(app: String) -> (result: ComputerControlResult, appName: String, bundleID: String, elements: [[String: Any]]) {
        guard let runningApp = resolveRunningApplication(app) else {
            return (
                ComputerControlResult(ok: false, message: app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No frontmost application is available."
                    : "No running application matched \(app)."),
                "",
                "",
                []
            )
        }

        elementMap = [:]
        snapshotCounter = 0
        var visited: Set<UInt> = []
        var elements: [[String: Any]] = []
        let root = AXUIElementCreateApplication(runningApp.processIdentifier)
        collect(element: root, depth: 0, parentID: nil, visited: &visited, output: &elements)
        let appName = runningApp.localizedName ?? runningApp.bundleIdentifier ?? "Unknown"
        let bundleID = runningApp.bundleIdentifier ?? ""
        return (
            ComputerControlResult(
                ok: true,
                message: "AX snapshot captured.",
                metadata: [
                    "app": appName,
                    "bundle_id": bundleID,
                    "pid": runningApp.processIdentifier,
                    "element_count": elements.count,
                    "elements": elements
                ]
            ),
            appName,
            bundleID,
            elements
        )
    }

    private func bestMatch(query: String, app: String, roles: [String]) -> (elementID: String, metadata: [String: Any], result: ComputerControlResult) {
        guard AXIsProcessTrusted() else { return ("", [:], accessibilityFailure()) }
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else {
            return ("", [:], ComputerControlResult(ok: false, message: "AX query is required."))
        }

        let snapshot = captureSnapshot(app: app)
        guard snapshot.result.ok else { return ("", [:], snapshot.result) }
        let matches = rankedMatches(
            query: normalizedQuery,
            elements: snapshot.elements,
            roleFilter: Set(roles.map { normalized($0) }.filter { !$0.isEmpty }),
            limit: 1
        )
        guard let first = matches.first, let id = first["id"] as? String else {
            return ("", [:], ComputerControlResult(ok: false, message: "No AX element matched \(query)."))
        }
        return (id, first, ComputerControlResult(ok: true, message: "AX element matched."))
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

    private func collect(
        element: AXUIElement,
        depth: Int,
        parentID: String?,
        visited: inout Set<UInt>,
        output: inout [[String: Any]]
    ) {
        guard depth <= maxDepth, output.count < maxElements else { return }

        let hash = CFHash(element)
        guard !visited.contains(hash) else { return }
        visited.insert(hash)

        snapshotCounter += 1
        let id = "ax_\(snapshotCounter)"
        elementMap[id] = element

        var item = describe(element: element, id: id, parentID: parentID, depth: depth)
        let children = childElements(for: element)
        item["child_count"] = children.count
        output.append(item)

        for child in children {
            guard output.count < maxElements else { break }
            collect(element: child, depth: depth + 1, parentID: id, visited: &visited, output: &output)
        }
    }

    private func describe(element: AXUIElement, id: String, parentID: String?, depth: Int) -> [String: Any] {
        var item: [String: Any] = [
            "id": id,
            "depth": depth,
            "role": stringAttribute("AXRole", element: element),
            "title": stringAttribute("AXTitle", element: element),
            "description": stringAttribute("AXDescription", element: element),
            "value": clipped(stringAttribute("AXValue", element: element)),
            "enabled": boolAttribute("AXEnabled", element: element) as Any,
            "focused": boolAttribute("AXFocused", element: element) as Any,
            "actions": actionNames(for: element)
        ]
        if let parentID {
            item["parent_id"] = parentID
        }
        if let frame = frame(for: element) {
            item["frame"] = [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.width,
                "height": frame.height
            ]
        }
        return item
    }

    private func rankedMatches(
        query: String,
        elements: [[String: Any]],
        roleFilter: Set<String>,
        limit: Int
    ) -> [[String: Any]] {
        elements.compactMap { item -> (score: Int, item: [String: Any])? in
            let role = normalized(item["role"] as? String ?? "")
            guard roleFilter.isEmpty || roleFilter.contains(role) || roleFilter.contains(role.replacingOccurrences(of: "ax", with: "")) else {
                return nil
            }

            let title = normalized(item["title"] as? String ?? "")
            let description = normalized(item["description"] as? String ?? "")
            let value = normalized(item["value"] as? String ?? "")
            let haystack = [title, description, value, role].joined(separator: " ")
            guard haystack.contains(query) || query.split(separator: " ").allSatisfy({ haystack.contains($0) }) else {
                return nil
            }

            var score = 1
            if title == query { score += 50 }
            if description == query { score += 35 }
            if title.contains(query) { score += 20 }
            if description.contains(query) { score += 14 }
            if value.contains(query) { score += 8 }
            if let enabled = item["enabled"] as? Bool, enabled { score += 5 }
            if (item["actions"] as? [String])?.contains("AXPress") == true { score += 5 }

            var scored = item
            scored["score"] = score
            return (score, scored)
        }
        .sorted { lhs, rhs in lhs.score > rhs.score }
        .prefix(limit)
        .map(\.item)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func childElements(for element: AXUIElement) -> [AXUIElement] {
        var children: [AXUIElement] = []
        for attribute in ["AXWindows", "AXVisibleChildren", "AXChildren"] {
            if let values = arrayAttribute(attribute, element: element) {
                children.append(contentsOf: values)
            }
        }
        return children
    }

    private func elementMatchesMenuPart(_ element: AXUIElement, _ part: String) -> Bool {
        let target = normalized(part)
        let candidates = [
            stringAttribute("AXTitle", element: element),
            stringAttribute("AXDescription", element: element),
            stringAttribute("AXValue", element: element)
        ].map(normalized)
        return candidates.contains(target) || candidates.contains { $0.replacingOccurrences(of: "...", with: "") == target }
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var value: CFArray?
        let error = AXUIElementCopyActionNames(element, &value)
        guard error == .success, let names = value as? [String] else {
            return []
        }
        return names
    }

    private func stringAttribute(_ attribute: String, element: AXUIElement) -> String {
        guard let value = copyAttribute(attribute, element: element) else { return "" }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private func boolAttribute(_ attribute: String, element: AXUIElement) -> Bool? {
        copyAttribute(attribute, element: element) as? Bool
    }

    private func arrayAttribute(_ attribute: String, element: AXUIElement) -> [AXUIElement]? {
        copyAttribute(attribute, element: element) as? [AXUIElement]
    }

    private func copyAttribute(_ attribute: String, element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as AnyObject?
    }

    private func frame(for element: AXUIElement) -> CGRect? {
        guard
            let positionValue = copyAttribute("AXPosition", element: element),
            let sizeValue = copyAttribute("AXSize", element: element),
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func clipped(_ value: String) -> String {
        value.count > 180 ? String(value.prefix(180)) + "..." : value
    }

    private func accessibilityFailure() -> ComputerControlResult {
        ComputerControlResult(
            ok: false,
            message: "Accessibility permission is required for AX native app control. Open Settings and click Request Accessibility Permission."
        )
    }

    private func missingElementFailure(_ elementID: String) -> ComputerControlResult {
        ComputerControlResult(
            ok: false,
            message: "Unknown AX element id \(elementID). Run ax_snapshot again and use an element id from the latest snapshot."
        )
    }
}

private extension AXError {
    var readableName: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegal argument"
        case .invalidUIElement: return "invalid UI element"
        case .invalidUIElementObserver: return "invalid UI element observer"
        case .cannotComplete: return "cannot complete"
        case .attributeUnsupported: return "attribute unsupported"
        case .actionUnsupported: return "action unsupported"
        case .notificationUnsupported: return "notification unsupported"
        case .notImplemented: return "not implemented"
        case .notificationAlreadyRegistered: return "notification already registered"
        case .notificationNotRegistered: return "notification not registered"
        case .apiDisabled: return "api disabled"
        case .noValue: return "no value"
        case .parameterizedAttributeUnsupported: return "parameterized attribute unsupported"
        case .notEnoughPrecision: return "not enough precision"
        @unknown default: return "unknown AX error \(rawValue)"
        }
    }
}
