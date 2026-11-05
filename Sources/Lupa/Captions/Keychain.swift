import Foundation
import Security

// A chave da OpenAI fica no chaveiro de início de sessão, nunca nos UserDefaults.
enum Keychain {
    private static let service = "io.github.paulofroes.lupa"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        delete(account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Lupa: chave da OpenAI",
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum OpenAIKey {
    private static let account = "openai-api-key"

    // Lida do chaveiro uma vez por abertura da Lupa: o painel de gravação e o revisor consultam
    // a chave toda hora, e cada leitura podia fazer o macOS pedir a senha de novo.
    private static var cached: String??

    static var value: String? {
        if let cached { return cached }
        let key = Keychain.read(account)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = key?.isEmpty == false ? key : nil
        cached = .some(result)
        return result
    }

    static var isSet: Bool { value != nil }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account)
            cached = .some(nil)
            return true
        }
        let saved = Keychain.save(trimmed, for: account)
        if saved { cached = .some(trimmed) }
        return saved
    }

    // Mostra só o começo e o fim, para conferir qual chave está salva sem expô-la.
    static var masked: String? {
        guard let key = value else { return nil }
        guard key.count > 12 else { return "••••" }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }
}
