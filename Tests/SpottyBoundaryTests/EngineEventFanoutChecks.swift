import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

/// Barrier-controlled checks for process-local engine event delivery order.
///
/// Timeouts are hang watchdogs only. Thread A/B ordering is forced with semaphores, not sleeps.
@Suite("Engine Event Fanout")
struct EngineEventFanoutTests {
    @Test
    @MainActor
    func testEngineEventFanout() {
        do {
            let inverted = AssignThenYieldAfterUnlockFanout()
            #expect(
                (collectInversionSchedule(inverted)) == ([2, 1]),
                "assign-then-yield-after-unlock delivers B before A under A-prepare/B-complete/A-yield")

            let serialized = EngineEventFanout(clock: SystemPlaybackClock())
            #expect(
                (collectInversionSchedule(serialized)) == ([1, 2]),
                "serialized assignment and delivery keeps A before B under the same schedule")

            let multi = EngineEventFanout(clock: SystemPlaybackClock())
            let both = collectInversionSchedule(multi, subscriberCount: 2)
            #expect((both[0]) == ([1, 2]), "first subscriber sees increasing sequences under inversion schedule")
            #expect((both[1]) == ([1, 2]), "second subscriber sees the same increasing sequences")

            let kinds = EngineEventFanout(clock: SystemPlaybackClock())
            #expect(
                (collectSequential(
                    kinds,
                    events: [
                        playbackEvent(),
                        queueEvent(),
                        connectionEvent(),
                        devicesEvent(),
                    ]
                ).map(\.sequence)) == ([1, 2, 3, 4]),
                "mixed playback/queue/connection/devices kinds stay in assigned order"
            )

            runTerminationAroundDelivery()
            runTerminationDuringDelivery()
            runEmitAfterLastSubscriber()
            runFixedClockReceiptTimestamps()
        }
    }
}

private protocol TestableEventFanout: AnyObject, Sendable {
    func events(
        onStart: (@Sendable () -> Void)?,
        onTermination: (@Sendable () -> Void)?
    ) -> AsyncStream<RustPlaybackEventEnvelope>
    func emit(_ event: RustPlaybackEvent, afterPrepare: (@Sendable () -> Void)?)
}

extension EngineEventFanout: TestableEventFanout {}

/// Replica of the pre-fix `RustPlaybackEngine.emit`: sequence under the lock, yield after unlock.
private final class AssignThenYieldAfterUnlockFanout: TestableEventFanout, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RustPlaybackEventEnvelope>.Continuation] = [:]
    private var sequence: UInt64 = 0

    func events(
        onStart: (@Sendable () -> Void)?,
        onTermination: (@Sendable () -> Void)?
    ) -> AsyncStream<RustPlaybackEventEnvelope> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
                onTermination?()
            }
            onStart?()
        }
    }

    func emit(_ event: RustPlaybackEvent, afterPrepare: (@Sendable () -> Void)?) {
        let (envelope, targets) = lockedPrepare(event)
        afterPrepare?()
        for continuation in targets {
            continuation.yield(envelope)
        }
    }

    private func lockedPrepare(
        _ event: RustPlaybackEvent
    ) -> (RustPlaybackEventEnvelope, [AsyncStream<RustPlaybackEventEnvelope>.Continuation]) {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        let envelope = RustPlaybackEventEnvelope(
            sequence: sequence,
            receivedAt: Date(),
            event: event
        )
        return (envelope, Array(continuations.values))
    }
}

private func collectInversionSchedule(_ fanout: some TestableEventFanout) -> [UInt64] {
    collectInversionSchedule(fanout, subscriberCount: 1)[0]
}

private func collectInversionSchedule(
    _ fanout: some TestableEventFanout,
    subscriberCount: Int
) -> [[UInt64]] {
    let expectedCount = 2
    var recorders: [FanoutRecorder<UInt64>] = []
    var subscribed: [DispatchSemaphore] = []
    var collected: [DispatchSemaphore] = []
    for _ in 0..<subscriberCount {
        let recorder = FanoutRecorder<UInt64>()
        let start = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        recorders.append(recorder)
        subscribed.append(start)
        collected.append(done)
        let stream = fanout.events(onStart: { start.signal() }, onTermination: nil)
        Task.detached {
            var values: [UInt64] = []
            for await envelope in stream {
                values.append(envelope.sequence)
                if values.count == expectedCount { break }
            }
            recorder.store(values)
            done.signal()
        }
    }
    guard subscribed.allSatisfy({ wait($0) }) else {
        return Array(repeating: [], count: subscriberCount)
    }

    let preparedA = DispatchSemaphore(value: 0)
    let releaseA = DispatchSemaphore(value: 0)
    let finishedA = DispatchSemaphore(value: 0)
    let finishedB = DispatchSemaphore(value: 0)

    Thread.detachNewThread {
        fanout.emit(playbackEvent()) {
            preparedA.signal()
            _ = wait(releaseA)
        }
        finishedA.signal()
    }
    guard wait(preparedA) else {
        return Array(repeating: [], count: subscriberCount)
    }

    Thread.detachNewThread {
        fanout.emit(queueEvent(), afterPrepare: nil)
        finishedB.signal()
    }
    guard wait(finishedB) else {
        return Array(repeating: [], count: subscriberCount)
    }
    releaseA.signal()
    guard wait(finishedA) else {
        return Array(repeating: [], count: subscriberCount)
    }

    var results: [[UInt64]] = []
    for (index, gate) in collected.enumerated() {
        if wait(gate) {
            results.append(recorders[index].load())
        } else {
            results.append([])
        }
    }
    return results
}

