# Thermos-style OpenCode advisory reviews (#233)

PR #268 evaluates a Cursor Thermos replacement alongside CodeRabbit. The selected implementation
uses pinned OpenCode 1.18.29, Muse contributor-free with `xhigh`, native foreground subagents, and
the official GitHub MCP server. It remains advisory and restricted to the same-repository
`codex/opencode-review-spike` branch. It changes neither repository protections nor the
[PR acceptance criteria](../CONTRIBUTING.md#automated-pr-acceptance). Issue #233 remains open.

## Run and inspect

[OpenCode advisory review](../.github/workflows/opencode-spike.yml) runs one full review when a
non-draft PR opens or becomes ready. Subsequent pushes do not start another review. A successful
owned review is terminal for that PR, including after toggling draft status. Failed runs can be
retried with GitHub Actions; the successful-run guard prevents repeated model reviews.

One job runs native correctness and quality audits, then lets the parent publish the overview
and genuine inline findings through MCP. The old scripted control, duplicate workflow, and
privileged thread publisher are retired. There is no baseline storage, incremental review,
automatic finding reconciliation, or automatic thread resolution. Findings are addressed through
the normal PR review process. The review identifies its exact SHA; it does not assess later pushes.

`opencode-mcp-evidence-<run>-<attempt>` retains `trial.json` and redacted session/trace evidence for
seven days. A green run proves validated advisory publication, not that the PR is correct.

## Review process

The exact correctness and quality rubrics are vendored from
[Cursor Thermos at `93b00b8`](https://github.com/cursor/plugins/tree/93b00b89ef425a9c1bac0d0b317dfc49c930ac99/thermos),
with Cursor's MIT license and orchestration reference. There is no runtime prompt download.

The parent launches exactly two native foreground tasks together. Both receive the full PR diff
and read/search access to the current checkout. Neither receives prior findings, PR
discussion, or the other audit's answer. Exported sessions verify independent identities, overlapping
execution, successful completion, the model and effort, and read-only child tool use.

After both finish, the parent compares their findings and checks source through immutable MCP
reads pinned to the head. Discussion reads are allowed only when correctness found a P1/P2,
with at most three calls of at most 20 records per discussion method. The parent must disclose
limits and attribute borrowed claims. The final export validator also checks that condition.

The parent uses MCP to create a pending review, add LINE/RIGHT inline comments, and submit COMMENT.
With no findings, it can create COMMENT directly. Each review has a run/attempt/head marker and
labeled overview. The structured final response must exactly match actual inline publication.
It must never approve, request changes, merge, edit code or settings, or touch another review.

## Permissions and boundaries

The model job has contents-read, PR-write for its MCP server, and actions-read to verify that an earlier review run completed successfully.
OpenCode itself receives no GitHub credential in its environment. A private MCP launcher supplies
the short-lived token only to the server process. Children have read/glob/grep permissions; the
parent additionally has exactly two task roles and four MCP tools. Shell, edits, external
directories, nested tasks, project configuration, LSP, formatting and session sharing are disabled.
Untrusted config text is escaped against `{env:...}` and `{file:...}` expansion.

No job has contents-write or OIDC access. Checkout credentials are not persisted. There is no
OpenCode App, provider key, or paid-model fallback. No automatic thread mutation is performed.

This is an owner-controlled experiment: workflow code comes from the PR. Before admitting arbitrary
contributors or making it authoritative, use protected orchestration and enforce publication
policy before tool execution. Current parent trace checks are postconditions: the consolidated
MCP review tool has broader capabilities than its prompt permits. Do not infer a trusted approval
gate from a passing run.

The full PR diff is bounded to 300 KB and attached once to each child. Parent execution
has an 11-minute timeout and 40 steps; children have 30 steps. Oversized output, malformed reports,
provider errors, incomplete sessions, invalid locations, or publication mismatches fail visibly.
Artifacts contain bounded redacted exports even when export fails or times out.

The free contributor offering permits prompts/completions to train future Meta models. Use public
source only, never account data, confidential code or diagnostic account exports. Runner usage is
separate from model pricing. See [OpenCode Zen](https://opencode.ai/docs/zen/) and
[permissions](https://opencode.ai/docs/permissions/).

## Evidence and remaining adoption work

The earlier control proved source-aware audits, real inline publication, and resolution:
[initial inline](https://github.com/aladh/Spotty/pull/268#discussion_r3939838965),
[isolated publisher success](https://github.com/aladh/Spotty/actions/runs/33978878101).
Those are historical control results, not native MCP evidence.

The native V1 [Actions run on `b21dc9a`](https://github.com/aladh/Spotty/actions/runs/33977771271)
proved two Muse `xhigh` children starting 34 ms apart and a parent using seven MCP reads plus one
MCP review write. It posted [this advisory review](https://github.com/aladh/Spotty/pull/268#pullrequestreview-5122040155).
The final comparison [native run on `83122b7`](https://github.com/aladh/Spotty/actions/runs/33979402835)
also passed. No inline findings were warranted in the first cited native run.

A [labeled native inline probe](https://github.com/aladh/Spotty/pull/268#discussion_r3941421046)
used OpenCode with Muse `xhigh` and the official MCP server to create a pending review, add one
RIGHT-side inline comment, and submit COMMENT. GitHub's individual comment endpoint verified the
exact body, path, line and SHA. This exposed and fixed a validator bug: the per-review list provides
legacy positions, so modern coordinates must be read from each individual comment. The probe used
the existing local GitHub identity, not an Actions token. It proves native MCP publication mechanics,
not independent bug discovery. The synthetic thread was explicitly marked complete and resolved.

Official OpenCode 2 beta `0.0.0-beta-19151` completed native audits, but its scoped deny-by-default
MCP permission configuration hid the tools in the [Actions trial](https://github.com/aladh/Spotty/actions/runs/33975552723).
Broad local permissions enabled real MCP reads; the intended restrictive policy did not. Keep V1
until V2 passes that policy test. A guided synthetic V1/V2 fixture took 68.92/36.92 seconds, but its
prompt named the bugs: it is compatibility evidence, neither independent discovery nor a benchmark.
The selected model catalog entry is checked in to avoid live-catalog drift and a V2 endpoint failure.

Before making this authoritative, assess known bugs and clean changes without revealing other
reviewers' answers, measure false positives, and add trusted revision-bound approval/check handling.
Successful plumbing and seeded probes do not establish review-quality parity with Cursor.
