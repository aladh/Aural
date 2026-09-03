import Foundation

func runBrandIdentityChecks(_ check: CheckRunner) {
    check.suite("Spotty display identity preserves technical identities") {
        check.noThrow("bundle display metadata is separated from technical identity") {
            let info = try propertyList(named: "Packaging/Info.plist")
            check.check("bundle display name is Spotty", info["CFBundleDisplayName"] as? String == "Spotty")
            check.check("bundle name is Spotty", info["CFBundleName"] as? String == "Spotty")
            check.check("bundle executable remains Aural", info["CFBundleExecutable"] as? String == "Aural")
            check.check("bundle icon resource remains Aural", info["CFBundleIconFile"] as? String == "Aural")
            check.check("bundle identifier remains stable", info["CFBundleIdentifier"] as? String == "dev.aural.app")
        }

        check.noThrow("main scene uses the Spotty display name") {
            let app = try sourceFile(named: "Sources/Aural/AuralApp.swift")
            check.check("main window title is Spotty", app.contains("Window(\"Spotty\", id: \"main\")"))
            check.check("Swift app type identity remains AuralApp", app.contains("struct AuralApp: App"))
        }

        check.noThrow("SwiftPM product and target identities remain stable") {
            let package = try sourceFile(named: "Package.swift")
            check.check("SwiftPM package name remains Aural", package.contains("name: \"Aural\","))
            check.check(
                "SwiftPM app product remains Aural",
                package.contains(".executable(name: \"Aural\", targets: [\"AuralApp\"])")
            )
            check.check("AuralCore source path remains stable", package.contains("path: \"Sources/Aural\""))
            check.check("AuralApp target remains stable", package.contains("name: \"AuralApp\""))
        }

        check.noThrow("persistent and diagnostic technical identifiers remain stable") {
            let keychain = try sourceFile(named: "Sources/Aural/Spotify/KeychainManager.swift")
            check.check(
                "keychain service remains stable",
                keychain.contains("keymasterService = \"dev.aural.app.keymaster\"")
            )

            let defaults = try sourceFile(named: "Sources/Aural/Spotify/KeymasterTokenStore.swift")
            check.check(
                "legacy defaults migration key remains stable",
                defaults.contains("key = \"keymaster.tokens.v1\"")
            )

            let clientToken = try sourceFile(named: "Sources/Aural/Spotify/ClientTokenProvider.swift")
            check.check(
                "local device defaults key remains stable",
                clientToken.contains("key = \"keymasterDeviceId\"")
            )

            let logging = try sourceFile(named: "Sources/Aural/Spotify/DebugLog.swift")
            check.check(
                "unified log subsystem remains stable",
                logging.contains("static let subsystem = \"dev.aural.app\"")
            )

            let playback = try sourceFile(named: "Sources/Aural/Spotify/PlaybackStore.swift")
            check.check(
                "local device label remains Swift-owned",
                playback.contains("let thisDeviceName = \"This Mac\"")
            )

            let credentials = try sourceFile(named: "Backend/aural-playback/src/session_lifecycle.rs")
            check.check(
                "credential directory remains Aural-named",
                credentials.contains(".join(\"Aural\")")
                    && credentials.contains(".join(\"credentials\")")
            )

            let launcher = try sourceFile(named: "script/build_and_run.sh")
            check.check(
                "launcher process and bundle identities remain stable",
                launcher.contains("app_name=\"Aural\"")
                    && launcher.contains("app_bundle=\"$root_dir/Aural.app\"")
                    && launcher.contains("Contents/MacOS/Aural")
            )

            let release = try sourceFile(named: ".github/workflows/release.yml")
            check.check(
                "release presentation is Spotty while artifacts remain Aural-named",
                release.contains("--title \"Spotty $version\"")
                    && release.contains("Aural-$version-arm64.zip")
            )
        }
    }
}

private enum BrandIdentityReadError: Error {
    case invalidPropertyList
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func sourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: repositoryRoot().appending(path: relativePath), encoding: .utf8)
}

private func propertyList(named relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repositoryRoot().appending(path: relativePath))
    var format = PropertyListSerialization.PropertyListFormat.xml
    let value = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
    guard let dictionary = value as? [String: Any] else {
        throw BrandIdentityReadError.invalidPropertyList
    }
    return dictionary
}
