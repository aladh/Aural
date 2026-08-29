import Foundation
@testable import AuralCore

@MainActor
func runAuthCredentialRetryChecks(_ check: CheckRunner) async {
    await check.suite("Rejected bearer forces refresh while still valid") {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: {}
        )
        let current = grant(access: "access-a", refresh: "refresh-a")
        let renewed = grant(access: "access-b", refresh: "refresh-b")
        try? await session.adopt(current)

        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        check.equal("clock-valid refusal spends the refresh token once", refresher.attemptCount, 1)
        check.equal("the spent refresh token is the current grant's", refresher.spent, ["refresh-a"])
        refresher.complete(renewed)

        let token = try? await pending.value
        check.equal("forced refresh returns the replacement bearer", token, "access-b")
        check.equal("the replacement grant is persisted", store.stored?.refreshToken, "refresh-b")
        check.equal("a later accessToken does not refresh again", try? await session.accessToken(), "access-b")
        check.equal("clock-valid access after refresh does not spend again", refresher.attemptCount, 1)
    }

    await check.suite("Concurrent same-bearer 401s single-flight") {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: {}
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let first = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        let second = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        let joinedAccess = Task { try await session.accessToken() }
        check.equal("the second 401 joins rather than starting a second spend", refresher.attemptCount, 1)

        refresher.complete(grant(access: "access-b", refresh: "refresh-b"))
        check.equal("first waiter receives the replacement", try? await first.value, "access-b")
        check.equal("second waiter receives the same replacement", try? await second.value, "access-b")
        check.equal("in-flight accessToken joins the same refresh", try? await joinedAccess.value, "access-b")
        check.equal("rotating refresh token is spent once", refresher.attemptCount, 1)
        check.equal("rotating refresh token is not double-spent", refresher.spent, ["refresh-a"])
    }

    await check.suite("Late rejection of a replaced bearer is inert") {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: {}
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))
        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        refresher.complete(grant(access: "access-b", refresh: "refresh-b"))
        _ = try? await pending.value

        let late = try? await session.refreshIgnoringExpiry(rejected: "access-a")
        check.equal("a late 401 for the old bearer returns the replacement", late, "access-b")
        check.equal("the replacement refresh token is not spent", refresher.attemptCount, 1)
        check.equal("the replacement grant remains stored", store.stored?.refreshToken, "refresh-b")
    }

    await check.suite("invalid_grant clears and announces only the matching generation") {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let cookies = GrantCookieCounter()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: { cookies.increment() }
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let announcements = RevocationProbe(session.grantRevocations())
        await session.drainActor()

        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        refresher.fail(KeymasterAuthError.grantRevoked)

        var revoked = false
        do {
            _ = try await pending.value
        } catch KeymasterSessionError.grantRevoked {
            revoked = true
        } catch {
            check.check("matching invalid_grant surfaces grantRevoked, got \(error)", false)
        }
        check.check("matching invalid_grant surfaces the sign-in-again error", revoked)
        check.nil_("matching invalid_grant clears the stored grant", store.stored)
        check.equal("matching invalid_grant runs the terminal cookie cleanup", cookies.count, 1)
        await announcements.waitForAnnouncement()
        check.equal("matching invalid_grant announces revocation", announcements.count, 1)
        announcements.cancel()
        var noGrantAfterClear = false
        do {
            _ = try await session.accessToken()
        } catch KeymasterSessionError.noGrant {
            noGrantAfterClear = true
        } catch {
            check.check("cleared grant is noGrant, got \(error)", false)
        }
        check.check("the session has no grant after matching revocation", noGrantAfterClear)
    }

    await check.suite("Stale invalid_grant does not revoke a replacement grant") {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let cookies = GrantCookieCounter()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: { cookies.increment() }
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let announcements = RevocationProbe(session.grantRevocations())
        await session.drainActor()

        let pending = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        try? await session.adopt(grant(access: "access-new", refresh: "refresh-new"))
        refresher.fail(KeymasterAuthError.grantRevoked)

        var stale = false
        do {
            _ = try await pending.value
        } catch KeymasterSessionError.noGrant {
            stale = true
        } catch {
            check.check("stale invalid_grant is noGrant, got \(error)", false)
        }
        check.check("stale invalid_grant does not claim the replacement was revoked", stale)
        check.equal("the adopted grant remains", store.stored?.refreshToken, "refresh-new")
        check.equal("stale invalid_grant does not clear cookies", cookies.count, 0)
        await session.drainActor()
        check.equal("stale invalid_grant does not announce", announcements.count, 0)
        check.equal("the replacement bearer is live", try? await session.accessToken(), "access-new")
        announcements.cancel()
    }

    await check.suite("Adopt and logout during refresh stay authoritative") {
        let store = MemoryGrantStore()
        let refresher = ParkingRefresher()
        let cookies = GrantCookieCounter()
        let session = KeymasterSession(
            store: store,
            refresher: { try await refresher.refresh($0) },
            cookieCleanup: { cookies.increment() }
        )
        try? await session.adopt(grant(access: "access-a", refresh: "refresh-a"))

        let superseded = Task { try await session.refreshIgnoringExpiry(rejected: "access-a") }
        await refresher.waitUntilParked()
        try? await session.adopt(grant(access: "access-adopted", refresh: "refresh-adopted"))
        refresher.complete(grant(access: "access-stale", refresh: "refresh-stale"))

        var adoptStale = false
        do {
            _ = try await superseded.value
        } catch KeymasterSessionError.noGrant {
            adoptStale = true
        } catch {
            check.check("adopt during refresh is noGrant, got \(error)", false)
        }
        check.check("a refresh that loses to adopt does not persist", adoptStale)
        check.equal("adopted tokens survive the stale success", store.stored?.accessToken, "access-adopted")

        let loggedOut = Task { try await session.refreshIgnoringExpiry(rejected: "access-adopted") }
        await refresher.waitUntilParked()
        await session.clear()
        refresher.complete(grant(access: "access-zombie", refresh: "refresh-zombie"))

        var logoutStale = false
        do {
            _ = try await loggedOut.value
        } catch KeymasterSessionError.noGrant {
            logoutStale = true
        } catch {
            check.check("logout during refresh is noGrant, got \(error)", false)
        }
        check.check("a refresh that loses to logout does not persist", logoutStale)
        check.nil_("logout leaves no grant for the stale success to restore", store.stored)
        check.equal("logout still runs cookie cleanup once", cookies.count, 1)
    }

    await check.suite("Concurrent initial store load is a single flight") {
        let stored = grant(access: "stored-access", refresh: "stored-refresh")
        let store = GatedGrantStore(initial: stored)
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                throw KeymasterAuthError.tokenExchangeFailed(500)
            },
            cookieCleanup: {}
        )

        let first = Task { await session.hasGrant }
        await store.waitUntilLoadEntered()
        check.equal("the first caller starts one store read", store.loadCount, 1)

        let second = Task { try await session.accessToken() }
        let third = Task { await session.hasGrant }
        store.releaseLoad()

        check.check("first caller sees the stored grant", await first.value)
        check.equal("second caller receives the stored bearer", try? await second.value, "stored-access")
        check.check("third caller sees the stored grant", await third.value)
        check.equal("concurrent callers share one store read", store.loadCount, 1)
    }

    await check.suite("Adopt during store load wins over the stale read") {
        let store = GatedGrantStore(initial: grant(access: "disk-access", refresh: "disk-refresh"))
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                throw KeymasterAuthError.tokenExchangeFailed(500)
            },
            cookieCleanup: {}
        )

        let first = Task { try await session.accessToken() }
        await store.waitUntilLoadEntered()
        try? await session.adopt(grant(access: "adopted-access", refresh: "adopted-refresh"))
        store.releaseLoad()

        check.equal("adopt during load is the live bearer", try? await first.value, "adopted-access")
        check.equal("the stale disk snapshot is not persisted", store.stored?.accessToken, "adopted-access")
    }

    await check.suite("Logout during store load wins over the stale read") {
        let store = GatedGrantStore(initial: grant(access: "disk-access", refresh: "disk-refresh"))
        let session = KeymasterSession(
            store: store,
            refresher: { _ in
                throw KeymasterAuthError.tokenExchangeFailed(500)
            },
            cookieCleanup: {}
        )

        let first = Task { await session.hasGrant }
        await store.waitUntilLoadEntered()
        await session.clear()
        store.releaseLoad()

        check.check("logout during load leaves no grant", await first.value == false)
        check.nil_("the stale disk snapshot is not re-applied", store.stored)
    }

    await check.suite("Partner 401 invalidates the sent pair once and does not loop") {
        let tokens = CredentialSequence(values: ["access-a", "access-b"])
        let clients = CredentialSequence(values: ["client-a", "client-b"])
        let invalidatedAccess = RecordingInvalidator()
        let invalidatedClient = RecordingInvalidator()
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (200, profileBody),
        ])
        let api = PartnerAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { await invalidatedAccess.record($0) },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: transport.send
        )

        let profile = try? await api.profile()
        check.equal("retry succeeds after one 401", profile?.name, "Listener")
        check.equal("the sent bearer is invalidated", await invalidatedAccess.values, ["access-a"])
        check.equal("the sent client token is invalidated", await invalidatedClient.values, ["client-a"])
        check.equal("access is fetched for the attempt and the retry", tokens.callCount, 2)
        check.equal("client token is fetched for the attempt and the retry", clients.callCount, 2)
        check.equal("the transport is attempted twice", transport.callCount, 2)
        check.equal(
            "retry carries the replacement pair",
            transport.authorizationTokens,
            ["access-a", "access-b"]
        )
        check.equal("retry carries the replacement client token", transport.clientTokens, ["client-a", "client-b"])
    }

    await check.suite("A second Partner 401 stops") {
        let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c"])
        let clients = CredentialSequence(values: ["client-a", "client-b", "client-c"])
        let invalidatedAccess = RecordingInvalidator()
        let invalidatedClient = RecordingInvalidator()
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (401, Data()),
            (200, profileBody),
        ])
        let api = PartnerAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { await invalidatedAccess.record($0) },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: transport.send
        )

        var status = 0
        do {
            _ = try await api.profile()
        } catch let error as PartnerAPIError {
            if case let .requestFailed(code) = error { status = code }
        } catch {
            check.check("second 401 stays PartnerAPIError, got \(error)", false)
        }
        check.equal("a second 401 is returned rather than retried again", status, 401)
        check.equal("credentials are invalidated only after the first 401", await invalidatedAccess.values, ["access-a"])
        check.equal("client token is invalidated only after the first 401", await invalidatedClient.values, ["client-a"])
        check.equal("the transport stops after the retry", transport.callCount, 2)
        check.equal("a third credential is never fetched", tokens.callCount, 2)
    }

    await check.suite("Web queue 401 retries the sent bearer once") {
        let tokens = CredentialSequence(values: ["queue-a", "queue-b", "queue-c"])
        let invalidated = RecordingInvalidator()
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (200, queueBody),
        ])
        let api = SpotifyWebPlayerAPI(
            accessToken: { tokens.next() },
            invalidateAccessToken: { await invalidated.record($0) },
            transport: transport.send
        )

        let tracks = try? await api.queue()
        check.equal("queue retry succeeds after one 401", tracks?.map(\.uri), ["spotify:track:track-id"])
        check.equal("queue 401 invalidates the sent bearer", await invalidated.values, ["queue-a"])
        check.equal("queue retry uses the replacement bearer", transport.authorizationTokens, ["queue-a", "queue-b"])
        check.equal("queue never sends a client token", transport.clientTokens, [])
        check.equal("queue transport is attempted twice", transport.callCount, 2)
    }

    await check.suite("A second Web queue 401 stops") {
        let tokens = CredentialSequence(values: ["queue-a", "queue-b", "queue-c"])
        let invalidated = RecordingInvalidator()
        let transport = ScriptedTransport(responses: [
            (401, Data()),
            (401, Data()),
            (200, queueBody),
        ])
        let api = SpotifyWebPlayerAPI(
            accessToken: { tokens.next() },
            invalidateAccessToken: { await invalidated.record($0) },
            transport: transport.send
        )

        var status = 0
        do {
            _ = try await api.queue()
        } catch let error as SpotifyWebPlayerAPIError {
            if case let .requestFailed(code) = error { status = code }
        } catch {
            check.check("second queue 401 stays SpotifyWebPlayerAPIError, got \(error)", false)
        }
        check.equal("a second queue 401 is returned rather than retried again", status, 401)
        check.equal("queue invalidates only the first sent bearer", await invalidated.values, ["queue-a"])
        check.equal("queue stops after the retry", transport.callCount, 2)
        check.equal("queue never fetches a third bearer", tokens.callCount, 2)
    }
}

