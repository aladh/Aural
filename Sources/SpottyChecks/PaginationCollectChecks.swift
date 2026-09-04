import SpottyDomain
import Foundation

private enum WalkProbe: Error, Equatable {
    case boom
}

func runPaginationCollectChecks(_ check: CheckRunner) async {
    await check.suite("Bounded pagination collect") {
        let ordinary = OffsetRecorder()
        await expectCollect(
            check,
            "ordinary totalCount concatenates pages in order",
            expected: [0, 1, 2]
        ) { offset in
            ordinary.record(offset)
            if offset == 0 {
                return Pagination.Page(items: [0, 1], pageEntryCount: 2, totalCount: 3)
            }
            return Pagination.Page(items: [2], pageEntryCount: 1, totalCount: 3)
        }
        check.equal("ordinary totalCount fetches each named offset once", ordinary.values, [0, 2])

        let boundary = OffsetRecorder()
        await expectCollect(
            check,
            "exact page-boundary totalCount does not fetch past the last page",
            expected: [0, 1, 2, 3]
        ) { offset in
            boundary.record(offset)
            return Pagination.Page(
                items: [offset, offset + 1],
                pageEntryCount: 2,
                totalCount: 4
            )
        }
        check.equal("exact page-boundary fetches two pages", boundary.values, [0, 2])

        await expectCollect(
            check,
            "omitted totalCount ends on a final empty page",
            expected: [0, 1]
        ) { offset in
            if offset == 0 {
                return Pagination.Page(items: [0, 1], pageEntryCount: 2, totalCount: nil)
            }
            return Pagination.Page(items: [], pageEntryCount: 0, totalCount: nil)
        }

        await expectCollect(
            check,
            "empty first page yields no items",
            expected: []
        ) { _ in
            Pagination.Page(items: [Int](), pageEntryCount: 0, totalCount: 0)
        }

        let zeroCap = OffsetRecorder()
        await expectThrown(
            check,
            "a zero page cap fails before any fetch",
            Pagination.Failure.pageLimitReached
        ) {
            _ = try await Pagination.collect(maximumPageCount: 0) { offset in
                zeroCap.record(offset)
                return Pagination.Page(items: [offset], pageEntryCount: 0, totalCount: 0)
            }
        }
        check.equal("a zero page cap does not fetch", zeroCap.values, [])

        let capOffsets = OffsetRecorder()
        await expectThrown(
            check,
            "cap exhaustion fails instead of returning a partial list",
            Pagination.Failure.pageLimitReached
        ) {
            _ = try await Pagination.collect(maximumPageCount: 2) { offset in
                capOffsets.record(offset)
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: nil)
            }
        }
        check.equal("cap exhaustion fetches exactly the allowed pages", capOffsets.values, [0, 1])

        let stalled = OffsetRecorder()
        await expectThrown(
            check,
            "a non-progressing offset fails rather than looping",
            Pagination.Failure.offsetDidNotAdvance
        ) {
            _ = try await Pagination.collect(
                maximumPageCount: 4,
                nextOffset: { offset, _, _ in offset }
            ) { offset in
                stalled.record(offset)
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: nil)
            }
        }
        check.equal("a non-progressing response is fetched once", stalled.values, [0])

        let thrown = OffsetRecorder()
        await expectThrown(
            check,
            "fetch errors propagate without a partial success",
            WalkProbe.boom
        ) {
            _ = try await Pagination.collect { offset in
                thrown.record(offset)
                if offset > 0 { throw WalkProbe.boom }
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: 10)
            }
        }
        check.equal("a mid-walk error stops after the failing page", thrown.values, [0, 1])

        let parked = ReleaseGate()
        let fetches = OffsetRecorder()
        let pending = Task {
            try await Pagination.collect { offset in
                fetches.record(offset)
                if offset > 0 {
                    await parked.park()
                    return Pagination.Page(items: [Int](), pageEntryCount: 0, totalCount: nil)
                }
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: nil)
            }
        }
        await parked.waitUntilEntered()
        pending.cancel()
        parked.open()
        var cancelled = false
        do {
            _ = try await pending.value
        } catch is CancellationError {
            cancelled = true
        } catch {
            check.check("cancellation stays CancellationError, got \(error)", false)
        }
        check.check("a cancelled walk does not succeed after a terminal page returns", cancelled)
        check.equal("cancellation does not fetch past the parked page", fetches.values, [0, 1])
    }
}

private func expectCollect(
    _ check: CheckRunner,
    _ label: String,
    expected: [Int],
    fetchPage: @escaping @Sendable (Int) async throws -> Pagination.Page<Int>
) async {
    do {
        let items = try await Pagination.collect(maximumPageCount: 8, fetchPage: fetchPage)
        check.equal(label, items, expected)
    } catch {
        check.check("\(label) succeeds, got \(error)", false)
    }
}

private func expectThrown<Failure: Error & Equatable>(
    _ check: CheckRunner,
    _ label: String,
    _ expected: Failure,
    perform: @escaping () async throws -> Void
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

private final class OffsetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    var values: [Int] {
        lock.withLock { recorded }
    }

    func record(_ offset: Int) {
        lock.lock()
        recorded.append(offset)
        lock.unlock()
    }
}

private final class ReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: CheckedContinuation<Void, Never>?
    private var parked: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var released = false

    func waitUntilEntered() async {
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

    func park() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            hasEntered = true
            let enteredWaiter = entered
            entered = nil
            if released {
                lock.unlock()
                enteredWaiter?.resume()
                continuation.resume()
            } else {
                parked = continuation
                lock.unlock()
                enteredWaiter?.resume()
            }
        }
    }

    func open() {
        lock.lock()
        released = true
        let parked = parked
        self.parked = nil
        lock.unlock()
        parked?.resume()
    }
}