private func collectSequential(
    _ fanout: EngineEventFanout,
    events: [RustPlaybackEvent]
) -> [RustPlaybackEventEnvelope] {
    collectSequential(fanout, events: events, subscriberCount: 1)[0]
}

private func collectSequential(
    _ fanout: EngineEventFanout,
    events: [RustPlaybackEvent],
    subscriberCount: Int
) -> [[RustPlaybackEventEnvelope]] {
    let expected = events.count
    var recorders: [FanoutRecorder<RustPlaybackEventEnvelope>] = []
    var subscribed: [DispatchSemaphore] = []
    var collected: [DispatchSemaphore] = []
    for _ in 0..<subscriberCount {
        let recorder = FanoutRecorder<RustPlaybackEventEnvelope>()
        let start = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        recorders.append(recorder)
        subscribed.append(start)
        collected.append(done)
        let stream = fanout.events(onStart: { start.signal() }, onTermination: nil)
        Task.detached {
            var values: [RustPlaybackEventEnvelope] = []
            for await envelope in stream {
                values.append(envelope)
                if values.count == expected { break }
            }
            recorder.store(values)
            done.signal()
        }
    }
    guard subscribed.allSatisfy({ wait($0) }) else {
        return Array(repeating: [], count: subscriberCount)
    }
    for event in events {
        fanout.emit(event)
    }
    var results: [[RustPlaybackEventEnvelope]] = []
    for (index, gate) in collected.enumerated() {
        if wait(gate) {
            results.append(recorders[index].load())
        } else {
            results.append([])
        }
    }
    return results
}

@MainActor
private func runTerminationAroundDelivery() {
    let fanout = EngineEventFanout(clock: SystemPlaybackClock())
    let surviving = FanoutRecorder<UInt64>()
    let survivingStart = DispatchSemaphore(value: 0)
    let survivingDone = DispatchSemaphore(value: 0)
    let cancelledStart = DispatchSemaphore(value: 0)
    let cancelledTerminated = DispatchSemaphore(value: 0)
    let cancelledDone = DispatchSemaphore(value: 0)

    let survivingStream = fanout.events(onStart: { survivingStart.signal() }, onTermination: nil)
    Task.detached {
        var values: [UInt64] = []
        for await envelope in survivingStream {
            values.append(envelope.sequence)
            if values.count == 2 { break }
        }
        surviving.store(values)
        survivingDone.signal()
    }

    let cancelledStream = fanout.events(
        onStart: { cancelledStart.signal() },
        onTermination: { cancelledTerminated.signal() }
    )
    let cancelledTask = Task.detached {
        for await _ in cancelledStream {}
        cancelledDone.signal()
    }

    guard wait(survivingStart), wait(cancelledStart) else {
        #expect((false) == true, "termination-around subscribers started")
        return
    }

    let preparedA = DispatchSemaphore(value: 0)
    let releaseA = DispatchSemaphore(value: 0)
    let finishedA = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        fanout.emit(playbackEvent()) {
            preparedA.signal()
            _ = wait(releaseA)
        }
        finishedA.signal()
    }
    guard wait(preparedA) else {
        #expect((false) == true, "A paused before yield")
        return
    }
    cancelledTask.cancel()
    #expect(
        (wait(cancelledTerminated) && wait(cancelledDone)) == true,
        "cancelled subscriber terminates while A is paused before yield")

    Thread.detachNewThread {
        fanout.emit(queueEvent())
    }
    releaseA.signal()
    #expect((wait(finishedA) && wait(survivingDone)) == true, "delivery after cancel completes")
    #expect((surviving.load()) == ([1, 2]), "surviving subscriber still receives both assigned sequences")
}

