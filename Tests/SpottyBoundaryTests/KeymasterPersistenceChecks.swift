import Testing
import Foundation
@testable import SpottyCore

@Suite("Keymaster Persistence")
struct KeymasterPersistenceTests {
    @Test
    @MainActor
    func testKeymasterPersistence() {
        do {
            let currentSuite = "dev.spotty.tests.current.\(UUID().uuidString)"
            let previousSuite = "dev.spotty.tests.previous.\(UUID().uuidString)"
            let current = UserDefaults(suiteName: currentSuite)!
            let previous = UserDefaults(suiteName: previousSuite)!
            defer {
                current.removePersistentDomain(forName: currentSuite)
                previous.removePersistentDomain(forName: previousSuite)
            }
            previous.set("migrated", forKey: "copied")
            previous.set("stale", forKey: "preserved")
            current.set("current", forKey: "preserved")

            PreviousInstallationIdentity.migrateDefaults(
                keys: ["copied", "preserved"],
                current: current,
                previous: previous
            )

            #expect((current.string(forKey: "copied")) == ("migrated"), "missing current value is copied")
            #expect((current.string(forKey: "preserved")) == ("current"), "current value wins")
            #expect((previous.object(forKey: "copied")) == nil, "copied previous value is removed")
            #expect((previous.object(forKey: "preserved")) == nil, "superseded previous value is removed")
        }

        do {
            let current = persistenceGrant(access: "current", refresh: "current-refresh")
            let previous = persistenceGrant(access: "previous", refresh: "previous-refresh")
            let currentData = try! JSONEncoder().encode(current)
            let previousData = try! JSONEncoder().encode(previous)
            var previousLoadCount = 0
            var currentSaveCount = 0
            var retirementCount = 0

            let loaded = KeychainManager.loadKeymasterTokensForMigration(
                loadCurrent: { currentData },
                loadPrevious: {
                    previousLoadCount += 1
                    return previousData
                },
                saveCurrent: { _ in currentSaveCount += 1 },
                previousIsRetired: { false },
                retirePrevious: { retirementCount += 1 }
            )

            #expect((loaded?.refreshToken) == ("current-refresh"), "current grant wins")
            #expect((previousLoadCount) == (0), "previous grant is not loaded")
            #expect((currentSaveCount) == (0), "current grant is not rewritten")
            #expect((retirementCount) == (1), "previous service is retired")
        }

        do {
            let previous = persistenceGrant(access: "previous", refresh: "previous-refresh")
            let previousData = try! JSONEncoder().encode(previous)
            var previousLoadCount = 0
            var retirementCount = 0

            let retiredLoad = KeychainManager.loadKeymasterTokensForMigration(
                loadCurrent: { nil },
                loadPrevious: {
                    previousLoadCount += 1
                    return previousData
                },
                saveCurrent: { _ in },
                previousIsRetired: { true },
                retirePrevious: { retirementCount += 1 }
            )
            #expect((retiredLoad) == nil, "retired previous grant cannot return")
            #expect((previousLoadCount) == (0), "retired previous service is not read")

            let corruptLoad = KeychainManager.loadKeymasterTokensForMigration(
                loadCurrent: { nil },
                loadPrevious: { Data("not-json".utf8) },
                saveCurrent: { _ in },
                previousIsRetired: { false },
                retirePrevious: { retirementCount += 1 }
            )
            #expect((corruptLoad) == nil, "corrupt previous grant fails closed")
            #expect((retirementCount) == (1), "corrupt previous service is retired")

            let failedSaveLoad = KeychainManager.loadKeymasterTokensForMigration(
                loadCurrent: { nil },
                loadPrevious: { previousData },
                saveCurrent: { _ in throw KeychainError.saveFailed(-1) },
                previousIsRetired: { false },
                retirePrevious: { retirementCount += 1 }
            )
            #expect(
                (failedSaveLoad?.refreshToken) == ("previous-refresh"),
                "failed migration still returns the current-session grant")
            #expect((retirementCount) == (1), "failed migration preserves the retry path")
        }

