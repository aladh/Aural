import Foundation
@testable import AuralCore

@MainActor
func runKeymasterPersistenceChecks(_ check: CheckRunner) {
    check.suite("Corrupt stored-grant decoding stays sanitized") {
        let sentinel = "AURAL_PRIVACY_SENTINEL_stored-grant_9b2e"
        let payload = Data(
            "{\"access_token\":\"\(sentinel)\",\"refresh_token\":\"\(sentinel)\",\"username\":\"\(sentinel)\"}"
                .utf8
        )
        check.nil_(
            "corrupt secure blobs fail closed",
            KeymasterStoredGrantCodec.decode(payload, source: .secure)
        )
        check.nil_(
            "corrupt legacy blobs fail closed",
            KeymasterStoredGrantCodec.decode(payload, source: .legacy)
        )

        let secure = KeymasterGrantPersistenceDiagnostics.unreadableGrant(source: .secure)
        let legacy = KeymasterGrantPersistenceDiagnostics.unreadableGrant(source: .legacy)
        check.equal("secure decode names the category and reason", secure, "Stored grant is unreadable source=secure")
        check.equal("legacy decode names the category and reason", legacy, "Stored grant is unreadable source=legacy")
        check.check("secure diagnostic omits the payload sentinel", !secure.contains(sentinel))
        check.check("legacy diagnostic omits the payload sentinel", !legacy.contains(sentinel))
        check.check(
            "migration-failure diagnostic is a fixed category and reason",
            KeymasterGrantPersistenceDiagnostics.legacyMigrationSaveFailed
                == "Legacy grant migration failed reason=secure-save"
        )
        check.check(
            "migration-failure diagnostic omits the payload sentinel",
            !KeymasterGrantPersistenceDiagnostics.legacyMigrationSaveFailed.contains(sentinel)
        )
    }

    check.suite("Legacy grant migrates one way into the secure store") {
        let tokens = persistenceGrant(access: "at", refresh: "rt")
        let secure = RecordingTokenStore()
        let legacy = RecordingLegacyStore(tokens: tokens)
        let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)

        check.equal("legacy success returns the grant", store.load()?.refreshToken, "rt")
        check.equal("legacy success writes the grant securely", secure.stored?.refreshToken, "rt")
        check.equal("legacy success is a single secure save", secure.saveCount, 1)
        check.nil_("legacy success deletes the plaintext copy", legacy.tokens)
    }

    check.suite("Migration save failure still erases plaintext") {
        let tokens = persistenceGrant(access: "at", refresh: "rt")
        let secure = FailingTokenStore()
        let legacy = RecordingLegacyStore(tokens: tokens)
        let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)

        check.equal(
            "a failed migration still returns the current-session grant",
            store.load()?.refreshToken,
            "rt"
        )
        check.nil_("a failed migration does not retain plaintext", legacy.tokens)
        check.nil_("a failed migration does not invent a secure copy", secure.stored)
    }

    check.suite("Unreadable leftover plaintext is still erased") {
        let secure = RecordingTokenStore()
        let legacy = UnreadableLegacyStore()
        let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)

        check.nil_("corrupt leftover plaintext fails closed", store.load())
        check.check("corrupt leftover plaintext is still deleted", !legacy.retained)
        check.nil_("corrupt leftover plaintext is not copied securely", secure.stored)
    }

    check.suite("Adopt, refresh, and clear persist only to the secure store") {
        let secure = RecordingTokenStore()
        let legacy = RecordingLegacyStore(tokens: persistenceGrant(access: "old", refresh: "old-rt"))
        let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)
        let adopted = persistenceGrant(access: "adopted", refresh: "adopted-rt")

        check.noThrow("adopt saves securely") {
            try store.save(adopted)
        }
        check.equal("adopt writes the secure grant", secure.stored?.refreshToken, "adopted-rt")
        check.nil_("adopt clears leftover plaintext", legacy.tokens)

        let rotated = persistenceGrant(access: "rotated", refresh: "rotated-rt")
        check.noThrow("refresh saves securely") {
            try store.save(rotated)
        }
        check.equal("refresh replaces the secure grant", secure.stored?.refreshToken, "rotated-rt")
        check.nil_("refresh does not restore plaintext", legacy.tokens)

        store.clear()
        check.nil_("clear removes the secure grant", secure.stored)
        check.nil_("clear removes the leftover plaintext", legacy.tokens)
    }
}

