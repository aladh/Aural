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
        check.equal(
            "superseded-repair diagnostic names the category and reason",
            KeymasterGrantPersistenceDiagnostics.supersededPersistRepairFailed,
            "Superseded grant repair failed reason=secure-save"
        )
        check.check(
            "superseded-repair diagnostic omits the payload sentinel",
            !KeymasterGrantPersistenceDiagnostics.supersededPersistRepairFailed.contains(sentinel)
        )
    }

    check.suite("Legacy grant migrates one way into the secure store") {
        let tokens = persistenceGrant(access: "at", refresh: "rt")
        let secure = RecordingTokenStore()
        let legacy = RecordingLegacyStore(tokens: tokens)
        let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)
        let snapshot = store.loadGrant()

        check.equal("legacy success returns the grant", snapshot.tokens?.refreshToken, "rt")
        check.check("legacy success asks the session to persist", snapshot.needsSecurePersist)
        check.nil_("load does not write leftover onto the secure store", secure.stored)
        check.equal("load does not save leftover itself", secure.saveCount, 0)
        check.nil_("legacy success deletes the plaintext copy", legacy.tokens)
    }

    check.suite("Migration save failure still erases plaintext") {
        let tokens = persistenceGrant(access: "at", refresh: "rt")
        let secure = FailingTokenStore()
        let legacy = RecordingLegacyStore(tokens: tokens)
        let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)
        let snapshot = store.loadGrant()

        check.equal(
            "a failed migration still returns the current-session grant",
            snapshot.tokens?.refreshToken,
            "rt"
        )
        check.check("a leftover grant still needs a later secure persist", snapshot.needsSecurePersist)
        check.nil_("a failed migration does not retain plaintext", legacy.tokens)
        check.nil_("load does not invent a secure copy", secure.stored)
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
                containsPersistenceToken(
                    session, "private typealias DefaultKeymasterTokenStore = KeymasterMigratingStore")
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
                "legacy plaintext is deleted without a load-time secure write",
                containsPersistenceToken(store, "legacyStore.clear()")
                    && containsPersistenceToken(store, "needsSecurePersist: true")
                    && containsPersistenceToken(session, "persistLeftoverGrantIfCurrent")
                    && containsPersistenceToken(session, "store.loadGrant()")
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
                "file-based keychain and team-signed development requirements stay explicit",
                !containsPersistenceToken(keychain, "kSecUseDataProtectionKeychain as String")
                    && !containsPersistenceToken(keychain, "[kSecUseDataProtectionKeychain")
                    && !containsPersistenceToken(keychain, "Shared keychain access group")
                    && containsPersistenceToken(keychain, "Self-signed development signatures are build-only")
                    && containsPersistenceToken(keychain, "requires an Apple-issued team signature")
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

    await check.suite("Session leftover load persists only after the generation still owns the slot") {
        let leftover = persistenceGrant(access: "legacy-at", refresh: "legacy-rt")
        let secure = RecordingTokenStore()
        let legacy = RecordingLegacyStore(tokens: leftover)
        let session = KeymasterSession(
            store: KeymasterMigratingStore(secureStore: secure, legacyStore: legacy),
            refresher: { _ in throw KeymasterAuthError.tokenExchangeFailed(500) },
            cookieCleanup: {}
        )
        check.check("leftover plaintext becomes a current grant", await session.hasGrant)
        check.equal("the session commits leftover plaintext securely", secure.stored?.refreshToken, "legacy-rt")
        check.nil_("leftover plaintext is deleted after the committed load", legacy.tokens)
        check.equal("the leftover bearer is live", try? await session.accessToken(), "legacy-at")
    }

    await check.suite("Failed leftover persist keeps the current-session grant") {
        let leftover = persistenceGrant(access: "legacy-at", refresh: "legacy-rt")
        let secure = FailingTokenStore()
        let legacy = RecordingLegacyStore(tokens: leftover)
        let session = KeymasterSession(
            store: KeymasterMigratingStore(secureStore: secure, legacyStore: legacy),
            refresher: { _ in throw KeymasterAuthError.tokenExchangeFailed(500) },
            cookieCleanup: {}
        )
        check.check("a leftover grant still loads for this process", await session.hasGrant)
        check.nil_("failed persist does not retain plaintext", legacy.tokens)
        check.nil_("failed persist does not invent a secure copy", secure.stored)
        check.equal("the leftover bearer stays in the current session", try? await session.accessToken(), "legacy-at")
    }

    await check.suite("Adopt during leftover load wins over the stale read") {
        let leftover = persistenceGrant(access: "legacy-at", refresh: "legacy-rt")
        let secure = GatedLoadTokenStore(initial: nil)
        let legacy = RecordingLegacyStore(tokens: leftover)
        let session = KeymasterSession(
            store: KeymasterMigratingStore(secureStore: secure, legacyStore: legacy),
            refresher: { _ in throw KeymasterAuthError.tokenExchangeFailed(500) },
            cookieCleanup: {}
        )
        let first = Task { try await session.accessToken() }
        await secure.waitUntilLoadEntered()
        do {
            try await session.adopt(persistenceGrant(access: "adopted-access", refresh: "adopted-refresh"))
        } catch {
            check.check("adopt during leftover load succeeds", false)
        }
        secure.releaseLoad()
        check.equal("adopt during leftover load is the live bearer", try? await first.value, "adopted-access")
        check.equal("the leftover snapshot is not persisted", secure.stored?.accessToken, "adopted-access")
        check.nil_("leftover plaintext is still deleted", legacy.tokens)
    }

    await check.suite("Logout during leftover load wins over the stale read") {
        let leftover = persistenceGrant(access: "legacy-at", refresh: "legacy-rt")
        let secure = GatedLoadTokenStore(initial: nil)
        let legacy = RecordingLegacyStore(tokens: leftover)
        let session = KeymasterSession(
            store: KeymasterMigratingStore(secureStore: secure, legacyStore: legacy),
            refresher: { _ in throw KeymasterAuthError.tokenExchangeFailed(500) },
            cookieCleanup: {}
        )
        let first = Task { await session.hasGrant }
        await secure.waitUntilLoadEntered()
        await session.clear()
        secure.releaseLoad()
        check.check("logout during leftover load leaves no grant", await first.value == false)
        check.nil_("logout does not let leftover plaintext persist", secure.stored)
        check.nil_("logout still deletes leftover plaintext", legacy.tokens)
    }

    await check.suite("Adopt during leftover persist repairs a stale secure write") {
        let leftover = persistenceGrant(access: "legacy-at", refresh: "legacy-rt")
        let secure = GatedFirstSaveTokenStore()
        let legacy = RecordingLegacyStore(tokens: leftover)
        let session = KeymasterSession(
            store: KeymasterMigratingStore(secureStore: secure, legacyStore: legacy),
            refresher: { _ in throw KeymasterAuthError.tokenExchangeFailed(500) },
            cookieCleanup: {}
        )
        let first = Task { await session.hasGrant }
        await secure.waitUntilFirstSaveEntered()
        do {
            try await session.adopt(persistenceGrant(access: "adopted-access", refresh: "adopted-refresh"))
        } catch {
            check.check("adopt during leftover persist succeeds", false)
        }
        secure.releaseFirstSave()
        check.check("adopt during leftover persist keeps a grant", await first.value)
        check.equal("the adopted grant is the live bearer", try? await session.accessToken(), "adopted-access")
        check.equal("a stale leftover write does not remain on disk", secure.stored?.accessToken, "adopted-access")
        check.nil_("leftover plaintext is still deleted", legacy.tokens)
    }
}