        do {
            let sentinel = "SPOTTY_PRIVACY_SENTINEL_stored-grant_9b2e"
            let payload = Data(
                "{\"access_token\":\"\(sentinel)\",\"refresh_token\":\"\(sentinel)\",\"username\":\"\(sentinel)\"}"
                    .utf8
            )
            #expect(
                (KeymasterStoredGrantCodec.decode(payload, source: .secure)) == nil, "corrupt secure blobs fail closed")
            #expect(
                (KeymasterStoredGrantCodec.decode(payload, source: .legacy)) == nil, "corrupt legacy blobs fail closed")

            let secure = KeymasterGrantPersistenceDiagnostics.unreadableGrant(source: .secure)
            let legacy = KeymasterGrantPersistenceDiagnostics.unreadableGrant(source: .legacy)
            #expect(
                (secure) == ("Stored grant is unreadable source=secure"), "secure decode names the category and reason")
            #expect(
                (legacy) == ("Stored grant is unreadable source=legacy"), "legacy decode names the category and reason")
            #expect((!secure.contains(sentinel)) == true, "secure diagnostic omits the payload sentinel")
            #expect((!legacy.contains(sentinel)) == true, "legacy diagnostic omits the payload sentinel")
            #expect(
                (KeymasterGrantPersistenceDiagnostics.legacyMigrationSaveFailed
                    == "Legacy grant migration failed reason=secure-save") == true,
                "migration-failure diagnostic is a fixed category and reason")
            #expect(
                (!KeymasterGrantPersistenceDiagnostics.legacyMigrationSaveFailed.contains(sentinel)) == true,
                "migration-failure diagnostic omits the payload sentinel")
            #expect(
                (KeymasterGrantPersistenceDiagnostics.supersededPersistRepairFailed)
                    == ("Superseded grant repair failed reason=secure-save"),
                "superseded-repair diagnostic names the category and reason")
            #expect(
                (!KeymasterGrantPersistenceDiagnostics.supersededPersistRepairFailed.contains(sentinel)) == true,
                "superseded-repair diagnostic omits the payload sentinel")
        }

        do {
            let tokens = persistenceGrant(access: "at", refresh: "rt")
            let secure = RecordingTokenStore()
            let legacy = RecordingLegacyStore(tokens: tokens)
            let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)
            let snapshot = store.loadGrant()

            #expect((snapshot.tokens?.refreshToken) == ("rt"), "legacy success returns the grant")
            #expect((snapshot.needsSecurePersist) == true, "legacy success asks the session to persist")
            #expect((secure.stored) == nil, "load does not write leftover onto the secure store")
            #expect((secure.saveCount) == (0), "load does not save leftover itself")
            #expect((legacy.tokens) == nil, "legacy success deletes the plaintext copy")
        }

        do {
            let tokens = persistenceGrant(access: "at", refresh: "rt")
            let secure = FailingTokenStore()
            let legacy = RecordingLegacyStore(tokens: tokens)
            let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)
            let snapshot = store.loadGrant()

            #expect(
                (snapshot.tokens?.refreshToken) == ("rt"), "a failed migration still returns the current-session grant")
            #expect((snapshot.needsSecurePersist) == true, "a leftover grant still needs a later secure persist")
            #expect((legacy.tokens) == nil, "a failed migration does not retain plaintext")
            #expect((secure.stored) == nil, "load does not invent a secure copy")
        }

        do {
            let secure = RecordingTokenStore()
            let legacy = UnreadableLegacyStore()
            let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)

            #expect((store.load()) == nil, "corrupt leftover plaintext fails closed")
            #expect((!legacy.retained) == true, "corrupt leftover plaintext is still deleted")
            #expect((secure.stored) == nil, "corrupt leftover plaintext is not copied securely")
        }

        do {
            let secure = RecordingTokenStore()
            let legacy = RecordingLegacyStore(tokens: persistenceGrant(access: "old", refresh: "old-rt"))
            let store = KeymasterMigratingStore(secureStore: secure, legacyStore: legacy)
            let adopted = persistenceGrant(access: "adopted", refresh: "adopted-rt")

            do {
                do {
                    try store.save(adopted)

                } catch {
                    Issue.record("\("adopt saves securely"): unexpected error \(error)")
                }
            }
            #expect((secure.stored?.refreshToken) == ("adopted-rt"), "adopt writes the secure grant")
            #expect((legacy.tokens) == nil, "adopt clears leftover plaintext")

            let rotated = persistenceGrant(access: "rotated", refresh: "rotated-rt")
            do {
                do {
                    try store.save(rotated)

                } catch {
                    Issue.record("\("refresh saves securely"): unexpected error \(error)")
                }
            }
            #expect((secure.stored?.refreshToken) == ("rotated-rt"), "refresh replaces the secure grant")
            #expect((legacy.tokens) == nil, "refresh does not restore plaintext")

            store.clear()
            #expect((secure.stored) == nil, "clear removes the secure grant")
            #expect((legacy.tokens) == nil, "clear removes the leftover plaintext")
        }
    }
}

