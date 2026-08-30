import Foundation

func runPlaybackStoreClockStampingContractChecks(_ check: CheckRunner) {
    check.suite("PlaybackStore clock-stamping contract") {
        check.equal(
            "a Date() stamp is reported",
            PlaybackStoreClockStampingContract.dateCallLines(in: "receivedAt: Date = Date()"),
            ["receivedAt: Date = Date()"]
        )
        check.check(
            "Date type names without a call are ignored",
            PlaybackStoreClockStampingContract.dateCallLines(in: "receivedAt: Date? = nil").isEmpty
        )
        check.check(
            "commented Date() calls are ignored",
            PlaybackStoreClockStampingContract.dateCallLines(in: "// receivedAt: Date = Date()").isEmpty
        )

        check.noThrow("production playback timestamp sources are readable") {
            let sourcesDirectory = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Aural/Spotify")
            let storeSources = try PlaybackStoreClockStampingContract.storeFiles.map { file in
                try String(contentsOf: sourcesDirectory.appending(path: file), encoding: .utf8)
            }
            let storeDateCalls = storeSources.flatMap(PlaybackStoreClockStampingContract.dateCallLines(in:))
            check.equal(
                "production PlaybackStore cannot call Date() for stamping",
                storeDateCalls,
                []
            )

            let fanout = try String(
                contentsOf: sourcesDirectory.appending(path: "EngineEventFanout.swift"),
                encoding: .utf8
            )
            check.equal(
                "engine fan-out cannot call Date() for receipt stamps",
                PlaybackStoreClockStampingContract.dateCallLines(in: fanout),
                []
            )
            check.check(
                "engine fan-out stores an injected PlaybackClock",
                fanout.contains("private let clock: any PlaybackClock")
                    && fanout.contains("init(clock: any PlaybackClock)")
                    && fanout.contains("receivedAt: clock.now()")
            )

            let engine = try String(
                contentsOf: sourcesDirectory.appending(path: "RustPlaybackEngine.swift"),
                encoding: .utf8
            )
            check.check(
                "production engine fan-out uses the live SystemPlaybackClock",
                engine.contains("EngineEventFanout(clock: SystemPlaybackClock())")
            )

            let history = try String(
                contentsOf: sourcesDirectory.appending(path: "PlaybackPanelModels.swift"),
                encoding: .utf8
            )
            check.equal(
                "played-history orchestration cannot call Date() for stamps",
                PlaybackStoreClockStampingContract.dateCallLines(in: history),
                []
            )
            check.check(
                "played-history notes require an explicit playedAt",
                history.contains("playedAt: Date")
                    && history.contains("playedAt: playedAt")
            )
        }
    }
}