private func persistenceGrant(
    access: String,
    refresh: String,
    expiresAt: Date = Date().addingTimeInterval(3_600)
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

private final class GatedLoadTokenStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private let gate = DispatchSemaphore(value: 0)

    init(initial: KeymasterTokens?) {
        value = initial
    }

    var stored: KeymasterTokens? {
        lock.withLock { value }
    }

    func load() -> KeymasterTokens? {
        lock.lock()
        let snapshot = value
        let continuation = entered
        entered = nil
        hasEntered = true
        lock.unlock()
        continuation?.resume()
        gate.wait()
        return snapshot
    }

    func save(_ tokens: KeymasterTokens) throws {
        lock.withLock { value = tokens }
    }

    func clear() {
        lock.withLock { value = nil }
    }

    func waitUntilLoadEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasEntered {
                lock.unlock()
                continuation.resume()
            } else {
                entered = continuation
                lock.unlock()
            }
        }
    }

    func releaseLoad() {
        gate.signal()
    }
}

private final class GatedFirstSaveTokenStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?
    private var saves = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private let gate = DispatchSemaphore(value: 0)

    var stored: KeymasterTokens? {
        lock.withLock { value }
    }

    func load() -> KeymasterTokens? {
        lock.withLock { value }
    }

    func save(_ tokens: KeymasterTokens) throws {
        lock.lock()
        saves += 1
        let shouldPark = saves == 1
        if shouldPark {
            hasEntered = true
            let continuation = entered
            entered = nil
            lock.unlock()
            continuation?.resume()
            gate.wait()
            lock.lock()
        }
        value = tokens
        lock.unlock()
    }

    func clear() {
        lock.withLock { value = nil }
    }

    func waitUntilFirstSaveEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasEntered {
                lock.unlock()
                continuation.resume()
            } else {
                entered = continuation
                lock.unlock()
            }
        }
    }

    func releaseFirstSave() {
        gate.signal()
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