@Suite("Keymaster Persistence Source Contract")
struct KeymasterPersistenceSourceContractTests {
    @Test
    @MainActor
    func testKeymasterPersistenceSourceContract() {
        do {
            do {
                do {
                    let session = try spottyPersistenceSourceFile("Spotty/Spotify/KeymasterSession.swift")
                    let store = try spottyPersistenceSourceFile("Spotty/Spotify/KeymasterTokenStore.swift")
                    let keychain = try spottyPersistenceSourceFile("Spotty/Spotify/KeychainManager.swift")

                    #expect(
                        (containsPersistenceToken(
                            session, "private typealias DefaultKeymasterTokenStore = KeymasterMigratingStore")
                            && !containsPersistenceToken(session, "SPOTTY_DISTRIBUTION")
                            && !containsPersistenceToken(session, "KeymasterDefaultsStore")
                            && !containsPersistenceToken(session, "KeymasterLegacyDefaultsStore")) == true,
                        "every compilation uses the migrating secure store")
                    #expect(
                        (!containsPersistenceToken(store, "UserDefaults.standard.set")
                            && !containsPersistenceToken(store, "legacyStore.save")
                            && containsPersistenceToken(store, "UserDefaults.standard.data(forKey: Self.storageKey)")
                            && containsPersistenceToken(
                                store, "UserDefaults.standard.removeObject(forKey: Self.storageKey)"))
                            == true, "production code has no UserDefaults save path for the grant")
                    #expect(
                        (containsPersistenceToken(store, "legacyStore.clear()")
                            && containsPersistenceToken(store, "needsSecurePersist: true")
                            && containsPersistenceToken(session, "persistLeftoverGrantIfCurrent")
                            && containsPersistenceToken(session, "store.loadGrant()")) == true,
                        "legacy plaintext is deleted without a load-time secure write")
                    #expect(
                        (containsPersistenceToken(store, "KeymasterStoredGrantCodec.decode(data, source: .legacy)")
                            && containsPersistenceToken(
                                keychain, "KeymasterStoredGrantCodec.decode(data, source: .secure)")
                            && containsPersistenceToken(store, "Stored grant is unreadable source=")
                            && !containsPersistenceToken(store, "error.localizedDescription")
                            && !containsPersistenceToken(keychain, "try? JSONDecoder().decode(KeymasterTokens.self"))
                            == true, "corrupt stored grants decode through the sanitized codec")
                    #expect(
                        (!containsPersistenceToken(keychain, "kSecUseDataProtectionKeychain as String")
                            && !containsPersistenceToken(keychain, "[kSecUseDataProtectionKeychain")
                            && !containsPersistenceToken(keychain, "kSecAttrAccessGroup")
                            && !containsPersistenceToken(keychain, "Shared keychain access group")
                            && containsPersistenceToken(keychain, "Self-signed development signatures are build-only")
                            && containsPersistenceToken(keychain, "requires an Apple-issued team signature")) == true,
                        "file-based keychain and team-signed development requirements stay explicit")
                    #expect(
                        (containsPersistenceToken(
                            keychain,
                            "UserDefaults.standard.set(true, forKey: previousServiceRetiredKey)"
                        )
                            && containsPersistenceToken(keychain, "guard !previousIsRetired()")
                            && containsPersistenceToken(keychain, "retirePreviousKeymasterService()")) == true,
                        "previous-service retirement is durable rather than delete-only")

                } catch {
                    Issue.record("\("token persistence sources are readable"): unexpected error \(error)")
                }
            }
        }
    }
}

