import Foundation
import Security

// Leitura e remoção do item antigo da chave da OpenAI no chaveiro (antes de ela ir para o arquivo).
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

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// Escolha do Paulo (2026-11-05): a chave não pede senha nunca. No chaveiro isso não se sustenta
// com a assinatura local (cada instalação muda o cdhash, que fica na partição do item), então ela
// vai para um arquivo só do usuário (0600) em Application Support. O item antigo do chaveiro é
// lido uma última vez, copiado para o arquivo e apagado.
enum OpenAIKey {
    private static let account = "openai-api-key"
    private static var cached: String??

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lupa", isDirectory: true)
            .appendingPathComponent("openai-key")
    }

    static var value: String? {
        if let cached { return cached }
        var result = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if result?.isEmpty != false, let old = Keychain.read(account)?.trimmingCharacters(in: .whitespacesAndNewlines), !old.isEmpty {
            if write(old) { Keychain.delete(account) }
            result = old
        }
        let key = result?.isEmpty == false ? result : nil
        cached = .some(key)
        return key
    }

    static var isSet: Bool { value != nil }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: file)
            Keychain.delete(account)
            cached = .some(nil)
            return true
        }
        let saved = write(trimmed)
        if saved { cached = .some(trimmed) }
        return saved
    }

    private static func write(_ key: String) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: file.path) {
                manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try Data(key.utf8).write(to: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            NSLog("Lupa legenda: não gravou a chave: %@", error.localizedDescription)
            return false
        }
    }

    // Mostra só o começo e o fim, para conferir qual chave está salva sem expô-la.
    static var masked: String? {
        guard let key = value else { return nil }
        guard key.count > 12 else { return "••••" }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }
}
