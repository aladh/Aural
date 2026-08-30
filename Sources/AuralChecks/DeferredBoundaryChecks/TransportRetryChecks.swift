import AuralDomain
import Foundation
@testable import AuralCore

@MainActor
func runTransportRetryChecks(_ check: CheckRunner) async {
    await check.suite("Replayable reads honor Retry-After and a bounded budget") {
        let deltaSleep = RecordingSleeper()
        let deltaTransport = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "7"]),
            .http(status: 200, body: profileBody),
        ])
        let deltaProfile = try? await partnerAPI(
            transport: deltaTransport.send,
            retryTiming: timing(sleeper: deltaSleep)
        ).profile()
        check.equal("Retry-After delta succeeds after one retry", deltaProfile?.name, "Listener")
        check.equal("Retry-After delta is the recorded delay", deltaSleep.delays, [7])
        check.equal("Retry-After delta attempts twice", deltaTransport.callCount, 2)

        let dateSleep = RecordingSleeper()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let dateTransport = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "Mon, 12 Jan 1970 13:47:10 GMT"]),
            .http(status: 200, body: profileBody),
        ])
        let dateProfile = try? await partnerAPI(
            transport: dateTransport.send,
            retryTiming: timing(now: now, sleeper: dateSleep)
        ).profile()
        check.equal("Retry-After HTTP-date succeeds after one retry", dateProfile?.name, "Listener")
        check.equal("Retry-After HTTP-date delay is the delta until that instant", dateSleep.delays, [30])

        let malformedSleep = RecordingSleeper()
        let malformedTransport = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "not-a-delay"]),
            .http(status: 200, body: profileBody),
        ])
        let malformedProfile = try? await partnerAPI(
            transport: malformedTransport.send,
            retryTiming: timing(sleeper: malformedSleep, jitter: 1)
        ).profile()
        check.equal("malformed Retry-After still retries", malformedProfile?.name, "Listener")
        check.equal(
            "malformed Retry-After uses the first backoff",
            malformedSleep.delays,
            [SpotifyTransientRetry.backoffDelay(completedAttempts: 1, unitJitter: 1)]
        )

        let cappedSleep = RecordingSleeper()
        let cappedTransport = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "3600"]),
            .http(status: 200, body: profileBody),
        ])
        _ = try? await partnerAPI(
            transport: cappedTransport.send,
            retryTiming: timing(sleeper: cappedSleep)
        ).profile()
        check.equal(
            "huge Retry-After is capped",
            cappedSleep.delays,
            [SpotifyTransientRetry.maximumDelaySeconds]
        )
    }

    await check.suite("Transient 5xx, URLError classification, budget, and success") {
        let fiveSleep = RecordingSleeper()
        let fiveTransport = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 200, body: profileBody),
        ])
        let recovered = try? await partnerAPI(
            transport: fiveTransport.send,
            retryTiming: timing(sleeper: fiveSleep, jitter: 1)
        ).profile()
        check.equal("transient 5xx succeeds after retry", recovered?.name, "Listener")
        check.equal("transient 5xx uses backoff", fiveSleep.delays, [0.5])
        check.equal("transient 5xx attempts twice", fiveTransport.callCount, 2)

        let budget = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 502),
            .http(status: 500),
            .http(status: 200, body: profileBody),
        ])
        await expectThrown(check, "the attempt budget is finite", PartnerAPIError.requestFailed(500)) {
            _ = try await partnerAPI(transport: budget.send).profile()
        }
        check.equal("budget stops after three attempts", budget.callCount, 3)

        let timeoutThenOk = ScriptedRetryTransport(steps: [
            .urlError(.timedOut),
            .http(status: 200, body: profileBody),
        ])
        let afterTimeout = try? await partnerAPI(transport: timeoutThenOk.send).profile()
        check.equal("timeout URLError retries and succeeds", afterTimeout?.name, "Listener")
        check.equal("timeout URLError attempts twice", timeoutThenOk.callCount, 2)

        let lostThenOk = ScriptedRetryTransport(steps: [
            .urlError(.networkConnectionLost),
            .http(status: 200, body: profileBody),
        ])
        check.equal(
            "networkConnectionLost retries",
            (try? await partnerAPI(transport: lostThenOk.send).profile())?.name,
            "Listener"
        )

        let hostThenOk = ScriptedRetryTransport(steps: [
            .urlError(.cannotConnectToHost),
            .http(status: 200, body: profileBody),
        ])
        check.equal(
            "cannotConnectToHost retries",
            (try? await partnerAPI(transport: hostThenOk.send).profile())?.name,
            "Listener"
        )

        let cancelled = ScriptedRetryTransport(steps: [.urlError(.cancelled)])
        await expectURLError(check, "cancelled URLError is not retried", .cancelled) {
            _ = try await partnerAPI(transport: cancelled.send).profile()
        }
        check.equal("cancelled URLError is one attempt", cancelled.callCount, 1)

        let tls = ScriptedRetryTransport(steps: [.urlError(.secureConnectionFailed)])
        await expectURLError(check, "TLS URLError is not retried", .secureConnectionFailed) {
            _ = try await partnerAPI(transport: tls.send).profile()
        }
        check.equal("disallowed URLError is one attempt", tls.callCount, 1)

        let offline = ScriptedRetryTransport(steps: [.urlError(.notConnectedToInternet)])
        await expectURLError(check, "offline URLError is not retried", .notConnectedToInternet) {
            _ = try await partnerAPI(transport: offline.send).profile()
        }
        check.equal("offline URLError is one attempt", offline.callCount, 1)

        let queueSleep = RecordingSleeper()
        let queueTransport = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "1"]),
            .http(status: 200, body: queueBody),
        ])
        await expectThrown(
            check,
            "Web queue 429 is not generic-replayed",
            SpotifyWebPlayerAPIError.requestFailed(429)
        ) {
            _ = try await SpotifyWebPlayerAPI(
                accessToken: { "queue-a" },
                invalidateAccessToken: { _ in },
                transport: queueTransport.send,
                retryTiming: timing(sleeper: queueSleep)
            ).queue()
        }
        check.equal("Web queue 429 is one GET", queueTransport.callCount, 1)
        check.equal("Web queue 429 does not sleep in the generic retry layer", queueSleep.delays, [])
        check.equal("Web queue 429 is GET", queueTransport.methods, ["GET"])
        check.equal("Web queue 429 hits the documented endpoint", queueTransport.urls, [
            SpotifyWebPlayerAPI.queueURL.absoluteString
        ])
    }

    await check.suite("One 401 interacts with the shared budget and cancellation") {
        let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c"])
        let clients = CredentialSequence(values: ["client-a", "client-b", "client-c"])
        let invalidatedAccess = RecordingInvalidator()
        let invalidatedClient = RecordingInvalidator()
        let mixed = ScriptedRetryTransport(steps: [
            .http(status: 401),
            .http(status: 503),
            .http(status: 200, body: profileBody),
        ])
        let recovered = try? await PartnerAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { await invalidatedAccess.record($0) },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: mixed.send,
            retryTiming: .immediate
        ).profile()
        check.equal("401 then 5xx still succeeds within the budget", recovered?.name, "Listener")
        check.equal("credentials invalidate once", await invalidatedAccess.values, ["access-a"])
        check.equal("client token invalidates once", await invalidatedClient.values, ["client-a"])
        check.equal("401 plus transient retry is three attempts", mixed.callCount, 3)
        check.equal("each attempt signs again", tokens.callCount, 3)

        let second401 = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 401),
            .http(status: 401),
            .http(status: 200, body: profileBody),
        ])
        let tokensB = CredentialSequence(values: ["a", "b", "c"])
        let clientsB = CredentialSequence(values: ["ca", "cb", "cc"])
        let accessB = RecordingInvalidator()
        var status = 0
        do {
            _ = try await PartnerAPI(
                accessToken: { tokensB.next() },
                clientToken: { clientsB.next() },
                invalidateAccessToken: { await accessB.record($0) },
                invalidateClientToken: { _ in },
                transport: second401.send,
                retryTiming: .immediate
            ).profile()
        } catch let error as PartnerAPIError {
            if case let .requestFailed(code) = error { status = code }
        } catch {
            check.check("second 401 stays PartnerAPIError, got \(error)", false)
        }
        check.equal("a second 401 stops even when budget remains", status, 401)
        check.equal("a second 401 does not consume a fourth attempt", second401.callCount, 3)
        check.equal("each 401 names its sent bearer", await accessB.values, ["b", "c"])

        let sleeper = ParkUntilCancelledSleeper()
        let parked = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "5"]),
            .http(status: 200, body: profileBody),
        ])
        let task = Task {
            try await partnerAPI(
                transport: parked.send,
                retryTiming: SpotifyTransientRetry.Timing(
                    now: { Date(timeIntervalSince1970: 0) },
                    sleep: { try await sleeper.sleep($0) },
                    unitJitter: { 1 }
                )
            ).profile()
        }
        await sleeper.waitUntilStarted()
        task.cancel()
        var cancelledDuringBackoff = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            cancelledDuringBackoff = true
        } catch {
            check.check("backoff cancellation stays CancellationError, got \(error)", false)
        }
        check.check("cancellation during backoff surfaces CancellationError", cancelledDuringBackoff)
        check.equal("cancellation during backoff does not send the retry", parked.callCount, 1)
        check.equal("cancellation still recorded the Retry-After delay", sleeper.delays, [5])
    }

    await check.suite("Concurrent 401s keep the rejected identity; mutations do not replay") {
        let started = StartedGate(count: 2)
        let current = SharedToken("access-a")
        let invalidatedAccess = RecordingInvalidator()
        let concurrent = BearerResponseTransport { token in
            token == "access-a" ? .http(status: 401) : .http(status: 200, body: profileBody)
        }
        let api = PartnerAPI(
            accessToken: {
                let token = await current.value()
                if token == "access-a" {
                    started.mark()
                    await started.wait()
                }
                return token
            },
            clientToken: { "client-a" },
            invalidateAccessToken: { rejected in
                await invalidatedAccess.record(rejected)
                await current.replace(rejected, with: "access-b")
            },
            invalidateClientToken: { _ in },
            transport: concurrent.send,
            retryTiming: .immediate
        )
        async let first = api.profile()
        async let second = api.profile()
        let names = [(try? await first)?.name, (try? await second)?.name]
        check.check("both concurrent reads succeed", names.allSatisfy { $0 == "Listener" })
        check.equal(
            "each concurrent 401 names the rejected bearer",
            await invalidatedAccess.values,
            ["access-a", "access-a"]
        )
        check.equal("concurrent reads retry independently", concurrent.callCount, 4)

        let mutation = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 200, body: Data()),
        ])
        await expectThrown(
            check,
            "PartnerAPI mutations do not replay a lost 5xx",
            PartnerAPIError.requestFailed(503)
        ) {
            try await partnerAPI(transport: mutation.send).addToPlaylist(
                playlistId: "pl",
                trackUris: ["spotify:track:t"]
            )
        }
        check.equal("a playlist mutation is one attempt", mutation.callCount, 1)

        let libraryWrite = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "2"]),
            .http(status: 200, body: Data()),
        ])
        await expectThrown(
            check,
            "library mutations do not replay a 429",
            PartnerAPIError.requestFailed(429)
        ) {
            try await partnerAPI(transport: libraryWrite.send).addToLibrary(uris: ["spotify:track:t"])
        }
        check.equal("a library mutation is one attempt", libraryWrite.callCount, 1)

        let connect = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 200, body: Data()),
        ])
        await expectThrown(
            check,
            "Connect commands do not replay a lost 5xx",
            SpotifyConnectAPIError.requestFailed(503)
        ) {
            try await SpotifyConnectAPI(
                accessToken: { "fixture-access" },
                clientToken: { "fixture-client" },
                invalidateAccessToken: { _ in },
                invalidateClientToken: { _ in },
                transport: connect.send,
                retryTiming: .immediate
            ).send(.pause, from: "source", to: "target")
        }
        check.equal("a Connect command is one attempt", connect.callCount, 1)
    }

    await check.suite("A budget-final 401 still invalidates the exact sent pair") {
        let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c", "access-d"])
        let clients = CredentialSequence(values: ["client-a", "client-b", "client-c", "client-d"])
        let invalidatedAccess = RecordingInvalidator()
        let invalidatedClient = RecordingInvalidator()
        let fiveThen401 = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 503),
            .http(status: 401),
            .http(status: 200, body: profileBody),
        ])
        var fiveStatus = 0
        do {
            _ = try await PartnerAPI(
                accessToken: { tokens.next() },
                clientToken: { clients.next() },
                invalidateAccessToken: { await invalidatedAccess.record($0) },
                invalidateClientToken: { await invalidatedClient.record($0) },
                transport: fiveThen401.send,
                retryTiming: .immediate
            ).profile()
        } catch let error as PartnerAPIError {
            if case let .requestFailed(code) = error { fiveStatus = code }
        } catch {
            check.check("budget-final 401 stays PartnerAPIError, got \(error)", false)
        }
        check.equal("5xx then 401 returns the terminal 401", fiveStatus, 401)
        check.equal("5xx then 401 is three attempts", fiveThen401.callCount, 3)
        check.equal("the final 401 bearer is invalidated", await invalidatedAccess.values, ["access-c"])
        check.equal("the final 401 client token is invalidated", await invalidatedClient.values, ["client-c"])
        check.equal("no fourth credential fetch after the budget-final 401", tokens.callCount, 3)

        let timeoutTokens = CredentialSequence(values: ["timeout-a", "timeout-b", "timeout-c", "timeout-d"])
        let timeoutClients = CredentialSequence(values: ["client-timeout-a", "client-timeout-b", "client-timeout-c"])
        let timeoutAccess = RecordingInvalidator()
        let timeoutClient = RecordingInvalidator()
        let timeoutThen401 = ScriptedRetryTransport(steps: [
            .urlError(.timedOut),
            .urlError(.timedOut),
            .http(status: 401),
            .http(status: 200, body: profileBody),
        ])
        var timeoutStatus = 0
        do {
            _ = try await PartnerAPI(
                accessToken: { timeoutTokens.next() },
                clientToken: { timeoutClients.next() },
                invalidateAccessToken: { await timeoutAccess.record($0) },
                invalidateClientToken: { await timeoutClient.record($0) },
                transport: timeoutThen401.send,
                retryTiming: .immediate
            ).profile()
        } catch let error as PartnerAPIError {
            if case let .requestFailed(code) = error { timeoutStatus = code }
        } catch {
            check.check("timeout then 401 stays PartnerAPIError, got \(error)", false)
        }
        check.equal("timeout then 401 returns the terminal 401", timeoutStatus, 401)
        check.equal("timeout then 401 is three attempts", timeoutThen401.callCount, 3)
        check.equal("the timeout-final 401 bearer is invalidated", await timeoutAccess.values, ["timeout-c"])
        check.equal(
            "the timeout-final 401 client token is invalidated",
            await timeoutClient.values,
            ["client-timeout-c"]
        )
        check.equal("no fourth credential fetch after the timeout-final 401", timeoutTokens.callCount, 3)

        let queueTokens = CredentialSequence(values: ["queue-a", "queue-b", "queue-c", "queue-d"])
        let queueAccess = RecordingInvalidator()
        let queueTransient = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 401),
            .http(status: 200, body: queueBody),
        ])
        await expectThrown(
            check,
            "Web queue 503 is not generic-replayed",
            SpotifyWebPlayerAPIError.requestFailed(503)
        ) {
            _ = try await SpotifyWebPlayerAPI(
                accessToken: { queueTokens.next() },
                invalidateAccessToken: { await queueAccess.record($0) },
                transport: queueTransient.send,
                retryTiming: .immediate
            ).queue()
        }
        check.equal("Web queue 503 is one GET", queueTransient.callCount, 1)
        check.equal("Web queue 503 does not invalidate a bearer", await queueAccess.values, [])
        check.equal("Web queue 503 does not fetch a replacement bearer", queueTokens.callCount, 1)
    }

    await check.suite("Terminal 401 invalidation failures and cancellation do not add a request") {
        let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c", "access-d"])
        let clients = CredentialSequence(values: ["client-a", "client-b", "client-c", "client-d"])
        let invalidatedClient = RecordingInvalidator()
        let thrown = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 503),
            .http(status: 401),
            .http(status: 200, body: profileBody),
        ])
        var revoked = false
        do {
            _ = try await PartnerAPI(
                accessToken: { tokens.next() },
                clientToken: { clients.next() },
                invalidateAccessToken: { _ in throw KeymasterSessionError.grantRevoked },
                invalidateClientToken: { await invalidatedClient.record($0) },
                transport: thrown.send,
                retryTiming: .immediate
            ).profile()
        } catch KeymasterSessionError.grantRevoked {
            revoked = true
        } catch {
            check.check("budget-final bearer throw stays grantRevoked, got \(error)", false)
        }
        check.check("a budget-final bearer throw still surfaces grantRevoked", revoked)
        check.equal(
            "client token drops before the terminal bearer throw",
            await invalidatedClient.values,
            ["client-c"]
        )
        check.equal("a terminal bearer throw does not add a request", thrown.callCount, 3)
        check.equal("a terminal bearer throw does not fetch another credential", tokens.callCount, 3)

        let parkedTokens = CredentialSequence(values: ["park-a", "park-b", "park-c", "park-d"])
        let parkedClients = CredentialSequence(values: ["park-client-a", "park-client-b", "park-client-c"])
        let parkedAccess = ParkUntilCancelledInvalidator()
        let parked = ScriptedRetryTransport(steps: [
            .http(status: 503),
            .http(status: 503),
            .http(status: 401),
            .http(status: 200, body: profileBody),
        ])
        let task = Task {
            try await PartnerAPI(
                accessToken: { parkedTokens.next() },
                clientToken: { parkedClients.next() },
                invalidateAccessToken: { try await parkedAccess.park($0) },
                invalidateClientToken: { _ in },
                transport: parked.send,
                retryTiming: .immediate
            ).profile()
        }
        await parkedAccess.waitUntilStarted()
        task.cancel()
        var cancelledDuringInvalidation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            cancelledDuringInvalidation = true
        } catch {
            check.check("terminal invalidation cancellation stays CancellationError, got \(error)", false)
        }
        check.check(
            "cancellation during terminal invalidation surfaces CancellationError",
            cancelledDuringInvalidation
        )
        check.equal(
            "cancellation during terminal invalidation does not add a request",
            parked.callCount,
            3
        )
        check.equal("cancellation still named the final bearer", await parkedAccess.values, ["park-c"])
        check.equal("cancellation does not fetch another credential", parkedTokens.callCount, 3)
    }

    await check.suite("Web queue 429 reaches QueueService without generic replay") {
        let sleeper = RecordingSleeper()
        let clock = ControllablePlaybackClock(Date(timeIntervalSince1970: 1_700_000_000))
        let rateLimited = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "7"]),
            .http(status: 200, body: queueBody),
        ])
        let fallback = [
            QueueEntry(uri: "spotify:track:alpha", provider: "connect", occurrence: 0, uid: "uid-alpha"),
            QueueEntry(uri: "spotify:track:beta", provider: "connect", occurrence: 1, uid: "uid-beta"),
        ]
        let cached = [
            queueCheckTrack("spotify:track:alpha"),
            queueCheckTrack("spotify:track:beta"),
        ]
        let limitedAPI = SpotifyWebPlayerAPI(
            accessToken: { "queue-a" },
            invalidateAccessToken: { _ in },
            transport: rateLimited.send,
            retryTiming: timing(now: clock.now(), sleeper: sleeper)
        )
        let limitedService = QueueService(
            webQueue: limitedAPI,
            metadata: TrackMetadataService(remote: UnusedQueueRemote()),
            clock: clock
        )
        await limitedService.reset(accountEpoch: 11)

        let first = await limitedService.refresh(
            fallbackEntries: fallback,
            cachedTracks: cached,
            currentTrackURI: "spotify:track:now",
            accountEpoch: 11
        )
        check.equal("first 429 performs one Web GET", rateLimited.callCount, 1)
        check.equal("first 429 is GET", rateLimited.methods, ["GET"])
        check.equal(
            "first 429 hits the documented Web queue",
            rateLimited.urls,
            [SpotifyWebPlayerAPI.queueURL.absoluteString]
        )
        check.equal("first 429 sends no client token", rateLimited.clientTokens, [])
        check.equal("first 429 does not invoke the generic sleeper", sleeper.delays, [])
        check.equal("first 429 falls back to Connect", first?.source, .connect)
        check.equal("first 429 Connect fallback is complete", first?.completeness, .complete)
        check.equal(
            "first 429 preserves Connect order",
            first?.entries.map(\.uri),
            ["spotify:track:alpha", "spotify:track:beta"]
        )
        check.equal(
            "first 429 preserves Connect occurrence uids",
            first?.entries.map(\.uid),
            ["uid-alpha", "uid-beta"]
        )

        let second = await limitedService.refresh(
            fallbackEntries: fallback,
            cachedTracks: cached,
            currentTrackURI: "spotify:track:now",
            accountEpoch: 11
        )
        check.equal("cooldown refresh makes no second Web request", rateLimited.callCount, 1)
        check.equal("cooldown refresh still uses Connect", second?.source, .connect)
        check.equal("cooldown refresh stays complete", second?.completeness, .complete)
        check.equal(
            "cooldown refresh keeps Connect order",
            second?.entries.map(\.uri),
            ["spotify:track:alpha", "spotify:track:beta"]
        )
        check.equal("cooldown refresh still does not sleep generically", sleeper.delays, [])

        let tokens = CredentialSequence(values: ["queue-a", "queue-b", "queue-c"])
        let invalidated = RecordingInvalidator()
        let recovered = ScriptedRetryTransport(steps: [
            .http(status: 401),
            .http(status: 200, body: queueBody),
        ])
        let recoveredAPI = SpotifyWebPlayerAPI(
            accessToken: { tokens.next() },
            invalidateAccessToken: { await invalidated.record($0) },
            transport: recovered.send,
            retryTiming: timing(sleeper: sleeper)
        )
        let recoveredService = QueueService(
            webQueue: recoveredAPI,
            metadata: TrackMetadataService(remote: UnusedQueueRemote()),
            clock: clock
        )
        await recoveredService.reset(accountEpoch: 12)
        let webSnapshot = await recoveredService.refresh(
            fallbackEntries: fallback,
            cachedTracks: cached,
            currentTrackURI: "spotify:track:now",
            accountEpoch: 12
        )
        check.equal("401 then 200 uses the Web queue", webSnapshot?.source, .webAPI)
        check.equal("401 then 200 retries once", recovered.callCount, 2)
        check.equal("401 then 200 invalidates the sent bearer once", await invalidated.values, ["queue-a"])
        check.equal("401 then 200 uses GET twice", recovered.methods, ["GET", "GET"])
        check.equal("401 then 200 sends no client token", recovered.clientTokens, [])
        check.equal("401 then 200 still does not sleep generically", sleeper.delays, [])
        check.equal("401 then 200 does not fetch a third bearer", tokens.callCount, 2)
        check.equal(
            "401 then 200 keeps the Web entry order",
            webSnapshot?.entries.map(\.uri),
            ["spotify:track:track-id"]
        )
    }
}

