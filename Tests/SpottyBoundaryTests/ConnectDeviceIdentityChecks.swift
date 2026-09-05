import Testing
import Foundation
@testable import SpottyCore

@Suite("Connect Device Identity")
struct ConnectDeviceIdentityTests {
    @Test
    @MainActor
    func testConnectDeviceIdentity() {
        do {
            #expect(
                (ConnectDeviceIdentity.advertisedName(computerName: "Studio Mac")) == ("Studio Mac (Spotty)"),
                "Computer Name is followed by the app name")
            #expect(
                (ConnectDeviceIdentity.advertisedName(computerName: "  Studio Mac\n")) == ("Studio Mac (Spotty)"),
                "Computer Name is trimmed")
            #expect(
                (ConnectDeviceIdentity.advertisedName(computerName: nil)) == ("Mac (Spotty)"),
                "missing Computer Name has a natural fallback")
        }

    }
}
