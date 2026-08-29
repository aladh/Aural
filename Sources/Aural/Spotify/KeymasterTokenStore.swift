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

/// One-way reader for the retired defaults-backed grant. Production code must never write
/// this value; leftover plaintext is deleted after a migration attempt.
nonisolated protocol KeymasterLegacyTokenReading: Sendable {
    func load() -> KeymasterTokens?
    func clear()
}

/// Privacy-safe persistence diagnostics. Messages name a storage category and a reason;
/// they must never include a token, username, payload, account id, or request data.
enum KeymasterGrantPersistenceDiagnostics {
    static func unreadableGrant(source: KeymasterStoredGrantCodec.Source) -> String {
        "Stored grant is unreadable source=\(source.rawValue)"
    }

    static let legacyMigrationSaveFailed = "Legacy grant migration failed reason=secure-save"
}

enum KeymasterStoredGrantCodec {
    enum Source: String, Sendable {
        case secure
        case legacy
    }

    static func decode(_ data: Data, source: Source) -> KeymasterTokens? {
        do {
            return try JSONDecoder().decode(KeymasterTokens.self, from: data)
        } catch {
            AuralLog.authentication.error(
                "\(KeymasterGrantPersistenceDiagnostics.unreadableGrant(source: source), privacy: .public)"
            )
            return nil
        }
    }
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

/// Retired plaintext location used by older locally signed development builds.
nonisolated struct KeymasterLegacyDefaultsStore: KeymasterLegacyTokenReading {
    private let key = "keymaster.tokens.v1"

    func load() -> KeymasterTokens? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return KeymasterStoredGrantCodec.decode(data, source: .legacy)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Secure storage with a one-way migration from the retired defaults-backed store.
///
/// Every build uses Keychain as the writer. A leftover `keymaster.tokens.v1` value is
/// read once, offered to the secure store, and then deleted even if that write fails so
/// the rotating refresh token is not deliberately kept in plaintext. A successful decode
/// still returns the grant for the current process; a corrupt blob fails closed after a
/// sanitized diagnostic rather than presenting as a silent sign-out.
nonisolated struct KeymasterMigratingStore: KeymasterTokenStoring {
    private let secureStore: any KeymasterTokenStoring
    private let legacyStore: any KeymasterLegacyTokenReading

    init(
        secureStore: any KeymasterTokenStoring = KeymasterKeychainStore(),
        legacyStore: any KeymasterLegacyTokenReading = KeymasterLegacyDefaultsStore()
    ) {
        self.secureStore = secureStore
        self.legacyStore = legacyStore
    }

    func load() -> KeymasterTokens? {
        if let tokens = secureStore.load() {
            legacyStore.clear()
            return tokens
        }
        guard let tokens = legacyStore.load() else { return nil }

        do {
            try secureStore.save(tokens)
        } catch {
            AuralLog.authentication.error(
                "\(KeymasterGrantPersistenceDiagnostics.legacyMigrationSaveFailed, privacy: .public)"
            )
        }
        legacyStore.clear()
        return tokens
    }

    func save(_ tokens: KeymasterTokens) throws {
        defer { legacyStore.clear() }
        try secureStore.save(tokens)
    }

    func clear() {
        secureStore.clear()
        legacyStore.clear()
    }
}