private let profileBody = Data(
    #"{"data":{"me":{"profile":{"username":"listener","name":"Listener"}}}}"#.utf8
)

private let queueBody = Data(
    #"{"currently_playing":null,"queue":[{"id":"track-id","uri":"spotify:track:track-id","name":"First Track","duration_ms":123000,"artists":[{"name":"First Artist"}],"album":{"name":"First Album"}}]}"#
        .utf8
)

private func queueCheckTrack(_ uri: String) -> CatalogTrack {
    CatalogTrack(
        id: uri,
        uri: uri,
        title: "Track",
        artist: "Artist",
        album: "Album",
        duration: 180,
        artworkURL: nil,
        addedAt: nil
    )
}

private struct UnusedQueueRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri, title: "Unused", artist: "Unused", artworkURL: nil, duration: 1
        )
    }
}

private final class ControllablePlaybackClock: PlaybackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func sleep(seconds _: TimeInterval) async throws {}
}

private func partnerAPI(
    transport: @escaping SpotifyCredentials.Transport,
    retryTiming: SpotifyTransientRetry.Timing = .immediate
) -> PartnerAPI {
    PartnerAPI(
        accessToken: { "fixture-access" },
        clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in },
        invalidateClientToken: { _ in },
        transport: transport,
        retryTiming: retryTiming
    )
}

