//
//  ShufflePolicyChecks.swift
//  Aural
//

import Foundation
import AuralDomain

func runShufflePolicyChecks(_ check: CheckRunner) {
    /// Tiny deterministic generator so shuffle outcomes are reproducible.
    struct StepRng: RandomNumberGenerator {
        var state: UInt64 = 0

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    check.suite("Fewer-repeats shuffle") {
        var rng = StepRng()
        check.equal(
            "empty list passes through",
            ShufflePolicy.order(count: 0, uri: { _ in "" }, history: [:], now: 0, generator: &rng),
            []
        )
        check.equal(
            "single track passes through",
            ShufflePolicy.order(count: 1, uri: { _ in "a" }, history: [:], now: 0, generator: &rng),
            [0]
        )

        // "fresh" (index 0) was played moments ago; "stale" has never been played.
        let uris = ["fresh", "stale"]
        let history = ["fresh": 9_000.0]
        let now: TimeInterval = 10_000
        for seed in [UInt64(1), 7, 123] {
            var seeded = StepRng(state: seed)
            let order = ShufflePolicy.order(
                count: 2,
                uri: { uris[$0] },
                history: history,
                now: now,
                generator: &seeded
            )
            check.equal(
                "just-played track sinks deepest into the sequence (seed \(seed))",
                order.last,
                0
            )
        }

        let scoringNow: TimeInterval = ShufflePolicy.freshnessWindow
        let scoringURIs = ["a", "b"]
        var scoringHistory = ["a": scoringNow]  // played this instant → freshness 0
        let staleFirst = ShufflePolicy.score(
            [0, 1], uri: { scoringURIs[$0] }, history: scoringHistory, now: scoringNow)
        scoringHistory["a"] = scoringNow - scoringNow / 2  // half a window old → freshness 0.5
        let halfFreshFirst = ShufflePolicy.score(
            [0, 1], uri: { scoringURIs[$0] }, history: scoringHistory, now: scoringNow
        )
        let unplayedFirst = ShufflePolicy.score([0, 1], uri: { scoringURIs[$0] }, history: [:], now: scoringNow)
        check.check("freshness raises the score of an early position", staleFirst < halfFreshFirst)
        check.check("unplayed beats half-fresh in the same slot", halfFreshFirst < unplayedFirst)

        let retentionNow: TimeInterval = 200 * 24 * 60 * 60
        let pruned = ShufflePolicy.pruned(
            [
                "expired": 0,
                "current": retentionNow - 60,
            ], now: retentionNow)
        check.check("expired entries are dropped", !pruned.keys.contains("expired"))
        check.check("recent entries survive pruning", pruned.keys.contains("current"))

        // The cutoff itself is inclusive; one second past it is not.
        let atCutoff = ShufflePolicy.pruned(["edge": retentionNow - ShufflePolicy.retention], now: retentionNow)
        check.check("history exactly at retention survives pruning", atCutoff.keys.contains("edge"))
        let pastCutoff = ShufflePolicy.pruned(
            ["gone": retentionNow - ShufflePolicy.retention - 1],
            now: retentionNow
        )
        check.check("history one second past retention is dropped", !pastCutoff.keys.contains("gone"))
        check.check(
            "pruning an empty history stays empty",
            ShufflePolicy.pruned([:], now: retentionNow).isEmpty
        )

        // Clock skew must never make a track fresher than fresh.
        check.equal(
            "future play times contribute no freshness",
            ShufflePolicy.score([0], uri: { scoringURIs[$0] }, history: ["a": scoringNow + 60], now: scoringNow),
            0
        )
        check.equal(
            "an empty sequence scores nothing",
            ShufflePolicy.score([], uri: { scoringURIs[$0] }, history: scoringHistory, now: scoringNow),
            0
        )

        // Whatever ordering wins, every track must still play exactly once.
        var permutationRng = StepRng(state: 99)
        let permutationURIs = (0..<5).map { "u\($0)" }
        let permutationOrder = ShufflePolicy.order(
            count: permutationURIs.count,
            uri: { permutationURIs[$0] },
            history: ["u0": 5, "u3": 100],
            now: 200,
            generator: &permutationRng
        )
        check.equal(
            "shuffled output is a permutation of the list",
            permutationOrder.sorted(),
            Array(0..<permutationURIs.count)
        )
    }
}