private let profileBody = Data(
    #"{"data":{"me":{"profile":{"username":"listener","name":"Listener"}}}}"#.utf8
)

private let queueBody = Data(
    #"{"currently_playing":null,"queue":[{"id":"track-id","uri":"spotify:track:track-id","name":"First Track","duration_ms":123000,"artists":[{"name":"First Artist"}],"album":{"name":"First Album"}}]}"#
        .utf8
)

private func grant(
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

private final class MemoryGrantStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?

    var stored: KeymasterTokens? {
        lock.withLock { value }
    }

    func load() -> KeymasterTokens? {
        lock.withLock { value }
    }

    func save(_ tokens: KeymasterTokens) throws {
        lock.withLock { value = tokens }
    }

    func clear() {
        lock.withLock { value = nil }
    }
}

/// `load()` snapshots on entry, then waits, so adopt/clear during the wait cannot change what
/// the stale read would have returned.
private final class GatedGrantStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: KeymasterTokens?
    private var loads = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private let gate = DispatchSemaphore(value: 0)

    init(initial: KeymasterTokens?) {
        value = initial
    }

    var stored: KeymasterTokens? {
        lock.withLock { value }
    }

    var loadCount: Int {
        lock.withLock { loads }
    }

    func load() -> KeymasterTokens? {
        lock.lock()
        loads += 1
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

private final class ParkingRefresher: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: CheckedContinuation<KeymasterTokens, Error>?
    private var entered: CheckedContinuation<Void, Never>?
    private var attempts = 0
    private var spentTokens: [String] = []

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    var spent: [String] {
        lock.withLock { spentTokens }
    }

    func refresh(_ refreshToken: String) async throws -> KeymasterTokens {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            attempts += 1
            spentTokens.append(refreshToken)
            parked = continuation
            let entered = entered
            self.entered = nil
            lock.unlock()
            entered?.resume()
        }
    }

    func waitUntilParked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if parked != nil {
                lock.unlock()
                continuation.resume()
            } else {
                entered = continuation
                lock.unlock()
            }
        }
    }

    func complete(_ tokens: KeymasterTokens) {
        lock.lock()
        let continuation = parked
        parked = nil
        lock.unlock()
        continuation?.resume(returning: tokens)
    }

    func fail(_ error: Error) {
        lock.lock()
        let continuation = parked
        parked = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private final class CredentialSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String]
    private var index = 0

    init(values: [String]) {
        self.values = values
    }

    var callCount: Int {
        lock.withLock { index }
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        let value = values[index]
        index += 1
        return value
    }
}

