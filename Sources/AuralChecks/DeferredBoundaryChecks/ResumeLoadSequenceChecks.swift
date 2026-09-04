import AuralDomain
import Foundation
@testable import AuralCore

/// `ResumeLoadSequence` policy for both callers. Store-level capture and the reconnect
/// trigger live in the command-failure and workflow suites.
func runResumeLoadSequenceChecks(_ runner: CheckRunner) {
    let context = ResumeLoadPlan.Target.context(
        uri: "spotify:playlist:ctx",
        trackHint: "spotify:track:one",
        positionMS: 10
    )
    let track = ResumeLoadPlan.Target.track(uri: "spotify:track:one", positionMS: 10)
    let reconnect = PlaybackEngineResult(rawValue: -2)

    runner.suite("User resume load sequence") {
        runner.equal(
            "successful play does not load",
            ResumeLoadSequence.completing(play: .ok, targets: [context, track]) { _ in
                runner.check("successful play must not load", false)
                return .error
            },
            .ok
        )
        runner.equal(
            "reconnect-required play does not load",
            ResumeLoadSequence.completing(play: reconnect, targets: [context, track]) { _ in
                runner.check("reconnect-required play must not load", false)
                return .ok
            },
            reconnect
        )

        var loaded: [ResumeLoadPlan.Target] = []
        let recovered = ResumeLoadSequence.completing(play: .error, targets: [context, track]) {
            loaded.append($0)
            if case .track = $0 { return .ok }
            return .error
        }
        runner.equal("timeout tries context then track", loaded, [context, track])
        runner.equal("a later target can recover the timeout", recovered, .ok)

        var failedLoads = 0
        let exhausted = ResumeLoadSequence.completing(play: .error, targets: [context, track]) { _ in
            failedLoads += 1
            return .error
        }
        runner.equal("exhausted loads keep the play timeout", exhausted, .error)
        runner.equal("exhausted loads try every target", failedLoads, 2)
    }

    runner.suite("Reconnect rehydration load sequence") {
        var loaded: [ResumeLoadPlan.Target] = []
        let queued = ResumeLoadSequence.completing(play: nil, targets: [context, track]) {
            loaded.append($0)
            return .ok
        }
        runner.equal("rehydration issues no play and stops at the first queued load", loaded, [context])
        runner.equal("a queued load is the sequence result", queued, .ok)

        loaded = []
        let unqueued = ResumeLoadSequence.completing(play: nil, targets: [context, track]) {
            loaded.append($0)
            if case .track = $0 { return .ok }
            return .error
        }
        runner.equal("a context load the engine refused to queue falls through to the track", loaded, [context, track])
        runner.equal("the fallback result is reported", unqueued, .ok)

        loaded = []
        let dead = ResumeLoadSequence.completing(play: nil, targets: [context, track]) {
            loaded.append($0)
            return reconnect
        }
        runner.equal("a dead Spirc stops the sequence", loaded, [context])
        runner.equal("a dead Spirc is reported as reconnect-required", dead, reconnect)

        runner.equal(
            "no targets is an ordinary failure",
            ResumeLoadSequence.completing(play: nil, targets: []) { _ in .ok },
            .error
        )
    }
}
