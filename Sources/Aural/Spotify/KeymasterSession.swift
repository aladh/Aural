//
//  KeymasterSession.swift
//  Aural
//
//  Holds the keymaster tokens, and keeps them fresh.
//

import Foundation

private typealias DefaultKeymasterTokenStore = KeymasterMigratingStore

/// The live keymaster grant: one access token, kept valid, shared by everything that needs it.
///
/// An actor because the token is read from several places at once — the accesspoint session,
/// pathfinder and spclient — and a refresh must happen once rather than once per caller.
/// Concurrent callers arriving during a refresh await the same one.
actor KeymasterSession {
    /// The app's grant. One instance, because one grant is what the app has: the accesspoint
    /// session and both API clients read the same token, and a second instance would refresh
    /// against a rotating token the first has already spent.
    static let shared = KeymasterSession()

    /// Async listeners waiting for a terminal grant revocation. The stream is instance-scoped:
    /// tests can construct an isolated session without ever notifying the live application.
    private var revocationContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Injected so the rotation policy can be tested without a network. The real one is
    /// `KeymasterAuth.refresh`.
    typealias Refresher = @Sendable (String) async throws -> KeymasterTokens

    private let store: KeymasterTokenStoring
    private let refresher: Refresher
    /// Clears Spotify authentication cookies from the jar the token exchange uses.
    /// Injected so Sign Out cleanup can be checked without mutating the process-wide store.
    private let cookieCleanup: @Sendable () -> Void
    private var tokens: KeymasterTokens?
    private var hasLoadedStore = false
    /// Concurrent first callers join this rather than observing `hasLoadedStore` before the
    /// detached store read has assigned `tokens`. The task includes the generation-guarded
    /// assignment, not only the disk read.
    private var storeLoadInFlight: Task<Void, Never>?
    private var refreshInFlight: Task<KeymasterTokens, Error>?
    /// Advanced by `supersedeRefresh()`. A refresh that was in flight when the grant was
    /// cleared or replaced must not write what it eventually returns — that would put the
    /// signed-out account's refresh token straight back into the keychain.
    private var generation = 0

    init(
        store: KeymasterTokenStoring = DefaultKeymasterTokenStore(),
        refresher: @escaping Refresher = { try await KeymasterAuth.refresh(refreshToken: $0) },
        cookieCleanup: @escaping @Sendable () -> Void = {
            AuthCookieCleanup.removeSpotifyAuthenticationCookies()
        }
    ) {
        self.store = store
        self.refresher = refresher
        self.cookieCleanup = cookieCleanup
    }

    /// Fires once when a refresh comes back `invalid_grant`. AsyncSequence keeps account
    /// lifecycle on the same structured-concurrency model as the rest of the application.
    nonisolated func grantRevocations() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.installRevocationContinuation(continuation, id: id) }
            continuation.onTermination = { _ in
                Task { await self.removeRevocationContinuation(id: id) }
            }
        }
    }

    private func installRevocationContinuation(
        _ continuation: AsyncStream<Void>.Continuation,
        id: UUID
    ) {
        revocationContinuations[id] = continuation
    }

    private func removeRevocationContinuation(id: UUID) {
        revocationContinuations[id] = nil
    }

    private func announceRevocation() {
        for continuation in revocationContinuations.values {
            continuation.yield(())
        }
    }

    /// Whether a grant has been completed on this machine.
    var hasGrant: Bool {
        get async {
            await loadStoredGrantIfNeeded()
            return tokens != nil
        }
    }

    /// Loads persisted state lazily on this actor rather than synchronously while the main-actor
    /// controller is being initialized. A Keychain lookup can take time to resolve an older
    /// item's ACL; that must not prevent SwiftUI from presenting the window.
    ///
    /// The load itself is a single flight: `hasLoadedStore` is not set until the read finishes,
    /// so a concurrent early `accessToken()` cannot observe an empty grant and throw `noGrant`
    /// while the store still holds one. `adopt` and `clear` bump `generation` and win over a
    /// stale read the same way a superseded refresh does. Leftover plaintext is never written
    /// to Keychain from the detached read; that commit happens only if this generation still
    /// owns the slot afterwards.
    private func loadStoredGrantIfNeeded() async {
        if hasLoadedStore { return }

        if let storeLoadInFlight {
            await storeLoadInFlight.value
            return
        }

        let startedAt = generation
        let task = Task {
            await self.commitStoreLoad(startedAt: startedAt)
        }
        storeLoadInFlight = task
        defer {
            if storeLoadInFlight == task {
                storeLoadInFlight = nil
            }
        }
        await task.value
    }

    private func commitStoreLoad(startedAt: Int) async {
        let store = store
        let snapshot = await Task.detached(priority: .utility) {
            store.loadGrant()
        }.value
        applyLoadedGrant(snapshot.tokens, startedAt: startedAt)
        guard snapshot.needsSecurePersist else { return }
        await persistLeftoverGrantIfCurrent(snapshot.tokens, startedAt: startedAt)
    }

    /// Only the in-flight load task assigns. Joiners wait for that task so they cannot observe
    /// `tokens == nil` after the disk read has finished. Adopt/clear bump `generation` and set
    /// `hasLoadedStore` first, so a stale snapshot is discarded.
    private func applyLoadedGrant(_ storedTokens: KeymasterTokens?, startedAt: Int) {
        guard generation == startedAt, !hasLoadedStore else { return }
        tokens = storedTokens
        hasLoadedStore = true
    }

    /// Writes a leftover plaintext grant only when this load still owns the session. If
    /// `adopt`/`clear` won while the Keychain write ran, restore that later disk state.
    private func persistLeftoverGrantIfCurrent(_ leftover: KeymasterTokens?, startedAt: Int) async {
        guard generation == startedAt, hasLoadedStore, let leftover else { return }
        let store = store
        do {
            try await Task.detached(priority: .utility) {
                try store.save(leftover)
            }.value
        } catch {
            AuralLog.authentication.error(
                "\(KeymasterGrantPersistenceDiagnostics.legacyMigrationSaveFailed, privacy: .public)"
            )
            return
        }
        guard generation != startedAt else { return }
        reconcileStoreAfterSupersededPersist()
    }

    private func reconcileStoreAfterSupersededPersist() {
        if let tokens {
            do {
                try store.save(tokens)
            } catch {
                AuralLog.authentication.error(
                    "\(KeymasterGrantPersistenceDiagnostics.supersededPersistRepairFailed, privacy: .public)"
                )
            }
        } else {
            store.clear()
        }
    }

    var username: String? {
        get async {
            await loadStoredGrantIfNeeded()
            return tokens?.username
        }
    }

    /// Records the outcome of a fresh grant.
    func adopt(_ newTokens: KeymasterTokens) throws {
        hasLoadedStore = true
        supersedeRefresh()
        tokens = newTokens
        try store.save(newTokens)
    }

    /// Forgets the grant — on logout, or when the refresh token is dead.
    func clear() {
        hasLoadedStore = true
        supersedeRefresh()
        tokens = nil
        store.clear()
        cookieCleanup()
    }

    /// Abandons any refresh in flight and disowns whatever it eventually returns.
    ///
    /// A refresh spends the *previous* refresh token, and Spotify keeps one live token per
    /// client id and account — so a refresh that started before a new grant either returns
    /// tokens that grant has already replaced, and overwrites it, or is refused as
    /// `invalid_grant` for the token it retired, and discards it. The second is the likelier of
    /// the two and logs the user out moments after they authorized. Re-authorizing while signed
    /// in is a real path here: Speakers and the play alert both offer it.
    ///
    /// Cancellation is cooperative, so the network call can still succeed afterwards; the
    /// generation is what stops its result from being written.
    private func supersedeRefresh() {
        generation &+= 1
        refreshInFlight?.cancel()
        refreshInFlight = nil
    }

    /// A token that is valid now, refreshing first if it is close enough to expiry.
    ///
    /// Throws rather than returning nil when there is no grant: every caller needs a token to
    /// do anything at all, and "not authorized yet" is a state the UI already handles.
    func accessToken(now: Date = Date()) async throws -> String {
        await loadStoredGrantIfNeeded()
        guard let current = tokens else {
            throw KeymasterSessionError.noGrant
        }

        if refreshInFlight != nil || current.needsRefresh(now: now) {
            do {
                return try await refreshed(from: current).accessToken
            } catch KeymasterSessionError.noGrant {
                if let tokens, !tokens.needsRefresh(now: now) {
                    return tokens.accessToken
                }
                throw KeymasterSessionError.noGrant
            }
        }

        return current.accessToken
    }

    /// A token that is valid now, refreshing even when the clock still considers the current
    /// access token live.
    ///
    /// HTTP 401 names the bearer that request actually sent. A token revoked mid-validity
    /// (`needsRefresh` is still false for up to ~55 minutes) must be spent here or every retry
    /// would carry the same dead credential. A late refusal for a bearer this session has
    /// already replaced is inert: the replacement's rotating refresh token must not be spent.
    /// Concurrent refusals of the same bearer join `refreshed(from:)` so that token is spent
    /// once.
    func refreshIgnoringExpiry(rejected: String) async throws -> String {
        await loadStoredGrantIfNeeded()
        guard let current = tokens else {
            throw KeymasterSessionError.noGrant
        }
        guard current.accessToken == rejected else {
            return current.accessToken
        }
        do {
            return try await refreshed(from: current).accessToken
        } catch KeymasterSessionError.noGrant {
            if let tokens, tokens.accessToken != rejected {
                return tokens.accessToken
            }
            throw KeymasterSessionError.noGrant
        }
    }

    private func refreshed(from current: KeymasterTokens) async throws -> KeymasterTokens {
        // A second caller during a refresh joins the one already running. Two concurrent
        // refreshes would each spend the same rotating token, and the loser's replacement
        // would be the one Spotify has already invalidated. The in-flight task is the
        // commit, not just the network call, so joiners observe the same persisted grant
        // or `KeymasterSessionError` as the owner.
        if let refreshInFlight {
            do {
                return try await refreshInFlight.value
            } catch is CancellationError {
                throw KeymasterSessionError.noGrant
            }
        }

        let startedAt = generation
        let current = current
        let task = Task {
            try await self.commitRefresh(from: current, startedAt: startedAt)
        }
        refreshInFlight = task
        // Only if the slot still holds *this* run. `adopt` and `clear` both empty it, and a
        // later refresh can have filled it again by the time this one unwinds — clearing that
        // one would let a second refresh start against the same rotating token, which is the
        // race the single-flight exists to prevent.
        defer {
            if refreshInFlight == task {
                refreshInFlight = nil
            }
        }
        return try await task.value
    }

    private func commitRefresh(from current: KeymasterTokens, startedAt: Int) async throws -> KeymasterTokens {
        let renewed: KeymasterTokens
        do {
            renewed = try await refresher(current.refreshToken)
        } catch KeymasterAuthError.grantRevoked {
            // Nothing to retry: this refresh token is dead and every later attempt spends the
            // same one. Left in place it fails forever and survives relaunch, because the
            // keychain item outlives the process — so forgetting it here is the whole fix for
            // the loop, and the announcement is what gets the user back to a sign-in.
            //
            // Guarded like the success path below: a logout during the network call already
            // cleared this grant, and a sign-in behind it may have adopted a *good* one. The
            // revocation belongs to the token this run spent, not to whatever holds the slot
            // now.
            guard startedAt == generation else {
                throw KeymasterSessionError.noGrant
            }

            clear()
            announceRevocation()
            throw KeymasterSessionError.grantRevoked
        } catch {
            // Adopt, logout, or a newer refresh already owns the slot; a cancelled or
            // transient failure from this spend must not be reported as the replacement's.
            guard startedAt == generation else {
                throw KeymasterSessionError.noGrant
            }
            throw error
        }

        // Back on the actor. A logout that landed during the network call already cleared the
        // grant, so this result belongs to an account that is gone — persisting it would
        // recreate the keychain item behind logout's back.
        guard startedAt == generation else {
            throw KeymasterSessionError.noGrant
        }

        // Only the initial exchange carries the username, so a refresh that omits it must not
        // blank the stored one.
        var merged = renewed
        if merged.username.isEmpty {
            merged.username = current.username
        }

        try store.save(merged)
        tokens = merged
        return merged
    }
}

nonisolated enum KeymasterSessionError: Error, LocalizedError, Equatable {
    case noGrant
    /// The grant was refused as dead and has been discarded. Separate from `noGrant` so a log
    /// says which of the two happened — a grant that never existed, or one that stopped being
    /// accepted mid-session.
    case grantRevoked

    var errorDescription: String? {
        switch self {
        case .noGrant:
            "This Mac has not been authorized for playback yet"
        case .grantRevoked:
            "Session expired, please sign in again"
        }
    }
}