private actor RecordingInvalidator {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private final class ScriptedTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [(Int, Data)]
    private var index = 0
    private var authorizations: [String] = []
    private var clients: [String] = []

    init(responses: [(Int, Data)]) {
        self.responses = responses
    }

    var callCount: Int {
        lock.withLock { index }
    }

    var authorizationTokens: [String] {
        lock.withLock { authorizations }
    }

    var clientTokens: [String] {
        lock.withLock { clients }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        if let access = SpotifyCredentials.accessTokenCarried(by: request) {
            authorizations.append(access)
        }
        if let client = request.value(forHTTPHeaderField: "Client-Token") {
            clients.append(client)
        }
        let response = responses[index]
        index += 1
        let url = request.url ?? URL(string: "https://example.invalid/")!
        return (response.1, HTTPURLResponse(url: url, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private extension KeymasterSession {
    /// Completes a hop onto this actor so a just-created revocation stream can install.
    func drainActor() async {
        _ = await hasGrant
    }
}

private final class GrantCookieCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class RevocationProbe: @unchecked Sendable {
    private let state: State
    private let listener: Task<Void, Never>

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var announcements = 0
        var waiter: CheckedContinuation<Void, Never>?
    }

    init(_ stream: AsyncStream<Void>) {
        let state = State()
        self.state = state
        listener = Task {
            for await _ in stream {
                state.lock.lock()
                state.announcements += 1
                let waiter = state.waiter
                state.waiter = nil
                state.lock.unlock()
                waiter?.resume()
            }
        }
    }

    var count: Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.announcements
    }

    func waitForAnnouncement() async {
        await withCheckedContinuation { continuation in
            state.lock.lock()
            if state.announcements > 0 {
                state.lock.unlock()
                continuation.resume()
            } else {
                state.waiter = continuation
                state.lock.unlock()
            }
        }
    }

    func cancel() {
        listener.cancel()
        state.lock.lock()
        let waiter = state.waiter
        state.waiter = nil
        state.lock.unlock()
        waiter?.resume()
    }
}
