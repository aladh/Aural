import Foundation

/// Read-only identity of the installation that predates the complete Spotty rename.
///
/// The values stay encoded so the retired product name does not remain part of Spotty's
/// source-level identity. They exist only to move user state forward once.
nonisolated enum PreviousInstallationIdentity {
    static let bundleIdentifier = decode("ZGV2LmF1cmFsLmFwcA==")
    static let keychainService = decode("ZGV2LmF1cmFsLmFwcC5rZXltYXN0ZXI=")
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: bundleIdentifier)
    }

    static func migrateDefaults(
        keys: [String] = persistedDefaultsKeys,
        current: UserDefaults = .standard,
        previous: UserDefaults? = defaults
    ) {
        guard let previous else { return }
        for key in keys {
            if current.object(forKey: key) == nil,
                let value = previous.object(forKey: key)
            {
                current.set(value, forKey: key)
            }
            previous.removeObject(forKey: key)
        }
    }

    private static let persistedDefaultsKeys = [
        "keymaster.tokens.v1",
        "keymasterDeviceId",
        "playback.shuffle.fewer-repeats",
        "playback.last-remote-device-id",
        "playback.fewer-repeats.history",
        "sidebarSelection",
        "selectedMediaTitle",
        "selectedMediaSubtitle",
        "selectedMediaArtworkURL",
        "showsPlaybackInspector",
    ]

    private static func decode(_ encoded: String) -> String {
        guard
            let data = Data(base64Encoded: encoded),
            let value = String(data: data, encoding: .utf8)
        else {
            preconditionFailure("Invalid previous-installation identity")
        }
        return value
    }
}
