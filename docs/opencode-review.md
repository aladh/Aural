# OpenCode pull-request review

[OpenCode advisory review](../.github/workflows/opencode-review.yml) performs one full review when
a same-repository, non-draft PR opens or becomes ready. Later pushes do not trigger another review.
A verified successful review is terminal for that PR, including after draft toggles or Actions
reruns. Fork PRs receive normal CI but are not sent to the credentialed model reviewer.

The review is advisory and identifies its exact source SHA. It does not assess subsequent commits,
approve PRs, replace required checks, or change [PR acceptance](../CONTRIBUTING.md#pr-acceptance).
There is no incremental baseline, finding reconciliation, or automatic thread resolution.

## Review process

Pinned OpenCode 1.18.29 runs Muse contributor-free with `xhigh`. The parent launches two native
foreground tasks together, with the verbatim correctness/security and code-quality rubrics from
[Cursor Thermos at `93b00b8`](https://github.com/cursor/plugins/tree/93b00b89ef425a9c1bac0d0b317dfc49c930ac99/thermos).
The upstream MIT license and orchestration reference are retained beside the rubrics.

Each child receives the full PR diff and read/search access to the current source checkout.
Neither sees the other audit's answer or live discussion. Completed session exports verify the
model, reasoning effort, independent child identities, overlapping execution, and read-only tools.

The parent compares both reports and verifies candidates using source pinned to the reviewed SHA.
Only after correctness reports a P1/P2 may it consult bounded discussion, at most three requests
of 20 records per method. It must disclose limits and attribute borrowed claims. It publishes one
overview and genuine LINE/RIGHT inline findings through the official GitHub MCP server. Runtime
traces, completed sessions and actual GitHub comments must agree before the run passes.

## Trust and permissions

The `pull_request_target` workflow loads its scripts, prompts, model catalog and policy from the
trusted default-branch SHA. It checks out candidate source separately as review data. No candidate code,
tests, build scripts or project configuration run in the credentialed review job. Ordinary CI runs
candidate tests separately with read-only repository permissions.

OpenCode receives no GitHub credential in its environment. A private MCP guard supplies the
short-lived token only to the official server. Before forwarding calls, the guard restricts the
repository, PR, immutable source SHA, review write sequence, COMMENT event, inline count and valid
diff anchors. APPROVE, REQUEST_CHANGES, deletion, other-PR writes and unlisted tools are refused.
Child tool ordering, investigation quality and discussion eligibility are additionally checked as
postconditions; these cannot establish semantic correctness.

The job has contents-read, PR-write and actions-read, with no contents-write or OIDC permission.
Checkout credentials are not persisted. There is no OpenCode GitHub App, provider key, or paid-model
fallback. OpenCode shell, file edits, external directories, nested tasks, project configuration,
LSP, formatting and session sharing are disabled. Untrusted config text is escaped against
`{env:...}` and `{file:...}` expansion.

The free contributor offering permits prompts/completions to train future Meta models. Use this
workflow only for public source; do not supply account data, confidential code or diagnostic
exports. Runner usage is separate from model pricing. See [OpenCode Zen](https://opencode.ai/docs/zen/).

## Operation and evidence

The full diff is limited to 300 KB and attached once to each child. Parent execution has an
11-minute timeout and 40 steps; children have 30 steps. Oversized input/output, malformed reports,
provider errors, incomplete sessions, invalid locations or publication mismatches fail visibly.

`opencode-mcp-evidence-<run>-<attempt>` retains redacted traces and session exports for seven days.
GitHub Actions can retry failed runs. A changed/closed PR can invalidate an in-flight review;
a fresh ready event is needed when a retry's recorded head is stale. A partial published review
may remain after failure. Revision checks and the guard reduce mistakes but do not make GitHub
comment writes atomic with concurrent pushes. A green run proves validated publication, not a
clean PR or review-quality parity with Cursor.

The [closed spike PR](https://github.com/aladh/Spotty/pull/268) established native delegation and
real MCP review publication in Actions. A [labeled local inline probe](https://github.com/aladh/Spotty/pull/268#discussion_r3941421046)
created a pending review, added a RIGHT-side inline comment, and submitted COMMENT. Its body, path,
line and SHA were independently verified. This caught the legacy coordinates returned by GitHub's
per-review list; the validator now retrieves each individual comment for modern line/side fields.
The synthetic probe used the existing local identity, not an Actions token, and is plumbing
evidence rather than independent bug discovery.

OpenCode 2 beta completed native audits but did not preserve MCP access under the tested restrictive
permission policy, so V1 is retained. Broader adoption or an authoritative gate should evaluate
known bugs and clean changes without revealing other reviewers' answers, and measure false positives.

The implementation guard also passed a real-server read probe and refused an APPROVE request
locally. Standard-library tests cover denied calls before forwarding, token isolation, pending
review transitions, and inline bounds; ordinary CI runs these tests on every push.
