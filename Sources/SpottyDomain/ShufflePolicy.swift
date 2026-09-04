//
//  ShufflePolicy.swift
//  Spotty
//

import Foundation

/// The "fewer repeats" shuffle policy.
///
/// Spotify's published approach compares multiple candidate shuffles and keeps the one that
/// least repeats recent listening; Connect exposes no shuffle-style argument, so Spotty mirrors
/// it locally. The policy is pure — history, the clock, and randomness arrive as inputs — so
/// it is testable without UserDefaults or wall time.
public enum ShufflePolicy {
    /// How many random orderings compete for the lowest repeat score.
    public static let candidateCount = 24
    /// Play history older than this is treated as fully fresh again.
    public static let freshnessWindow: TimeInterval = 30 * 24 * 60 * 60
    /// History entries expire entirely after this long.
    public static let retention: TimeInterval = 180 * 24 * 60 * 60

    /// Indices of the track list in playback order.
    ///
    /// Every candidate shuffle is scored by summing freshness x earliness across its
    /// positions. Unplayed tracks are perfectly fresh (1.0), so recently played ones sink
    /// toward the end of the winning sequence.
    public static func order(
        count: Int,
        uri: (Int) -> String,
        history: [String: TimeInterval],
        now: TimeInterval,
        generator: inout some RandomNumberGenerator,
    ) -> [Int] {
        guard count > 1 else { return Array(0..<count) }

        var best = Array(0..<count)
        best.shuffle(using: &generator)
        var bestScore = score(best, uri: uri, history: history, now: now)

        for _ in 1..<candidateCount {
            var candidate = Array(0..<count)
            candidate.shuffle(using: &generator)
            let candidateScore = score(candidate, uri: uri, history: history, now: now)
            if candidateScore > bestScore {
                bestScore = candidateScore
                best = candidate
            }
        }

        return best
    }

    /// Sum of freshness x earliness for one candidate sequence of indices.
    public static func score(
        _ indices: [Int],
        uri: (Int) -> String,
        history: [String: TimeInterval],
        now: TimeInterval,
    ) -> Double {
        indices.enumerated().reduce(0) { result, entry in
            let freshness =
                history[uri(entry.element)].map { playedAt in
                    min(max((now - playedAt) / freshnessWindow, 0), 1)
                } ?? 1
            return result + freshness * Double(indices.count - entry.offset)
        }
    }

    /// Drops expired entries; the caller persists the result.
    public static func pruned(
        _ history: [String: TimeInterval],
        now: TimeInterval,
    ) -> [String: TimeInterval] {
        history.filter { now - $0.value <= retention }
    }
}
