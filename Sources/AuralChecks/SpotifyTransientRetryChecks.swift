import AuralDomain
import Foundation

func runSpotifyTransientRetryChecks(_ check: CheckRunner) {
    check.suite("Transient retry classification and Retry-After") {
        check.check("429 is retryable", SpotifyTransientRetry.isRetryableStatus(429))
        check.check("500 is retryable", SpotifyTransientRetry.isRetryableStatus(500))
        check.check("502 is retryable", SpotifyTransientRetry.isRetryableStatus(502))
        check.check("503 is retryable", SpotifyTransientRetry.isRetryableStatus(503))
        check.check("504 is retryable", SpotifyTransientRetry.isRetryableStatus(504))
        check.check("501 is not a transient 5xx", !SpotifyTransientRetry.isRetryableStatus(501))
        check.check("400 is not retryable", !SpotifyTransientRetry.isRetryableStatus(400))
        check.check("401 is not a transient HTTP retry", !SpotifyTransientRetry.isRetryableStatus(401))
        check.check("403 is not retryable", !SpotifyTransientRetry.isRetryableStatus(403))

        check.check(
            "timedOut is retryable",
            SpotifyTransientRetry.isRetryableURLErrorCode(.timedOut)
        )
        check.check(
            "networkConnectionLost is retryable",
            SpotifyTransientRetry.isRetryableURLErrorCode(.networkConnectionLost)
        )
        check.check(
            "cannotConnectToHost is retryable",
            SpotifyTransientRetry.isRetryableURLErrorCode(.cannotConnectToHost)
        )
        check.check(
            "cancelled is not retryable",
            !SpotifyTransientRetry.isRetryableURLErrorCode(.cancelled)
        )
        check.check(
            "secureConnectionFailed is not retryable",
            !SpotifyTransientRetry.isRetryableURLErrorCode(.secureConnectionFailed)
        )
        check.check(
            "notConnectedToInternet is not an interruption retry",
            !SpotifyTransientRetry.isRetryableURLErrorCode(.notConnectedToInternet)
        )
        check.check(
            "cannotFindHost is not retryable",
            !SpotifyTransientRetry.isRetryableURLErrorCode(.cannotFindHost)
        )
        check.check(
            "userCancelledAuthentication is not retryable",
            !SpotifyTransientRetry.isRetryableURLErrorCode(.userCancelledAuthentication)
        )

        check.equal(
            "delta-seconds Retry-After is honored",
            SpotifyTransientRetry.parseRetryAfter("7", now: Date(timeIntervalSince1970: 0)),
            7
        )
        check.equal(
            "delta-seconds trims surrounding whitespace",
            SpotifyTransientRetry.parseRetryAfter("  12\n", now: Date(timeIntervalSince1970: 0)),
            12
        )
        check.nil_(
            "malformed Retry-After is ignored",
            SpotifyTransientRetry.parseRetryAfter("not-a-delay", now: Date(timeIntervalSince1970: 0))
        )
        check.nil_(
            "empty Retry-After is ignored",
            SpotifyTransientRetry.parseRetryAfter("  ", now: Date(timeIntervalSince1970: 0))
        )
        check.nil_(
            "signed delta-seconds are malformed",
            SpotifyTransientRetry.parseRetryAfter("+8", now: Date(timeIntervalSince1970: 0))
        )
        check.nil_(
            "overflowing delta-seconds are malformed",
            SpotifyTransientRetry.parseRetryAfter("99999999999999999999", now: Date(timeIntervalSince1970: 0))
        )

        let now = Date(timeIntervalSince1970: 1_000_000)
        let httpDate = "Mon, 12 Jan 1970 13:46:40 GMT"
        check.equal(
            "IMF-fixdate Retry-After is seconds until that instant",
            SpotifyTransientRetry.parseRetryAfter(httpDate, now: now),
            0
        )
        let later = "Mon, 12 Jan 1970 13:47:10 GMT"
        check.equal(
            "IMF-fixdate in the future is a positive delta",
            SpotifyTransientRetry.parseRetryAfter(later, now: now),
            30
        )
        let past = "Mon, 12 Jan 1970 13:46:10 GMT"
        check.equal(
            "IMF-fixdate in the past is a negative delta",
            SpotifyTransientRetry.parseRetryAfter(past, now: now),
            -30
        )

        check.equal(
            "malformed 429 uses jittered backoff",
            SpotifyTransientRetry.delay(
                status: 429,
                retryAfterHeader: "tomorrow",
                completedAttempts: 1,
                now: now,
                unitJitter: 1
            ),
            0.5
        )
        check.equal(
            "delta Retry-After replaces backoff",
            SpotifyTransientRetry.delay(
                status: 429,
                retryAfterHeader: "8",
                completedAttempts: 1,
                now: now,
                unitJitter: 1
            ),
            8
        )
        check.equal(
            "huge Retry-After is capped",
            SpotifyTransientRetry.delay(
                status: 429,
                retryAfterHeader: "3600",
                completedAttempts: 1,
                now: now,
                unitJitter: 1
            ),
            SpotifyTransientRetry.maximumDelaySeconds
        )
        check.equal(
            "past HTTP-date retries immediately",
            SpotifyTransientRetry.delay(
                status: 429,
                retryAfterHeader: past,
                completedAttempts: 1,
                now: now,
                unitJitter: 1
            ),
            0
        )
        check.equal(
            "HTTP-date Retry-After is honored",
            SpotifyTransientRetry.delay(
                status: 429,
                retryAfterHeader: later,
                completedAttempts: 1,
                now: now,
                unitJitter: 1
            ),
            30
        )
        check.equal(
            "second backoff doubles",
            SpotifyTransientRetry.backoffDelay(completedAttempts: 2, unitJitter: 1),
            1
        )
        check.nil_(
            "non-retryable status has no delay",
            SpotifyTransientRetry.delay(
                status: 404,
                retryAfterHeader: "5",
                completedAttempts: 1,
                now: now,
                unitJitter: 1
            )
        )
        check.equal("attempt budget is three", SpotifyTransientRetry.maximumAttempts, 3)
    }
}
