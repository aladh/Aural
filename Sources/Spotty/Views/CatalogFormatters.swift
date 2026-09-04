import Foundation

func formatDuration(_ interval: TimeInterval) -> String {
    let total = boundedDurationSeconds(interval, rounding: .down)
    return String(format: "%d:%02d", total / 60, total % 60)
}

func roundedCatalogDurationSeconds(_ interval: TimeInterval) -> Int {
    boundedDurationSeconds(interval, rounding: .toNearestOrAwayFromZero)
}

func formatCatalogDuration(_ interval: TimeInterval) -> String {
    let total = roundedCatalogDurationSeconds(interval)
    return String(format: "%d:%02d", total / 60, total % 60)
}

private func boundedDurationSeconds(
    _ interval: TimeInterval,
    rounding rule: FloatingPointRoundingRule
) -> Int {
    guard interval.isFinite, interval > 0 else { return 0 }
    let rounded = interval.rounded(rule)
    // `Double(Int.max)` rounds to the first unrepresentable positive Int value.
    guard rounded < TimeInterval(Int.max) else { return 0 }
    return Int(rounded)
}

func formatDateAdded(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .omitted) ?? "—"
}
