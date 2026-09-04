import Foundation

/// One cluster member as the engine observes it: identity and protobuf type name only.
/// Activity, sort, and unused Web API fields are not part of this row.
public struct ConnectProtocolDevice: Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: String

    public init(id: String, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }
}

/// App-facing Connect device list from unfiltered cluster members.
///
/// The cluster names one active device; members do not carry `is_active`. Empty
/// `activeDeviceID` means nothing is active anywhere and must clear activity.
public enum ConnectDeviceProjection: Sendable {
    public static func isActive(deviceID: String, activeDeviceID: String) -> Bool {
        !activeDeviceID.isEmpty && deviceID == activeDeviceID
    }

    /// Wire type is an open enum. An empty name has no variant to report.
    public static func normalizedType(_ type: String) -> String {
        type.isEmpty ? "UNKNOWN" : type
    }

    public static func devices(
        from protocolDevices: [ConnectProtocolDevice],
        activeDeviceID: String
    ) -> [ConnectDevice] {
        protocolDevices
            .sorted { $0.id < $1.id }
            .map { device in
                ConnectDevice(
                    id: device.id,
                    name: device.name,
                    type: normalizedType(device.type),
                    isActive: isActive(deviceID: device.id, activeDeviceID: activeDeviceID)
                )
            }
    }
}