private func timing(
    now: Date = Date(timeIntervalSince1970: 0),
    sleeper: RecordingSleeper,
    jitter: Double = 1
) -> SpotifyTransientRetry.Timing {
    SpotifyTransientRetry.Timing(
        now: { now },
        sleep: { try await sleeper.sleep($0) },
        unitJitter: { jitter }
    )
}

@MainActor
private func expectThrown<Failure: Error & Equatable>(
    _ check: CheckRunner,
    _ label: String,
    _ expected: Failure,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        check.check("\(label) throws", false)
    } catch let error as Failure {
        check.equal(label, error, expected)
    } catch {
        check.check("\(label) throws \(Failure.self), got \(error)", false)
    }
}

@MainActor
private func expectURLError(
    _ check: CheckRunner,
    _ label: String,
    _ code: URLError.Code,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        check.check("\(label) throws", false)
    } catch let error as URLError {
        check.equal("\(label) keeps URLError.code", error.code, code)
    } catch {
        check.check("\(label) throws URLError, got \(error)", false)
    }
}

private enum RetryStep {
    case http(status: Int, body: Data = Data(), headers: [String: String] = [:])
    case urlError(URLError.Code)
}

private final class ScriptedRetryTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [RetryStep]
    private var index = 0
    private var recordedMethods: [String] = []
    private var recordedURLs: [String] = []
    private var recordedClientTokens: [String] = []

    init(steps: [RetryStep]) {
        self.steps = steps
    }

    var callCount: Int {
        lock.withLock { index }
    }

    var methods: [String] {
        lock.withLock { recordedMethods }
    }

    var urls: [String] {
        lock.withLock { recordedURLs }
    }

    var clientTokens: [String] {
        lock.withLock { recordedClientTokens }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        let step = steps[index]
        index += 1
        recordedMethods.append(request.httpMethod ?? "GET")
        recordedURLs.append(request.url?.absoluteString ?? "")
        if let client = request.value(forHTTPHeaderField: "Client-Token"), !client.isEmpty {
            recordedClientTokens.append(client)
        }
        let url = request.url ?? URL(string: "https://example.invalid/")!
        switch step {
        case let .http(status, body, headers):
            return (
                body,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            )
        case let .urlError(code):
            throw URLError(code)
        }
    }
}