@MainActor
func runKeymasterPersistenceSourceContractChecks(_ check: CheckRunner) {
    check.suite("Keymaster persistence source contract") {
        check.noThrow("token persistence sources are readable") {
            let session = try auralPersistenceSourceFile("Aural/Spotify/KeymasterSession.swift")
            let store = try auralPersistenceSourceFile("Aural/Spotify/KeymasterTokenStore.swift")
            let keychain = try auralPersistenceSourceFile("Aural/Spotify/KeychainManager.swift")

            check.check(
                "every compilation uses the migrating secure store",
                containsPersistenceToken(session, "private typealias DefaultKeymasterTokenStore = KeymasterMigratingStore")
                    && !containsPersistenceToken(session, "AURAL_DISTRIBUTION")
                    && !containsPersistenceToken(session, "KeymasterDefaultsStore")
                    && !containsPersistenceToken(session, "KeymasterLegacyDefaultsStore")
            )
            check.check(
                "production code has no UserDefaults save path for the grant",
                !containsPersistenceToken(store, "UserDefaults.standard.set")
                    && !containsPersistenceToken(store, "legacyStore.save")
                    && containsPersistenceToken(store, "UserDefaults.standard.data(forKey: key)")
                    && containsPersistenceToken(store, "UserDefaults.standard.removeObject(forKey: key)")
            )
            check.check(
                "legacy plaintext is deleted after a migration attempt even when save fails",
                containsPersistenceToken(store, "legacyStore.clear()")
                    && containsPersistenceToken(store, "defer { legacyStore.clear() }")
                    && containsPersistenceToken(store, "guard let tokens = legacyStore.load() else { return nil }")
                    && containsPersistenceToken(store, KeymasterGrantPersistenceDiagnostics.legacyMigrationSaveFailed)
            )
            check.check(
                "corrupt stored grants decode through the sanitized codec",
                containsPersistenceToken(store, "KeymasterStoredGrantCodec.decode(data, source: .legacy)")
                    && containsPersistenceToken(keychain, "KeymasterStoredGrantCodec.decode(data, source: .secure)")
                    && containsPersistenceToken(store, "Stored grant is unreadable source=")
                    && !containsPersistenceToken(store, "error.localizedDescription")
                    && !containsPersistenceToken(keychain, "try? JSONDecoder().decode(KeymasterTokens.self")
            )
            check.check(
                "data-protection keychain is not selected and the stale access-group comment is gone",
                !containsPersistenceToken(keychain, "kSecUseDataProtectionKeychain")
                    && !containsPersistenceToken(keychain, "Shared keychain access group")
                    && containsPersistenceToken(keychain, "errSecMissingEntitlement")
            )
        }
    }
}

@MainActor
func runKeymasterSessionPersistenceChecks(_ check: CheckRunner) async {
    await check.suite("Session adopt and refresh save through the migrating store") {
        let secure = RecordingTokenStore()
        let leftover = persistenceGrant(access: "legacy-at", refresh: "legacy-rt")
        let legacy = RecordingLegacyStore(tokens: leftover)
        let session = KeymasterSession(
            store: KeymasterMigratingStore(secureStore: secure, legacyStore: legacy),
            refresher: { refreshToken in
                persistenceGrant(access: "rotated-at", refresh: "rotated-\(refreshToken)")
            },
            cookieCleanup: {}
        )
        let adopted = persistenceGrant(access: "adopted-at", refresh: "adopted-rt")
        do {
            try await session.adopt(adopted)
            check.check("adopt writes the grant", true)
        } catch {
            check.check("adopt writes the grant", false)
        }
        check.equal("adopt persists to the secure store", secure.stored?.refreshToken, "adopted-rt")
        check.nil_("adopt clears leftover plaintext", legacy.tokens)

        let expired = persistenceGrant(
            access: "adopted-at",
            refresh: "adopted-rt",
            expiresAt: Date(timeIntervalSince1970: 1)
        )
        do {
            try await session.adopt(expired)
        } catch {
            check.check("re-adopt of an expired grant succeeds", false)
        }
        check.equal(
            "refresh persists the rotated grant securely",
            try? await session.accessToken(now: Date(timeIntervalSince1970: 1_000)),
            "rotated-at"
        )
        check.equal("refresh replaces the secure grant", secure.stored?.refreshToken, "rotated-adopted-rt")
        check.nil_("refresh does not restore plaintext", legacy.tokens)

        await session.clear()
        check.nil_("clear removes the secure grant", secure.stored)
        check.nil_("clear removes leftover plaintext", legacy.tokens)
    }
}

private func persistenceGrant(
    access: String,
    refresh: String,
    expiresAt: Date = Date(timeIntervalSince1970: 2_000_000)
) -> KeymasterTokens {
    KeymasterTokens(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: expiresAt,
        username: "listener"
    )
}

private final class RecordingTokenStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?
    private(set) var saveCount = 0

    var stored: KeymasterTokens? {
        lock.withLock { value }
    }

    func load() -> KeymasterTokens? {
        lock.withLock { value }
    }

    func save(_ tokens: KeymasterTokens) throws {
        lock.lock()
        value = tokens
        saveCount += 1
        lock.unlock()
    }

    func clear() {
        lock.withLock { value = nil }
    }
}

private final class FailingTokenStore: KeymasterTokenStoring, @unchecked Sendable {
    var stored: KeymasterTokens? { nil }

    func load() -> KeymasterTokens? { nil }

    func save(_: KeymasterTokens) throws {
        throw KeychainError.saveFailed(-1)
    }

    func clear() {}
}

private final class UnreadableLegacyStore: KeymasterLegacyTokenReading, @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    var retained: Bool {
        lock.withLock { value }
    }

    func load() -> KeymasterTokens? { nil }

    func clear() {
        lock.withLock { value = false }
    }
}

private final class RecordingLegacyStore: KeymasterLegacyTokenReading, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?

    init(tokens: KeymasterTokens?) {
        value = tokens
    }

    var tokens: KeymasterTokens? {
        lock.withLock { value }
    }

    func load() -> KeymasterTokens? {
        lock.withLock { value }
    }

    func clear() {
        lock.withLock { value = nil }
    }
}

private func auralPersistenceSourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sources = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let url = sources.appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func containsPersistenceToken(_ source: String, _ token: String) -> Bool {
    source.contains(token)
}
