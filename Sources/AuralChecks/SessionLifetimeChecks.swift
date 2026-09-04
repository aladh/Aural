import AuralDomain
import Foundation

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

    check.suite("Catalog request cancellation classification") {
        check.check("CancellationError is cancellation", isCancellation(CancellationError()))
        check.check("URLError.cancelled is cancellation", isCancellation(URLError(.cancelled)))
        check.check(
            "a failed catalog transport is not cancellation",
            !isCancellation(URLError(.badServerResponse))
        )
        enum CatalogCheckFailure: Error { case unavailable }
        check.check("an ordinary error is not cancellation", !isCancellation(CatalogCheckFailure.unavailable))
    }

    check.suite("Connect queue callback watermark") {
        var watermark = ConnectQueueCallbackWatermark()
        check.check(
            "the first callback is accepted before the engine epoch catches up",
            watermark.accept(generation: 2, revision: 4, engineEpoch: 1)
        )
        check.equal("the callback generation is stored independently", watermark.generation, 2)
        check.equal("the callback revision is stored", watermark.revision, 4)

        let afterFirst = watermark
        check.check(
            "a duplicate revision in the same generation is rejected",
            !watermark.accept(generation: 2, revision: 4, engineEpoch: 1)
        )
        check.equal("a rejected duplicate does not clear the watermark", watermark, afterFirst)
        check.check(
            "an older revision in the same generation is rejected",
            !watermark.accept(generation: 2, revision: 3, engineEpoch: 1)
        )
        check.equal("an older revision does not reopen the generation", watermark, afterFirst)

        check.check(
            "adopting the same engine epoch later does not reset the watermark",
            !watermark.accept(generation: 2, revision: 1, engineEpoch: 2)
        )
        check.equal("the watermark survives the engine epoch catching up", watermark, afterFirst)
        check.check(
            "a newer revision in the stored generation is still accepted",
            watermark.accept(generation: 2, revision: 5, engineEpoch: 2)
        )

        check.check(
            "a previous engine generation is rejected after a newer callback generation",
            !watermark.accept(generation: 1, revision: 9, engineEpoch: 2)
        )
        check.check(
            "a newer callback generation starts a fresh revision namespace",
            watermark.accept(generation: 3, revision: 1, engineEpoch: 2)
        )
        check.equal("the new callback generation is recorded", watermark.generation, 3)
        check.equal("the new generation accepts a restarted revision", watermark.revision, 1)

        watermark.reset()
        check.check(
            "a missing generation still records revision against a later engine epoch",
            watermark.accept(generation: nil, revision: 9, engineEpoch: 4)
        )
        check.equal("the unstamped generation leaves the previous generation at zero", watermark.generation, 0)
        check.equal("the recorded revision would block a later restarted callback", watermark.revision, 9)
        watermark.reset()
        check.equal("reset clears the callback generation", watermark.generation, 0)
        check.equal("reset clears the callback revision", watermark.revision, 0)
        check.check(
            "a later engine epoch rejects a stale callback generation",
            !watermark.accept(generation: 2, revision: 1, engineEpoch: 3)
        )
        check.check(
            "a callback matching the later engine epoch is accepted",
            watermark.accept(generation: 3, revision: 1, engineEpoch: 3)
        )
    }

    check.suite("Playback command admission") {
        check.check(
            "an idle live session admits a command",
            playbackCommandShouldAdmit(
                isTearingDown: false,
                allowsCommands: true,
                hasPendingCommandForKind: false
            )
        )
        check.check(
            "teardown refuses admission",
            !playbackCommandShouldAdmit(
                isTearingDown: true,
                allowsCommands: true,
                hasPendingCommandForKind: false
            )
        )
        check.check(
            "a started termination gate refuses admission",
            !playbackCommandShouldAdmit(
                isTearingDown: false,
                allowsCommands: false,
                hasPendingCommandForKind: false
            )
        )
        check.check(
            "a pending command of the same kind refuses admission",
            !playbackCommandShouldAdmit(
                isTearingDown: false,
                allowsCommands: true,
                hasPendingCommandForKind: true
            )
        )
    }

    check.suite("Playback command finish follow-up") {
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        func followUp(
            finishAccepted: Bool,
            succeeded: Bool,
            reconnect: Bool = false,
            kind: PlaybackCommandKind = .transport,
            pending: UUID? = nil,
            resolution: PlaybackTransportCommandResolution? = nil,
            account: UInt64 = 1,
            engine: UInt64 = 1,
            currentAccount: UInt64 = 1,
            currentEngine: UInt64 = 1,
            tearingDown: Bool = false
        ) -> PlaybackCommandFollowUp {
            playbackCommandFollowUp(
                finishAccepted: finishAccepted,
                operationSucceeded: succeeded,
                requiresReconnect: reconnect,
                commandKind: kind,
                pendingCommandID: pending,
                finishedCommandResolution: resolution,
                capturedLifetime: PlaybackLifetime(
                    accountEpoch: account,
                    engineGeneration: engine
                ),
                currentLifetime: PlaybackLifetime(
                    accountEpoch: currentAccount,
                    engineGeneration: currentEngine
                ),
                isTearingDown: tearingDown
            )
        }

        check.equal(
            "an accepted success reports success", followUp(finishAccepted: true, succeeded: true), .reportSuccess)
        check.equal(
            "an accepted reconnect-required failure reports reconnect",
            followUp(finishAccepted: true, succeeded: false, reconnect: true),
            .reportFailure(reconnect: true)
        )
        check.equal(
            "a matching snapshot then successful finish still reports success",
            followUp(finishAccepted: false, succeeded: true, reconnect: true),
            .reportSuccess
        )
        check.equal(
            "already-reconciled transport success with an ordinary failure reports success",
            followUp(finishAccepted: false, succeeded: false, reconnect: false),
            .reportSuccess
        )
        check.equal(
            "already-reconciled transport success with a reconnect-required failure keeps presentation and reconnects",
            followUp(finishAccepted: false, succeeded: false, reconnect: true),
            .reconnectAfterReconciledSuccess
        )
        check.equal(
            "a non-transport kind with no pending command stays inert",
            followUp(finishAccepted: false, succeeded: false, reconnect: true, kind: .options),
            .inert
        )
        check.equal(
            "a late seek finish after pending was cleared stays inert",
            followUp(finishAccepted: false, succeeded: false, reconnect: true, kind: .seek),
            .inert
        )
        check.equal(
            "engine-epoch invalidation stays inert",
            followUp(finishAccepted: false, succeeded: true, reconnect: true, currentEngine: 2),
            .inert
        )
        check.equal(
            "account-epoch invalidation stays inert",
            followUp(finishAccepted: false, succeeded: true, reconnect: true, currentAccount: 2),
            .inert
        )
        check.equal(
            "a superseded id stays inert",
            followUp(finishAccepted: false, succeeded: true, pending: other),
            .inert
        )
        check.equal(
            "teardown stays inert",
            followUp(finishAccepted: false, succeeded: true, tearingDown: true),
            .inert
        )
        check.equal(
            "a confirmed play target still reports success after an ordinary late failure",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                resolution: .confirmed
            ),
            .reportSuccess
        )
        check.equal(
            "a confirmed play target keeps presentation but reconnects after a reconnect-required failure",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                resolution: .confirmed
            ),
            .reconnectAfterReconciledSuccess
        )
        check.equal(
            "a confirmed command that succeeded never reconnects",
            followUp(finishAccepted: false, succeeded: true, reconnect: true, resolution: .confirmed),
            .reportSuccess
        )
        check.equal(
            "a superseded play target stays inert after a late failure",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                resolution: .superseded
            ),
            .inert
        )
        check.equal(
            "a superseded play stays inert after a later pause is pending",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                pending: other,
                resolution: .superseded
            ),
            .inert
        )
        check.equal(
            "a superseded play stays inert after a later pause cleared pending",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                resolution: .superseded
            ),
            .inert
        )
        check.equal(
            "a confirmed transfer still reports success after an ordinary late failure",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                kind: .transfer,
                resolution: .confirmed
            ),
            .reportSuccess
        )
        check.equal(
            "a superseded transfer stays inert after an accepted coordinator result",
            followUp(
                finishAccepted: true,
                succeeded: true,
                reconnect: true,
                kind: .transfer,
                resolution: .superseded
            ),
            .inert
        )
        check.equal(
            "a confirmed play still reports success (ordinary failure) while a later pause is pending",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                pending: other,
                resolution: .confirmed
            ),
            .reportSuccess
        )
        check.equal(
            "consume-only acceptance without a captured resolution still reports failure",
            followUp(finishAccepted: true, succeeded: false, reconnect: true),
            .reportFailure(reconnect: true)
        )
        check.equal(
            "a confirmed play is inert after an engine-epoch invalidation",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                resolution: .confirmed,
                currentEngine: 2
            ),
            .inert
        )
        check.equal(
            "a confirmed play is inert during teardown",
            followUp(
                finishAccepted: true,
                succeeded: false,
                resolution: .confirmed,
                tearingDown: true
            ),
            .inert
        )
        check.equal(
            "options reconnect-required after an accepted finish reports reconnect",
            followUp(finishAccepted: true, succeeded: false, reconnect: true, kind: .options),
            .reportFailure(reconnect: true)
        )
        check.equal(
            "transfer reconnect-required after an accepted finish reports reconnect",
            followUp(finishAccepted: true, succeeded: false, reconnect: true, kind: .transfer),
            .reportFailure(reconnect: true)
        )
        check.equal(
            "a confirmed shuffle still reports success after an ordinary late failure",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                kind: .options,
                resolution: .confirmed
            ),
            .reportSuccess
        )
        check.equal(
            "a confirmed shuffle still reports success (ordinary failure) while a later options command is pending",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: false,
                kind: .options,
                pending: other,
                resolution: .confirmed
            ),
            .reportSuccess
        )
        check.equal(
            "a confirmed shuffle is inert after an engine-epoch invalidation",
            followUp(
                finishAccepted: true,
                succeeded: false,
                reconnect: true,
                kind: .options,
                resolution: .confirmed,
                currentEngine: 2
            ),
            .inert
        )
        check.equal(
            "an options finish without a captured resolution stays inert when pending is gone",
            followUp(finishAccepted: false, succeeded: false, reconnect: true, kind: .options),
            .inert
        )
    }

    check.suite("Playback command ordinary cancellation") {
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-00000000009A")!
        func shouldSettle(
            pending: UUID? = commandID,
            cancelled: UUID = commandID,
            account: UInt64 = 1,
            engine: UInt64 = 1,
            currentAccount: UInt64 = 1,
            currentEngine: UInt64 = 1,
            tearingDown: Bool = false
        ) -> Bool {
            playbackCommandShouldSettleOrdinaryCancellation(
                pendingCommandID: pending,
                cancelledCommandID: cancelled,
                capturedLifetime: PlaybackLifetime(
                    accountEpoch: account,
                    engineGeneration: engine
                ),
                currentLifetime: PlaybackLifetime(
                    accountEpoch: currentAccount,
                    engineGeneration: currentEngine
                ),
                isTearingDown: tearingDown
            )
        }

        check.check("a matching same-lifetime cancel settles", shouldSettle())
        check.check("a missing pending command stays inert", !shouldSettle(pending: nil))
        check.check("a newer pending command stays inert", !shouldSettle(pending: other))
        check.check("a different cancelled id stays inert", !shouldSettle(cancelled: other))
        check.check("engine-epoch invalidation stays inert", !shouldSettle(currentEngine: 2))
        check.check("account-epoch invalidation stays inert", !shouldSettle(currentAccount: 2))
        check.check("teardown stays inert", !shouldSettle(tearingDown: true))
    }
}
