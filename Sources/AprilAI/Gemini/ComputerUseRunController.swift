import Foundation

@MainActor
final class ComputerUseRunController {
    private var pendingDirective = ""
    private var stopRequested = false

    func steer(_ directive: String) {
        let trimmed = directive.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingDirective = trimmed
    }

    func requestStop(reason: String) {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        stopRequested = true
        if !trimmed.isEmpty {
            pendingDirective = trimmed
        }
    }

    func consumeDirective() -> String? {
        let directive = pendingDirective.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingDirective = ""
        return directive.isEmpty ? nil : directive
    }

    var shouldStop: Bool {
        stopRequested
    }
}
