import Foundation
import Security

final class KeychainStore {
    private let service = "AprilAI.GeminiAPIKey"
    private let localService = "AprilAI.LocalModelAPIKey"
    private let cartesiaService = "AprilAI.CartesiaAPIKey"
    private let legacyService = "PolymathAssistant.GeminiAPIKey"
    private let account = "default"

    func readAPIKey() -> String {
        let current = readAPIKey(service: service)
        if !current.isEmpty {
            return current
        }

        let legacy = readAPIKey(service: legacyService)
        if !legacy.isEmpty {
            try? saveAPIKey(legacy)
        }
        return legacy
    }

    private func readAPIKey(service: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func saveAPIKey(_ key: String) throws {
        try save(key, service: service)
    }

    func readLocalAPIKey() -> String {
        readAPIKey(service: localService)
    }

    func saveLocalAPIKey(_ key: String) throws {
        try save(key, service: localService)
    }

    func readCartesiaAPIKey() -> String {
        readAPIKey(service: cartesiaService)
    }

    func saveCartesiaAPIKey(_ key: String) throws {
        try save(key, service: cartesiaService)
    }

    private func save(_ key: String, service: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }
}
