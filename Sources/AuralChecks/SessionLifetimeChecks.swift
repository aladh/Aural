import AuralDomain

func runSessionLifetimeChecks(_ check: CheckRunner) {
    check.suite("Session teardown coalescing") {
        let revoked = SessionTeardownIntent(
            clearGrant: false,
            finalPhase: .failed("expired")
        )
        let logout = SessionTeardownIntent(clearGrant: true, finalPhase: .signedOut)

        var revocationFirst = SessionTeardownCoalescer()
        check.check("first request owns the teardown", revocationFirst.request(revoked))
        check.check("overlapping logout joins the existing teardown", !revocationFirst.request(logout))
        check.equal("logout upgrades grant clearing", revocationFirst.intent?.clearGrant, true)
        check.equal("logout wins the final phase", revocationFirst.intent?.finalPhase, .signedOut)
        check.equal("completion returns the cumulative intent", revocationFirst.complete(), logout)
        check.check("completion releases the single-flight gate", !revocationFirst.isActive)
        check.check("a later boundary can start", revocationFirst.request(revoked))

        var logoutFirst = SessionTeardownCoalescer()
        check.check("logout can own the teardown", logoutFirst.request(logout))
        check.check("late revocation is coalesced", !logoutFirst.request(revoked))
        check.equal("revocation cannot downgrade grant clearing", logoutFirst.intent, logout)
    }

    check.suite("Catalog request lifetime") {
        let captured = AccountScopedRequestIdentity(
            requestID: 7,
            accountEpoch: 3,
            sessionRevision: 11
        )
        check.check(
            "current result is accepted",
            captured.isCurrent(
                requestID: 7,
                accountEpoch: 3,
                sessionRevision: 11,
                isAvailable: true,
                isCancelled: false
            )
        )
        check.check(
            "superseded request result is rejected",
            !captured.isCurrent(
                requestID: 8,
                accountEpoch: 3,
                sessionRevision: 11,
                isAvailable: true,
                isCancelled: false
            )
        )
        check.check(
            "previous account result is rejected",
            !captured.isCurrent(
                requestID: 7,
                accountEpoch: 4,
                sessionRevision: 11,
                isAvailable: true,
                isCancelled: false
            )
        )
        check.check(
            "result from before a disconnect-reconnect cycle is rejected",
            !captured.isCurrent(
                requestID: 7,
                accountEpoch: 3,
                sessionRevision: 13,
                isAvailable: true,
                isCancelled: false
            )
        )
        check.check(
            "unavailable session rejects results",
            !captured.isCurrent(
                requestID: 7,
                accountEpoch: 3,
                sessionRevision: 11,
                isAvailable: false,
                isCancelled: false
            )
        )
        check.check(
            "cancelled task rejects results",
            !captured.isCurrent(
                requestID: 7,
                accountEpoch: 3,
                sessionRevision: 11,
                isAvailable: true,
                isCancelled: true
            )
        )
    }
}
