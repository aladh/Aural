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

        let queueTransport = ScriptedRetryTransport(steps: [
            .http(status: 429, headers: ["Retry-After": "1"]),
            .http(status: 200, body: queueBody),
        ])
        let tracks = try? await SpotifyWebPlayerAPI(
            accessToken: { "queue-a" },
            invalidateAccessToken: { _ in },
            transport: queueTransport.send,
            retryTiming: .immediate
        ).queue()
        check.equal("Web queue 429 retries", tracks?.map(\.uri), ["spotify:track:track-id"])
        check.equal("Web queue 429 attempts twice", queueTransport.callCount, 2)
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
        check.equal("401 invalidation still happens once", await accessB.values, ["b"])

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
}

private let profileBody = Data(
    #"{"data":{"me":{"profile":{"username":"listener","name":"Listener"}}}}"#.utf8
)

private let queueBody = Data(
    #"{"currently_playing":null,"queue":[{"id":"track-id","uri":"spotify:track:track-id","name":"First Track","duration_ms":123000,"artists":[{"name":"First Artist"}],"album":{"name":"First Album"}}]}"#
        .utf8
)

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

    init(steps: [RetryStep]) {
        self.steps = steps
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
        defer { lock.unlock() }
        let step = steps[index]
        index += 1
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
