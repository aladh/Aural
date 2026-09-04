import Foundation
import SystemConfiguration

/// Swift-owned policy for the name advertised to Spotify Connect.
nonisolated enum ConnectDeviceIdentity {
    static let fallbackComputerName = "Mac"

    static func advertisedName(computerName: String?) -> String {
        let trimmed = computerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = trimmed.isEmpty ? fallbackComputerName : trimmed
        return "\(resolved) (Spotty)"
    }

    static var current: String {
        advertisedName(computerName: systemComputerName())
    }

    private static func systemComputerName() -> String? {
        // Use the user-facing Computer Name from System Settings, not a DNS hostname.
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }
}
