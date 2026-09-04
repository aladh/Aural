import SpottyDomain
import Foundation

func runConnectionSnapshotProjectionChecks(_ check: CheckRunner) {
    check.suite("Connection snapshot projection") {
        check.equal(
            "connected and ready is ready",
            ConnectionSnapshotProjection.sessionPhase(
                connected: true,
                spircReady: true,
                lastError: nil
            ),
            .ready
        )
        check.equal(
            "a last error while disconnected is failed",
            ConnectionSnapshotProjection.sessionPhase(
                connected: false,
                spircReady: false,
                lastError: "session-timeout"
            ),
            .failed("session-timeout")
        )
        check.nil_(
            "connecting with an empty error has no phase yet",
            ConnectionSnapshotProjection.sessionPhase(
                connected: true,
                spircReady: false,
                lastError: ""
            )
        )
        check.nil_(
            "disconnected without an error has no phase yet",
            ConnectionSnapshotProjection.sessionPhase(
                connected: false,
                spircReady: false,
                lastError: nil
            )
        )
        check.equal(
            "ready wins over a leftover error string",
            ConnectionSnapshotProjection.sessionPhase(
                connected: true,
                spircReady: true,
                lastError: "stale"
            ),
            .ready
        )

        check.equal(
            "a nonempty wire id wins",
            ConnectionSnapshotProjection.resolvedDeviceID(wire: "mac", fallback: "old"),
            "mac"
        )
        check.equal(
            "an empty wire id uses the fallback",
            ConnectionSnapshotProjection.resolvedDeviceID(wire: "", fallback: "old"),
            "old"
        )
        check.equal(
            "a missing wire id uses the fallback",
            ConnectionSnapshotProjection.resolvedDeviceID(wire: nil, fallback: "old"),
            "old"
        )
        check.nil_(
            "empty wire and empty fallback stay missing",
            ConnectionSnapshotProjection.resolvedDeviceID(wire: "", fallback: nil)
        )
    }
}
