import AuralDomain

func runResumeLoadPlanChecks(_ check: CheckRunner) {
    check.suite("Resume load plan") {
        check.equal(
            "a deactivation position outranks the live playhead",
            ResumeLoadPlan.resumePosition(savedAtDeactivation: 93606, live: 0),
            93606
        )
        check.equal(
            "a zero deactivation position uses the live playhead",
            ResumeLoadPlan.resumePosition(savedAtDeactivation: 0, live: 12087),
            12087
        )

        let plan = ResumeLoadPlan.capture(
            savedAtDeactivation: 93606,
            live: 0,
            contextURI: "spotify:playlist:ctx",
            trackURI: "spotify:track:one"
        )
        check.equal(
            "context then track at the resume position",
            plan.targets(),
            [
                .context(
                    uri: "spotify:playlist:ctx",
                    trackHint: "spotify:track:one",
                    positionMS: 93606
                ),
                .track(uri: "spotify:track:one", positionMS: 93606),
            ]
        )

        let empty = ResumeLoadPlan.capture(
            savedAtDeactivation: 0,
            live: 12087,
            contextURI: "",
            trackURI: ""
        )
        check.nil_("empty context is missing", empty.contextURI)
        check.check("empty strings produce no load targets", empty.targets().isEmpty)
        check.equal("live position is kept when deactivation is zero", empty.positionMS, 12087)

        check.equal(
            "only a track loads that track",
            ResumeLoadPlan.capture(
                savedAtDeactivation: 0,
                live: 0,
                contextURI: nil,
                trackURI: "spotify:track:solo"
            ).targets(),
            [
                .track(uri: "spotify:track:solo", positionMS: 0)
            ]
        )

        check.equal(
            "an empty track stays a context hint only",
            ResumeLoadPlan.capture(
                savedAtDeactivation: 10,
                live: 1,
                contextURI: "spotify:album:ctx",
                trackURI: ""
            ).targets(),
            [
                .context(uri: "spotify:album:ctx", trackHint: "", positionMS: 10)
            ]
        )
    }
}
