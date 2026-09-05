//
//  DebugLog.swift
//  Spotty
//
//  Privacy-safe Unified Logging shared by debug and release builds.
//

import Foundation
import OSLog

nonisolated enum SpottyLog {
    static let subsystem = "dev.spotty.app"
    static let account = Logger(subsystem: subsystem, category: "Account")
    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    static let playback = Logger(subsystem: subsystem, category: "Playback")
    static let queue = Logger(subsystem: subsystem, category: "Queue")
    static let catalog = Logger(subsystem: subsystem, category: "Catalog")
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let commands = Logger(subsystem: subsystem, category: "Commands")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let authentication = Logger(subsystem: subsystem, category: "Authentication")

    static let accountSignposter = OSSignposter(logger: account)
    static let queueSignposter = OSSignposter(logger: queue)
    static let catalogSignposter = OSSignposter(logger: catalog)
    static let audioSignposter = OSSignposter(logger: audio)

    static func logger(for module: String) -> Logger {
        switch module {
        case "KeymasterAuth", "ClientToken": authentication
        case "AudioRenderer": audio
        case "QueueService": queue
        case "CatalogMetadataRepository", "PartnerAPI", "TrackAttributesAPI": catalog
        default: playback
        }
    }
}

#if DEBUG
    private nonisolated let iso8601FormatStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
#endif

/// High-signal production diagnostics. Callers must pass a privacy-safe summary: never a token,
/// OAuth redirect, response body, or raw user payload. Dynamic fields are intentionally public so
/// the local `--telemetry` workflow is useful; the call sites constrain what those fields contain.
nonisolated func debugLog(_ module: String, _ message: String) {
    SpottyLog.logger(for: module).info("\(message, privacy: .public)")

    #if DEBUG
        let timestamp = iso8601FormatStyle.format(Date())
        fputs("[\(timestamp) DEBUG \(module)] \(message)\n", stderr)
    #endif
}
