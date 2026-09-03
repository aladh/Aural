import AuralDomain
import Foundation

func runConnectDeviceProjectionChecks(_ check: CheckRunner) {
    func proto(_ id: String, name: String, type: String) -> ConnectProtocolDevice {
        ConnectProtocolDevice(id: id, name: name, type: type)
    }

    check.suite("Connect device projection") {
        check.check(
            "matching nonempty active id is active",
            ConnectDeviceProjection.isActive(deviceID: "mac", activeDeviceID: "mac")
        )
        check.check(
            "a different device is not active",
            !ConnectDeviceProjection.isActive(deviceID: "mac", activeDeviceID: "phone")
        )
        check.check(
            "an empty active id clears activity",
            !ConnectDeviceProjection.isActive(deviceID: "mac", activeDeviceID: "")
        )
        check.equal(
            "empty type becomes UNKNOWN",
            ConnectDeviceProjection.normalizedType(""),
            "UNKNOWN"
        )
        check.equal(
            "named unknown types are preserved",
            ConnectDeviceProjection.normalizedType("TOASTER"),
            "TOASTER"
        )
        check.equal(
            "a named Unknown variant is not rewritten",
            ConnectDeviceProjection.normalizedType("Unknown"),
            "Unknown"
        )

        let projected = ConnectDeviceProjection.devices(
            from: [
                proto("speaker", name: "Speaker", type: "Speaker"),
                proto("mac", name: "Mac", type: "Computer"),
                proto("unknown", name: "Odd", type: ""),
            ],
            activeDeviceID: "mac"
        )
        check.equal("projection sorts by id", projected.map(\.id), ["mac", "speaker", "unknown"])
        check.equal("active member is marked", projected[0].isActive, true)
        check.equal("other members stay inactive", projected[1].isActive, false)
        check.equal("empty type is UNKNOWN", projected[2].type, "UNKNOWN")
        check.equal("unknown type uses the default icon", projected[2].symbolName, "hifispeaker")

        let noneActive = ConnectDeviceProjection.devices(
            from: [proto("mac", name: "Mac", type: "Computer")],
            activeDeviceID: ""
        )
        check.check(
            "empty cluster active id clears the listed device",
            noneActive.allSatisfy { !$0.isActive }
        )
    }
}
