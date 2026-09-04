import Testing
import SpottyDomain
import Foundation

@Suite("Connection Snapshot Projection")
struct ConnectionSnapshotProjectionTests {
    @Test
    func testConnectionSnapshotProjection() {
        do {
            #expect(
                (ConnectionSnapshotProjection.sessionPhase(
                    connected: true,
                    spircReady: true,
                    lastError: nil
                )) == (.ready), "connected and ready is ready")
            #expect(
                (ConnectionSnapshotProjection.sessionPhase(
                    connected: false,
                    spircReady: false,
                    lastError: "session-timeout"
                )) == (.failed(ConnectionSnapshotProjection.connectionFailedMessage)),
                "a last error uses stable privacy-safe presentation"
            )
            #expect(
                (ConnectionSnapshotProjection.sessionPhase(
                    connected: true,
                    spircReady: false,
                    lastError: ""
                )) == nil, "connecting with an empty error has no phase yet")
            #expect(
                (ConnectionSnapshotProjection.sessionPhase(
                    connected: false,
                    spircReady: false,
                    lastError: nil
                )) == nil, "disconnected without an error has no phase yet")
            #expect(
                (ConnectionSnapshotProjection.sessionPhase(
                    connected: true,
                    spircReady: true,
                    lastError: "stale"
                )) == (.ready), "ready wins over a leftover error string")
            #expect(
                (ConnectionSnapshotProjection.sessionPhase(
                    connected: true,
                    spircReady: true,
                    credentialsRejected: true,
                    lastError: nil
                )) == (.failed(ConnectionSnapshotProjection.credentialsRejectedMessage)),
                "credential rejection wins over ready flags"
            )
            #expect(
                (ConnectionSnapshotProjection.sessionPhase(
                    connected: false,
                    spircReady: false,
                    credentialsRejected: true,
                    lastError: "private upstream detail"
                )) == (.failed(ConnectionSnapshotProjection.credentialsRejectedMessage)),
                "credential rejection wins over upstream error details"
            )

            #expect(
                (ConnectionSnapshotProjection.resolvedDeviceID(wire: "mac", fallback: "old")) == ("mac"),
                "a nonempty wire id wins")
            #expect(
                (ConnectionSnapshotProjection.resolvedDeviceID(wire: "", fallback: "old")) == ("old"),
                "an empty wire id uses the fallback")
            #expect(
                (ConnectionSnapshotProjection.resolvedDeviceID(wire: nil, fallback: "old")) == ("old"),
                "a missing wire id uses the fallback")
            #expect(
                (ConnectionSnapshotProjection.resolvedDeviceID(wire: "", fallback: nil)) == nil,
                "empty wire and empty fallback stay missing")
        }
    }
}