@MainActor
private func runTerminationDuringDelivery() {
    let fanout = EngineEventFanout(clock: SystemPlaybackClock())
    let surviving = FanoutRecorder<UInt64>()
    let partial = FanoutRecorder<UInt64>()
    let survivingStart = DispatchSemaphore(value: 0)
    let partialStart = DispatchSemaphore(value: 0)
    let survivingDone = DispatchSemaphore(value: 0)
    let partialDone = DispatchSemaphore(value: 0)
    let sawFirst = DispatchSemaphore(value: 0)

    let survivingStream = fanout.events(onStart: { survivingStart.signal() }, onTermination: nil)
    Task.detached {
        var values: [UInt64] = []
        for await envelope in survivingStream {
            values.append(envelope.sequence)
            if values.count == 2 { break }
        }
        surviving.store(values)
        survivingDone.signal()
    }

    let partialStream = fanout.events(onStart: { partialStart.signal() }, onTermination: nil)
    Task.detached {
        var values: [UInt64] = []
        for await envelope in partialStream {
            values.append(envelope.sequence)
            sawFirst.signal()
            break
        }
        partial.store(values)
        partialDone.signal()
    }

    guard wait(survivingStart), wait(partialStart) else {
        #expect((false) == true, "termination-during subscribers started")
        return
    }
    fanout.emit(playbackEvent())
    #expect((wait(sawFirst)) == true, "partial subscriber observed the first envelope")
    fanout.emit(queueEvent())
    #expect((wait(survivingDone) && wait(partialDone)) == true, "both consumers finished after the second emit")
    #expect((partial.load()) == ([1]), "partial subscriber received the first envelope once")
    #expect((surviving.load()) == ([1, 2]), "surviving subscriber received both envelopes once")
}

@MainActor
private func runEmitAfterLastSubscriber() {
    let fanout = EngineEventFanout(clock: SystemPlaybackClock())
    let terminated = DispatchSemaphore(value: 0)
    let start = DispatchSemaphore(value: 0)
    let stream = fanout.events(
        onStart: { start.signal() },
        onTermination: { terminated.signal() }
    )
    let task = Task.detached {
        for await _ in stream {}
    }
    guard wait(start) else {
        #expect((false) == true, "last-subscriber start")
        return
    }
    task.cancel()
    #expect((wait(terminated)) == true, "last subscriber termination is observed")
    fanout.emit(playbackEvent())
    fanout.emit(queueEvent())
    let after = collectSequential(fanout, events: [connectionEvent(), devicesEvent()]).map(\.sequence)
    #expect((after) == ([3, 4]), "later subscriber observes later sequences without duplicates or a rewind")
}

@MainActor
private func runFixedClockReceiptTimestamps() {
    let origin = Date(timeIntervalSince1970: 2_000_000)
    let frozen = EngineEventFanout(clock: FrozenFanoutClock(date: origin))
    let events = [
        playbackEvent(),
        queueEvent(),
        connectionEvent(),
        devicesEvent(),
    ]
    let both = collectSequential(frozen, events: events, subscriberCount: 2)
    let sequences = both.map { $0.map(\.sequence) }
    let receipts = both.map { $0.map(\.receivedAt) }
    #expect((sequences[0]) == ([1, 2, 3, 4]), "first subscriber sees increasing sequences under a frozen clock")
    #expect((sequences[1]) == ([1, 2, 3, 4]), "second subscriber sees the same sequences")
    #expect(
        (receipts[0]) == (Array(repeating: origin, count: events.count)),
        "every event kind is stamped with the injected receipt time")
    #expect((receipts[1]) == (receipts[0]), "both subscribers observe the same receipt timestamps")
}

private func wait(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + .seconds(5)) == .success
}

private struct FrozenFanoutClock: PlaybackClock {
    let date: Date
    func now() -> Date { date }
    func sleep(seconds _: TimeInterval) async throws {}
}

private final class FanoutRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func store(_ values: [Value]) {
        lock.lock()
        self.values = values
        lock.unlock()
    }

    func load() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func playbackEvent() -> RustPlaybackEvent {
    .playback(
        RustPlaybackState(
            revision: 1,
            sessionGeneration: 1,
            isPlaying: false,
            isPaused: true,
            trackURI: "spotify:track:a",
            positionMS: 0,
            durationMS: 1,
            timestampMS: 0,
            shuffle: false,
            repeatTrack: false,
            repeatContext: false
        )
    )
}

private func queueEvent() -> RustPlaybackEvent {
    .queue(
        RustQueueState(
            revision: 1,
            sessionGeneration: 1,
            track: nil,
            protocolNextTracks: [],
            protocolPrevTracks: [],
            queueRevision: "",
            disallowSetQueue: false,
            disallowRemovingFromNextTracks: false
        )
    )
}

private func connectionEvent() -> RustPlaybackEvent {
    .connection(
        RustConnectionState(
            revision: 1,
            sessionGeneration: 1,
            sessionConnected: true,
            spircReady: true,
            isActiveDevice: false,
            resumePending: false,
            lastError: nil,
            deviceID: "local"
        )
    )
}

private func devicesEvent() -> RustPlaybackEvent {
    .devices(
        RustDevicesState(
            revision: 1,
            sessionGeneration: 1,
            activeDeviceID: "local",
            devices: [
                ConnectProtocolDevice(id: "local", name: "Spotty", type: "computer")
            ]
        )
    )
}