private final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var delays: [TimeInterval] {
        lock.withLock { recorded }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        lock.withLock { recorded.append(seconds) }
        try Task.checkCancellation()
    }
}

private final class ParkUntilCancelledSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    var delays: [TimeInterval] {
        lock.withLock { recorded }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            recorded.append(seconds)
            let waiter = started
            started = nil
            didStart = true
            return waiter
        }
        waiter?.resume()
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didStart {
                lock.unlock()
                continuation.resume()
            } else {
                started = continuation
                lock.unlock()
            }
        }
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

private actor ParkUntilCancelledInvalidator {
    private(set) var values: [String] = []
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    func park(_ value: String) async throws {
        values.append(value)
        let waiter = started
        started = nil
        didStart = true
        waiter?.resume()
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            if didStart {
                continuation.resume()
            } else {
                started = continuation
            }
        }
    }
}

private actor SharedToken {
    private var current: String

    init(_ value: String) {
        current = value
    }

    func value() -> String { current }

    func replace(_ rejected: String, with replacement: String) {
        if current == rejected {
            current = replacement
        }
    }
}

private final class BearerResponseTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let response: @Sendable (String?) -> RetryStep

    init(response: @escaping @Sendable (String?) -> RetryStep) {
        self.response = response
    }

    var callCount: Int {
        lock.withLock { index }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        index += 1
        lock.unlock()
        let url = request.url ?? URL(string: "https://example.invalid/")!
        switch response(SpotifyCredentials.accessTokenCarried(by: request)) {
        case let .http(status, body, headers):
            return (
                body,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            )
        case let .urlError(code):
            throw URLError(code)
        }
    }
}

private final class StartedGate: @unchecked Sendable {
    private let lock = NSLock()
    private let target: Int
    private var marked = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        target = count
    }

    func mark() {
        lock.lock()
        marked += 1
        let ready = marked >= target
        let toResume: [CheckedContinuation<Void, Never>]
        if ready {
            toResume = waiters
            waiters = []
        } else {
            toResume = []
        }
        lock.unlock()
        for waiter in toResume {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if marked >= target {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
