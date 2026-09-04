import Testing
import SpottyDomain

@Test
func testResumeLoadPlan() {
    do {
        #expect(
            (ResumeLoadPlan.resumePosition(savedAtDeactivation: 93606, live: 0)) == (93606),
            "a deactivation position outranks the live playhead")
        #expect(
            (ResumeLoadPlan.resumePosition(savedAtDeactivation: 0, live: 12087)) == (12087),
            "a zero deactivation position uses the live playhead")

        let plan = ResumeLoadPlan.capture(
            savedAtDeactivation: 93606,
            live: 0,
            contextURI: "spotify:playlist:ctx",
            trackURI: "spotify:track:one"
        )
        #expect(
            (plan.targets())
                == ([
                    .context(
                        uri: "spotify:playlist:ctx",
                        trackHint: "spotify:track:one",
                        positionMS: 93606
                    ),
                    .track(uri: "spotify:track:one", positionMS: 93606),
                ]), "context then track at the resume position")

        let empty = ResumeLoadPlan.capture(
            savedAtDeactivation: 0,
            live: 12087,
            contextURI: "",
            trackURI: ""
        )
        #expect((empty.contextURI) == nil, "empty context is missing")
        #expect((empty.targets().isEmpty) == true, "empty strings produce no load targets")
        #expect((empty.positionMS) == (12087), "live position is kept when deactivation is zero")

        let initializedWithEmptyContext = ResumeLoadPlan(
            positionMS: 10,
            contextURI: "",
            trackURI: "spotify:track:hint"
        )
        #expect(
            (initializedWithEmptyContext.contextURI) == nil, "the public initializer treats an empty context as missing"
        )
        #expect(
            (initializedWithEmptyContext.targets()) == ([.track(uri: "spotify:track:hint", positionMS: 10)]),
            "an empty initialized context does not produce a context target")

        #expect(
            (ResumeLoadPlan.capture(
                savedAtDeactivation: 0,
                live: 0,
                contextURI: nil,
                trackURI: "spotify:track:solo"
            ).targets())
                == ([
                    .track(uri: "spotify:track:solo", positionMS: 0)
                ]), "only a track loads that track")

        #expect(
            (ResumeLoadPlan.capture(
                savedAtDeactivation: 10,
                live: 1,
                contextURI: "spotify:album:ctx",
                trackURI: ""
            ).targets())
                == ([
                    .context(uri: "spotify:album:ctx", trackHint: "", positionMS: 10)
                ]), "an empty track stays a context hint only")
    }
}
