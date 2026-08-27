import AuralDomain
import Foundation

func runQueueMutationChecks(_ check: CheckRunner) {
    func entry(_ uri: String, provider: String = "queue", occurrence: Int, uid: String = "") -> QueueEntry {
        QueueEntry(uri: uri, provider: provider, occurrence: occurrence, uid: uid)
    }

    func protocolTrack(_ uri: String, provider: String = "queue", uid: String = "") -> QueueProtocolTrack {
        QueueProtocolTrack(uri: uri, uid: uid, provider: provider)
    }

    func snapshot(
        next: [QueueProtocolTrack],
        prev: [QueueProtocolTrack] = [protocolTrack("spotify:track:prev", provider: "context")],
        provisional: Bool = false,
        source: PlaybackQueueSource = .connect,
        completeness: PlaybackQueueCompleteness = .complete,
        accountEpoch: UInt64 = 1,
        engineEpoch: UInt64 = 2,
        disallowSetQueue: Bool = false,
        disallowRemoving: Bool = false
    ) -> QueueMutationSnapshot {
        QueueMutationSnapshot(
            accountEpoch: accountEpoch,
            engineEpoch: engineEpoch,
            sourceRevision: 4,
            source: source,
            completeness: completeness,
            provisional: provisional,
            next: next,
            prev: prev,
            queueRevision: "rev-4",
            disallowSetQueue: disallowSetQueue,
            disallowRemovingFromNextTracks: disallowRemoving
        )
    }

    let duplicate = "spotify:track:dup"
    let other = "spotify:track:other"
    let visible = [
        entry(duplicate, occurrence: 0, uid: "q0"),
        entry(duplicate, occurrence: 1, uid: "q1"),
        entry(other, occurrence: 2, uid: "q2"),
    ]
    let protocolNext = [
        protocolTrack(duplicate, uid: "q0"),
        protocolTrack(duplicate, uid: "q1"),
        protocolTrack(other, uid: "q2"),
        protocolTrack("spotify:delimiter", provider: "delimiter"),
        protocolTrack("spotify:track:autoplay", provider: "autoplay"),
    ]
    let remote = ConnectCommandRoute.remote(from: "mac", to: "speaker")

    check.suite("Queue protocol projection and occurrence removal") {
        check.equal(
            "upcoming projection stops at the delimiter",
            QueueProtocolProjection.upcoming(from: protocolNext).map(\.uid),
            ["q0", "q1", "q2"]
        )
        check.check(
            "visible Connect URIs match the upcoming projection",
            QueueProtocolProjection.matchesVisibleUpcoming(
                protocolNext: protocolNext,
                visible: visible
            )
        )
        let removedSecondDuplicate = QueueProtocolProjection.removingUpcomingOccurrences(
            selectedIDs: [visible[1].id],
            visibleUpcoming: visible,
            protocolNext: protocolNext
        )
        check.equal(
            "duplicate URI removal keeps the first occurrence and autoplay",
            removedSecondDuplicate?.map(\.uid),
            ["q0", "q2", "", ""]
        )
        check.equal(
            "duplicate URI removal keeps protocol URIs in order",
            removedSecondDuplicate?.map(\.uri),
            [duplicate, other, "spotify:delimiter", "spotify:track:autoplay"]
        )
        let removedBothDuplicates = QueueProtocolProjection.removingUpcomingOccurrences(
            selectedIDs: [visible[0].id, visible[1].id],
            visibleUpcoming: visible,
            protocolNext: protocolNext
        )
        check.equal(
            "multi-occurrence removal is ordered and keeps delimiter metadata",
            removedBothDuplicates?.map(\.uri),
            [other, "spotify:delimiter", "spotify:track:autoplay"]
        )
        check.nil_(
            "URI-set selection cannot be used when visible identities drifted",
            QueueProtocolProjection.removingUpcomingOccurrences(
                selectedIDs: [visible[0].id],
                visibleUpcoming: [entry(other, occurrence: 0)],
                protocolNext: protocolNext
            )
        )
    }

    check.suite("Queue add selection preserves visible order and duplicates") {
        let tracks = [
            CatalogTrack(
                id: "a", uri: duplicate, title: "A", artist: "", album: "",
                duration: 1, artworkURL: nil, addedAt: nil
            ),
            CatalogTrack(
                id: "b", uri: duplicate, title: "B", artist: "", album: "",
                duration: 1, artworkURL: nil, addedAt: nil
            ),
            CatalogTrack(
                id: "c", uri: other, title: "C", artist: "", album: "",
                duration: 1, artworkURL: nil, addedAt: nil
            ),
        ]
        let ordered = QueueMutationSelection.orderedUpcoming(
            selectedIDs: [visible[2].id, visible[0].id],
            in: visible
        )
        check.equal(
            "selection follows visible upcoming order",
            ordered.map(\.id),
            [visible[0].id, visible[2].id]
        )
        check.equal(
            "batch add keeps duplicate URIs from distinct rows",
            QueueMutationSelection.addURIs(from: Array(tracks.prefix(2))),
            [duplicate, duplicate]
        )
    }

    check.suite("Queue keyboard command routing") {
        check.equal(
            "Delete on an allowed upcoming selection removes occurrences",
            QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                selectedUpcomingCount: 2,
                isRemovalAllowed: true
            ),
            .removeUpcomingOccurrences
        )
        check.equal(
            "Backspace uses the same native delete command",
            QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                selectedUpcomingCount: 1,
                isRemovalAllowed: true
            ),
            .removeUpcomingOccurrences
        )
        check.nil_(
            "Delete is not enabled without a selection",
            QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                selectedUpcomingCount: 0,
                isRemovalAllowed: true
            )
        )
        check.nil_(
            "Delete is not enabled when replacement is refused",
            QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                selectedUpcomingCount: 2,
                isRemovalAllowed: false
            )
        )
        check.nil_(
            "unrelated keys are not queue removal",
            QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: false,
                selectedUpcomingCount: 2,
                isRemovalAllowed: true
            )
        )
    }

    check.suite("Queue replacement capability gates") {
        let allowed = QueueMutationPolicy.evaluateRemoval(
            selectedIDs: [visible[1].id],
            visibleUpcoming: visible,
            nowPlayingID: "now",
            historyIDs: ["hist"],
            mutation: snapshot(next: protocolNext),
            route: remote,
            isConnected: true,
            accountEpoch: 1,
            engineEpoch: 2
        )
        switch allowed {
        case let .success(replacement):
            check.equal("allowed replacement keeps prev_tracks", replacement.prev.map(\.uri), ["spotify:track:prev"])
            check.equal("allowed replacement reports one removal", replacement.removedCount, 1)
            check.equal("allowed replacement preserves queue revision", replacement.queueRevision, "rev-4")
        case let .failure(reason):
            check.check("complete remote snapshot should be allowed: \(reason)", false)
        }

        check.equal(
            "disconnected removal is refused",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext),
                route: remote,
                isConnected: false,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.notConnected)
        )
        check.equal(
            "joining Connect is refused",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext),
                route: .waitingForLocalIdentity,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.joiningConnect)
        )
        check.equal(
            "local owner is unsupported without a Spirc replacement export",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext),
                route: .local,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.localOwnerUnsupported)
        )
        check.check(
            "local replacement is documented as unsupported",
            !LocalQueueReplacementCapability.isSupported
                && LocalQueueReplacementCapability.evidence.contains("add_to_queue")
                && LocalQueueReplacementCapability.evidence.contains("SetQueueCommand")
        )
        check.equal(
            "provisional snapshots cannot be replaced",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext, provisional: true),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.provisional)
        )
        check.equal(
            "partial provenance cannot be replaced",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext, completeness: .partial),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.incompleteProvenance)
        )
        check.equal(
            "web-api presentation provenance cannot replace Connect protocol tracks",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext, source: .webAPI),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.incompleteProvenance)
        )
        check.equal(
            "Spotify set_queue restrictions refuse replacement",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext, disallowSetQueue: true),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.restricted)
        )
        check.equal(
            "Spotify next-track removal restrictions refuse replacement",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext, disallowRemoving: true),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.restricted)
        )
        check.equal(
            "now-playing identity is not removable",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: ["now"],
                visibleUpcoming: visible,
                nowPlayingID: "now",
                historyIDs: [],
                mutation: snapshot(next: protocolNext),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.nowPlayingOrHistory)
        )
        check.equal(
            "history identity is not removable",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: ["hist"],
                visibleUpcoming: visible,
                nowPlayingID: "now",
                historyIDs: ["hist"],
                mutation: snapshot(next: protocolNext),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.nowPlayingOrHistory)
        )
        check.equal(
            "stale account epoch refuses replacement",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext, accountEpoch: 1),
                route: remote,
                isConnected: true,
                accountEpoch: 9,
                engineEpoch: 2
            ),
            .failure(.staleIdentities)
        )
        check.equal(
            "stale engine epoch refuses replacement",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: protocolNext),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 99
            ),
            .failure(.staleIdentities)
        )
        check.equal(
            "missing mutation snapshot is incomplete",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: nil,
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.incompleteProvenance)
        )

        let driftedUIDs = [
            protocolTrack(duplicate, uid: "q9"),
            protocolTrack(duplicate, uid: "q8"),
            protocolTrack(other, uid: "q7"),
            protocolTrack("spotify:delimiter", provider: "delimiter"),
            protocolTrack("spotify:track:autoplay", provider: "autoplay"),
        ]
        check.equal(
            "same URIs at the same indices with different Connect UIDs refuse the old selection",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [visible[0].id],
                visibleUpcoming: visible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: driftedUIDs),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.staleIdentities)
        )
        check.check(
            "old UID-bearing identities do not survive a UID-only snapshot rotation",
            visible[0].id != QueueEntry(
                uri: duplicate, provider: "queue", occurrence: 0, uid: "q9"
            ).id
        )

        let duplicateUIDNext = [
            protocolTrack(duplicate, uid: "shared"),
            protocolTrack(other, uid: "shared"),
            protocolTrack("spotify:delimiter", provider: "delimiter"),
        ]
        let duplicateUIDVisible = [
            entry(duplicate, occurrence: 0, uid: "shared"),
            entry(other, occurrence: 1, uid: "shared"),
        ]
        check.equal(
            "duplicate Connect UIDs fail closed even when URIs and indices match",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [duplicateUIDVisible[0].id],
                visibleUpcoming: duplicateUIDVisible,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: duplicateUIDNext),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.staleIdentities)
        )

        let webUnique = [entry("spotify:track:only", provider: "web-api", occurrence: 0)]
        let webUniqueProtocol = [
            protocolTrack("spotify:track:only", provider: "context", uid: "c1"),
            protocolTrack("spotify:delimiter", provider: "delimiter"),
        ]
        switch QueueMutationPolicy.evaluateRemoval(
            selectedIDs: [webUnique[0].id],
            visibleUpcoming: webUnique,
            nowPlayingID: nil,
            historyIDs: [],
            mutation: snapshot(next: webUniqueProtocol),
            route: remote,
            isConnected: true,
            accountEpoch: 1,
            engineEpoch: 2
        ) {
        case let .success(replacement):
            check.equal(
                "unique-URI Web presentation can bind a unique Connect uid",
                replacement.next.map(\.uri),
                ["spotify:delimiter"]
            )
        case let .failure(reason):
            check.check("unique-URI Web fallback should be allowed: \(reason)", false)
        }

        let webDuplicates = [
            entry(duplicate, provider: "web-api", occurrence: 0),
            entry(duplicate, provider: "web-api", occurrence: 1),
        ]
        let webDuplicateProtocol = [
            protocolTrack(duplicate, uid: "q0"),
            protocolTrack(duplicate, uid: "q1"),
            protocolTrack("spotify:delimiter", provider: "delimiter"),
        ]
        check.equal(
            "Web presentation without UIDs cannot remove duplicate URI occurrences",
            QueueMutationPolicy.evaluateRemoval(
                selectedIDs: [webDuplicates[0].id],
                visibleUpcoming: webDuplicates,
                nowPlayingID: nil,
                historyIDs: [],
                mutation: snapshot(next: webDuplicateProtocol),
                route: remote,
                isConnected: true,
                accountEpoch: 1,
                engineEpoch: 2
            ),
            .failure(.staleIdentities)
        )
    }

    check.suite("Queue add feedback reports completed command counts") {
        func expectAddFeedback(
            requested: Int,
            completed: Int,
            kind: QueueAddFeedbackKind,
            message: String,
            label: String
        ) {
            guard let actual = QueueAddFeedbackPolicy.evaluate(requested: requested, completed: completed) else {
                check.check("\(label) produced feedback", false)
                return
            }
            check.equal("\(label) kind", actual.kind, kind)
            check.equal("\(label) message", actual.message, message)
        }

        expectAddFeedback(
            requested: 1,
            completed: 1,
            kind: .success,
            message: "Added to Queue",
            label: "single add success"
        )
        expectAddFeedback(
            requested: 3,
            completed: 3,
            kind: .success,
            message: "Added 3 songs to Queue",
            label: "batch add success"
        )
        expectAddFeedback(
            requested: 3,
            completed: 0,
            kind: .failure,
            message: "Could not add those tracks to the queue.",
            label: "zero completed commands"
        )
        expectAddFeedback(
            requested: 5,
            completed: 2,
            kind: .informational,
            message: "Added 2 of 5 songs to Queue",
            label: "partial sequential add"
        )
        check.nil_("invalid counts produce no message", QueueAddFeedbackPolicy.evaluate(requested: 2, completed: 3))
    }
}
