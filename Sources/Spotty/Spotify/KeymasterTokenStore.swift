//
//  KeymasterTokenStore.swift
//  Spotty
//
//  Where the keymaster grant's tokens live between launches.
//

import Foundation

/// Storage for the keymaster tokens.
///
/// A protocol rather than a direct `KeychainManager` call so the rotation policy can be
/// tested without a keychain — the rule that matters (the response's refresh token replaces
/// the stored one) is a property of the *sequence* of refreshes, and a test that cannot
/// observe what was written cannot check it.
nonisolated protocol KeymasterTokenStoring: Sendable {
    func load() -> KeymasterTokens?
    func save(_ tokens: KeymasterTokens) throws
    func clear()
}

/// Privacy-safe persistence diagnostics. Messages name a storage category and a reason;
/// they must never include a token, username, payload, account id, or request data.
enum KeymasterGrantPersistenceDiagnostics {
    static let unreadableGrant = "Stored grant is unreadable source=secure"
}

enum KeymasterStoredGrantCodec {
    static func decode(_ data: Data) -> KeymasterTokens? {
        do {
            return try JSONDecoder().decode(KeymasterTokens.self, from: data)
        } catch {
            SpottyLog.authentication.error(
                "\(KeymasterGrantPersistenceDiagnostics.unreadableGrant, privacy: .public)"
            )
            return nil
        }
    }
}

/// The real store, in the same keychain service the Web API half uses.
nonisolated struct KeymasterKeychainStore: KeymasterTokenStoring {
    private static let retiredDefaultsKey = "keymaster.tokens.v1"

    func load() -> KeymasterTokens? {
        clearRetiredPlaintextGrant()
        return KeychainManager.loadKeymasterTokens()
    }

    func save(_ tokens: KeymasterTokens) throws {
        clearRetiredPlaintextGrant()
        try KeychainManager.saveKeymasterTokens(tokens)
    }

    func clear() {
        clearRetiredPlaintextGrant()
        KeychainManager.clearKeymasterTokens()
    }

    private func clearRetiredPlaintextGrant() {
        UserDefaults.standard.removeObject(forKey: Self.retiredDefaultsKey)
    }
}
