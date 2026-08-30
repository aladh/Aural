import Foundation
import Observation

/// Stand-in for `CatalogPlaybackAccess`: init stores the observable without reading
/// facts; leaves observe by reading computed properties.
@Observable
private final class CatalogPlaybackFactProbe {
    var isConnected = false
    var trackURI = ""
}

private struct CatalogPlaybackFactAccess {
    private let probe: CatalogPlaybackFactProbe

    init(probe: CatalogPlaybackFactProbe) {
        self.probe = probe
    }

    var isConnected: Bool { probe.isConnected }
    var currentTrackURI: String { probe.trackURI }
}

private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

func runCatalogPlaybackAccessObservationChecks(_ check: CheckRunner) {
    check.suite("Catalog playback access observation topology") {
        let probe = CatalogPlaybackFactProbe()
        let constructFlag = ObservationFlag()
        let access = withObservationTracking {
            CatalogPlaybackFactAccess(probe: probe)
        } onChange: {
            constructFlag.fired = true
        }

        probe.isConnected = true
        probe.trackURI = "spotify:track:access"
        check.check("constructing access does not observe playback facts", !constructFlag.fired)
        check.equal("a later fact read still follows the probe", access.isConnected, true)
        check.equal("currentTrackURI follows the probe", access.currentTrackURI, "spotify:track:access")

        let trackFlag = ObservationFlag()
        withObservationTracking {
            _ = access.currentTrackURI
        } onChange: {
            trackFlag.fired = true
        }
        probe.trackURI = "spotify:track:next"
        check.check("a leaf that reads the current track observes URI changes", trackFlag.fired)

        let connectedFlag = ObservationFlag()
        withObservationTracking {
            _ = access.isConnected
        } onChange: {
            connectedFlag.fired = true
        }
        probe.isConnected = false
        check.check("a leaf that reads isConnected observes that fact", connectedFlag.fired)
    }
}
