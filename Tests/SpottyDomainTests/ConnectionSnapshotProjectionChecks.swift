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
                )) == (.failed("session-timeout")), "a last error while disconnected is failed")
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
