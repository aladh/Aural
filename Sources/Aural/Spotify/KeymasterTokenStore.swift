//
//  KeymasterTokenStore.swift
//  Aural
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

/// The real store, in the same keychain service the Web API half uses.
nonisolated struct KeymasterKeychainStore: KeymasterTokenStoring {
    func load() -> KeymasterTokens? {
        KeychainManager.loadKeymasterTokens()
    }

    func save(_ tokens: KeymasterTokens) throws {
        try KeychainManager.saveKeymasterTokens(tokens)
    }

    func clear() {
        KeychainManager.clearKeymasterTokens()
    }
}

/// Stable storage for locally signed development builds, whose changing executable ACL cannot
/// reliably reuse a Keychain item. Distribution builds migrate this legacy value into Keychain.
nonisolated struct KeymasterDefaultsStore: KeymasterTokenStoring {
    private let key = "keymaster.tokens.v1"

    func load() -> KeymasterTokens? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeymasterTokens.self, from: data)
    }

    func save(_ tokens: KeymasterTokens) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(tokens), forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Secure production storage with a one-way migration from the legacy defaults-backed store.
///
/// The legacy value is deleted only after Keychain accepts the same grant. If Keychain is
/// temporarily unavailable, the current session can still recover and a later save retries the
/// migration rather than discarding a valid rotating refresh token.
nonisolated struct KeymasterMigratingStore: KeymasterTokenStoring {
    private let secureStore = KeymasterKeychainStore()
    private let legacyStore = KeymasterDefaultsStore()

    func load() -> KeymasterTokens? {
        if let tokens = secureStore.load() {
            legacyStore.clear()
            return tokens
        }
        guard let tokens = legacyStore.load() else { return nil }

        do {
            try secureStore.save(tokens)
            legacyStore.clear()
        } catch {
            // Keep the legacy copy until a secure write succeeds; losing a rotating refresh
            // token here would force an otherwise unnecessary sign-in.
        }
        return tokens
    }

    func save(_ tokens: KeymasterTokens) throws {
        try secureStore.save(tokens)
        legacyStore.clear()
    }

    func clear() {
        secureStore.clear()
        legacyStore.clear()
    }
}
