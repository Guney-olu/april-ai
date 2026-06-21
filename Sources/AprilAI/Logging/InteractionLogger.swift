import Foundation

@MainActor
final class InteractionLogger {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let dateFormatter = ISO8601DateFormatter()
    private let fileManager = FileManager.default

    init(logsURL: URL) throws {
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        fileURL = logsURL.appending(path: "\(formatter.string(from: Date()))-session.jsonl")
        encoder.outputFormatting = [.sortedKeys]
        log("session_start", [
            "log_file": fileURL.path,
            "app": "April AI"
        ])
    }

    var path: String {
        fileURL.path
    }

    func log(_ event: String, _ payload: [String: Any] = [:]) {
        var object = (sanitize(payload) as? [String: Any]) ?? [:]
        object["event"] = event
        object["timestamp"] = dateFormatter.string(from: Date())

        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else {
            return
        }

        append(line + "\n")
    }

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if !fileManager.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
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
            return clipped(string)
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

    private func clipped(_ string: String) -> String {
        string.count > 5_000 ? String(string.prefix(5_000)) + "...[truncated]" : string
    }
}
