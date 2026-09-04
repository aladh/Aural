import Foundation
import Testing
@testable import SpottyCore

@Suite("Keymaster Persistence")
struct KeymasterPersistenceTests {
    @Test @MainActor
    func testKeymasterPersistence() async {
        let sentinel = "SPOTTY_PRIVACY_SENTINEL_stored-grant_9b2e"
        let payload = Data("{\"access_token\":\"\(sentinel)\"}".utf8)
        #expect(KeymasterStoredGrantCodec.decode(payload) == nil, "corrupt secure blobs fail closed")
        #expect(KeymasterGrantPersistenceDiagnostics.unreadableGrant == "Stored grant is unreadable source=secure")
        #expect(!KeymasterGrantPersistenceDiagnostics.unreadableGrant.contains(sentinel))

        let secure = RecordingTokenStore()
        let session = KeymasterSession(
            store: secure,
            refresher: { refreshToken in
                persistenceGrant(access: "rotated-at", refresh: "rotated-\(refreshToken)")
            },
            cookieCleanup: {}
        )
        do {
            try await session.adopt(
                persistenceGrant(
                    access: "adopted-at",
                    refresh: "adopted-rt",
                    expiresAt: Date(timeIntervalSince1970: 1)
                ))
        } catch {
            Issue.record("adopt saves securely: unexpected error \(error)")
        }
        #expect((try? await session.accessToken(now: Date(timeIntervalSince1970: 1_000))) == "rotated-at")
        #expect(secure.stored?.refreshToken == "rotated-adopted-rt")
        await session.clear()
        #expect(secure.stored == nil)
    }
}

@Suite("Keymaster Persistence Source Contract")
struct KeymasterPersistenceSourceContractTests {
    @Test @MainActor
    func testKeymasterPersistenceSourceContract() {
        do {
            let session = try sourceFile("Spotty/Spotify/KeymasterSession.swift")
            let store = try sourceFile("Spotty/Spotify/KeymasterTokenStore.swift")
            let keychain = try sourceFile("Spotty/Spotify/KeychainManager.swift")
            #expect(session.contains("private typealias DefaultKeymasterTokenStore = KeymasterKeychainStore"))
            #expect(!store.contains("UserDefaults.standard"))
            #expect(keychain.contains("KeymasterStoredGrantCodec.decode(data)"))
            #expect(!keychain.contains("kSecUseDataProtectionKeychain as String"))
            #expect(!keychain.contains("kSecAttrAccessGroup"))
            #expect(keychain.contains("Self-signed development signatures are build-only"))
            #expect(keychain.contains("requires an Apple-issued team signature"))
        } catch {
            Issue.record("token persistence sources are readable: unexpected error \(error)")
        }
    }
}

private func persistenceGrant(access: String, refresh: String, expiresAt: Date = Date().addingTimeInterval(3_600))
    -> KeymasterTokens
{
    KeymasterTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, username: "listener")
}

private final class RecordingTokenStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?
    var stored: KeymasterTokens? { lock.withLock { value } }
    func load() -> KeymasterTokens? { lock.withLock { value } }
    func save(_ tokens: KeymasterTokens) throws { lock.withLock { value = tokens } }
    func clear() { lock.withLock { value = nil } }
}

private func sourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appending(path: "Sources").appending(path: relativePath),
        encoding: .utf8
    )
}
