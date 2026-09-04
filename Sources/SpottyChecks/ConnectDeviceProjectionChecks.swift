import Testing
import SpottyDomain
import Foundation

@Test
func testConnectDeviceProjection() {
    func proto(_ id: String, name: String, type: String) -> ConnectProtocolDevice {
        ConnectProtocolDevice(id: id, name: name, type: type)
    }

    do {
        #expect(
            (ConnectDeviceProjection.isActive(deviceID: "mac", activeDeviceID: "mac")) == true,
            "matching nonempty active id is active")
        #expect(
            (!ConnectDeviceProjection.isActive(deviceID: "mac", activeDeviceID: "phone")) == true,
            "a different device is not active")
        #expect(
            (!ConnectDeviceProjection.isActive(deviceID: "mac", activeDeviceID: "")) == true,
            "an empty active id clears activity")
        #expect((ConnectDeviceProjection.normalizedType("")) == ("UNKNOWN"), "empty type becomes UNKNOWN")
        #expect((ConnectDeviceProjection.normalizedType("TOASTER")) == ("TOASTER"), "named unknown types are preserved")
        #expect(
            (ConnectDeviceProjection.normalizedType("Unknown")) == ("Unknown"),
            "a named Unknown variant is not rewritten")

        let projected = ConnectDeviceProjection.devices(
            from: [
                proto("speaker", name: "Speaker", type: "Speaker"),
                proto("mac", name: "Mac", type: "Computer"),
                proto("unknown", name: "Odd", type: ""),
            ],
            activeDeviceID: "mac"
        )
        #expect((projected.map(\.id)) == (["mac", "speaker", "unknown"]), "projection sorts by id")
        #expect((projected[0].isActive) == (true), "active member is marked")
        #expect((projected[1].isActive) == (false), "other members stay inactive")
        #expect((projected[2].type) == ("UNKNOWN"), "empty type is UNKNOWN")
        #expect((projected[2].symbolName) == ("hifispeaker"), "unknown type uses the default icon")

        let noneActive = ConnectDeviceProjection.devices(
            from: [proto("mac", name: "Mac", type: "Computer")],
            activeDeviceID: ""
        )
        #expect((noneActive.allSatisfy { !$0.isActive }) == true, "empty cluster active id clears the listed device")
    }
}