@Suite("Keymaster Session Persistence")
struct KeymasterSessionPersistenceTests {
    @Test
    @MainActor
    func testKeymasterSessionPersistence() async {
        do {
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
                #expect((true) == true, "adopt writes the grant")
            } catch {
                #expect((false) == true, "adopt writes the grant")
            }
            #expect((secure.stored?.refreshToken) == ("adopted-rt"), "adopt persists to the secure store")
            #expect((legacy.tokens) == nil, "adopt clears leftover plaintext")

            let expired = persistenceGrant(
                access: "adopted-at",
                refresh: "adopted-rt",
                expiresAt: Date(timeIntervalSince1970: 1)
            )
            do {
                try await session.adopt(expired)
            } catch {
                #expect((false) == true, "re-adopt of an expired grant succeeds")
            }
            #expect(
                (try? await session.accessToken(now: Date(timeIntervalSince1970: 1_000))) == ("rotated-at"),
                "refresh persists the rotated grant securely")
            #expect((secure.stored?.refreshToken) == ("rotated-adopted-rt"), "refresh replaces the secure grant")
            #expect((legacy.tokens) == nil, "refresh does not restore plaintext")

            await session.clear()
            #expect((secure.stored) == nil, "clear removes the secure grant")
            #expect((legacy.tokens) == nil, "clear removes leftover plaintext")
        }

        do {
            let leftover = persistenceGrant(access: "legacy-at", refresh: "legacy-rt")
            let secure = RecordingTokenStore()
            let legacy = RecordingLegacyStore(tokens: leftover)
            let session = KeymasterSession(
                store: KeymasterMigratingStore(secureStore: secure, legacyStore: legacy),
                refresher: { _ in throw KeymasterAuthError.tokenExchangeFailed(500) },
                cookieCleanup: {}
            )
            #expect((await session.hasGrant) == true, "leftover plaintext becomes a current grant")
            #expect((secure.stored?.refreshToken) == ("legacy-rt"), "the session commits leftover plaintext securely")
            #expect((legacy.tokens) == nil, "leftover plaintext is deleted after the committed load")
            #expect((try? await session.accessToken()) == ("legacy-at"), "the leftover bearer is live")
        }

        do {
            let leftover = persistenceGrant(access: "legacy-at", refresh: "legacy-rt")
            let secure = FailingTokenStore()
            let legacy = RecordingLegacyStore(tokens: leftover)
            let session = KeymasterSession(
                store: KeymasterMigratingStore(secureStore: secure, legacyStore: legacy),
                refresher: { _ in throw KeymasterAuthError.tokenExchangeFailed(500) },
                cookieCleanup: {}
            )
            #expect((await session.hasGrant) == true, "a leftover grant still loads for this process")
            #expect((legacy.tokens) == nil, "failed persist does not retain plaintext")
            #expect((secure.stored) == nil, "failed persist does not invent a secure copy")
            #expect(
                (try? await session.accessToken()) == ("legacy-at"), "the leftover bearer stays in the current session")
        }

        do {
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
                #expect((false) == true, "adopt during leftover load succeeds")
            }
            secure.releaseLoad()
            #expect((try? await first.value) == ("adopted-access"), "adopt during leftover load is the live bearer")
            #expect((secure.stored?.accessToken) == ("adopted-access"), "the leftover snapshot is not persisted")
            #expect((legacy.tokens) == nil, "leftover plaintext is still deleted")
        }

        do {
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
            #expect((await first.value == false) == true, "logout during leftover load leaves no grant")
            #expect((secure.stored) == nil, "logout does not let leftover plaintext persist")
            #expect((legacy.tokens) == nil, "logout still deletes leftover plaintext")
        }

        do {
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
                #expect((false) == true, "adopt during leftover persist succeeds")
            }
            secure.releaseFirstSave()
            #expect((await first.value) == true, "adopt during leftover persist keeps a grant")
            #expect((try? await session.accessToken()) == ("adopted-access"), "the adopted grant is the live bearer")
            #expect(
                (secure.stored?.accessToken) == ("adopted-access"), "a stale leftover write does not remain on disk")
            #expect((legacy.tokens) == nil, "leftover plaintext is still deleted")
        }
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

private func spottyPersistenceSourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let url = repositoryRoot.appending(path: "Sources").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func containsPersistenceToken(_ source: String, _ token: String) -> Bool {
    source.contains(token)
}
