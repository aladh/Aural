//
//  LogicChecks.swift
//  Aural
//
//  Entry point for the pure-logic regression checks.
//

import Foundation

enum LogicChecks {
    /// Runs every suite and reports the verdict.
    ///
    /// The Command Line Tools toolchain this project builds with ships neither the XCTest
    /// framework nor the swift-testing runtime, so the checks live inside the app and run
    /// behind `--run-core-checks`: `Scripts/check.sh` executes that mode and asserts the
    /// exit status. Installing full Xcode would unlock XCTest; until then this keeps the
    /// pure logic under real regression coverage with zero dependencies.
    @discardableResult
    @MainActor
    static func runAll() -> Bool {
        let runner = CheckRunner()

        runProtobufChecks(runner)
        runTrackAttributeChecks(runner)
        runShufflePolicyChecks(runner)
        runAuthFlowChecks(runner)
        runPaginationChecks(runner)
        runPlaybackPanelChecks(runner)
        runLoopbackParsingChecks(runner)
        runURIChecks(runner)
        runFormattingChecks(runner)

        runner.report()
        return runner.succeeded
    }
}
