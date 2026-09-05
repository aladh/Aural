# Source-aware OpenCode advisory reviews (#233)

PR #268 tests a replacement for Cursor Thermos alongside CodeRabbit. It remains advisory and
confined to the same-repository `codex/opencode-review-spike` branch. It does not change the
[PR acceptance criteria](../CONTRIBUTING.md#automated-pr-acceptance), protections, or either existing
reviewer's role. #233 stays open for the adoption decision.

## Run and inspect

Push the trial PR or rerun **all jobs** in `OpenCode advisory review`. The workflow has two jobs:

1. `Source-aware OpenCode review` tests the reviewer, builds immutable source snapshots, runs the
   model without GitHub credentials, and validates its structured response.
2. `Publish advisory findings` uses a scoped Actions token in a separate runner,
   checks that the PR is still open at the expected base/head, and updates one advisory comment as
   `github-actions[bot]`. Only this job has `pull-requests: write`; neither job has OIDC access.

The comment lists active findings with stable IDs and links to exact source revisions, plus
explicit resolution reasons for previously open findings. These are model assessments, not
GitHub approvals or automatically resolved GitHub review threads. The workflow never submits
`APPROVE` or `REQUEST_CHANGES`. A green run means a validated advisory response was published,
not that the PR is correct.

`opencode-review-<run>-<attempt>` contains the validated report for 14 days. Diagnostic events
are retained separately for 7 days. Rerun all jobs after a transient failure: a publisher-only
rerun deliberately cannot reuse an artifact from a different attempt.

## Source access and incremental behavior

The model can read, glob and search `source/` at the PR head and `before/` at the comparison
revision. Raw Git blobs are used, so candidate export-ignore attributes cannot hide source and
symlinks/submodules are never followed. The full PR diff remains available. Previous review text
is supplied only for tracked OpenCode findings; other reviewers' comments and live PR prose are
not imported into the model prompt.

A prior result narrows the review to new commits only when its repository, PR, base SHA and
reviewer-policy digest match, its head is an ancestor, and its recorded workflow run/attempt
completed successfully. The model must still recheck **every** previously open finding. Each ID
must be retained or explicitly resolved; omissions, unknown IDs and duplicate IDs fail validation.
New findings receive deterministic IDs, and the publisher updates its existing comment instead
of posting duplicate comments on each push.

Missing/incompatible baselines, changed base commits, rewritten history, and changes to the
reviewer implementation, prompt, workflow or pins cause a full review. Rerunning the same head
also performs a full review and rechecks previous findings. Failed or stale runs never become
incremental baselines. Publication checks base/head immediately before and after the comment
write. GitHub cannot atomically bind an issue-comment write to a PR SHA; a racing push can leave
an explicitly old-SHA comment, but the run fails and that state is not reused as a successful
baseline.

## Boundaries and limits

The [workflow environment](../.github/workflows/opencode-spike.yml) owns the CLI version, release
checksum, free model and `xhigh` reasoning selection. The CLI release checksum is verified; there
is no provider key or paid fallback. The model process receives a small environment allowlist
without GitHub, OIDC, Actions runtime or local authentication tokens. Its working directory is a
source snapshot with no `.git` directory. Shell, writes, network tools, external directories,
subagents, skills, project configuration, external plugins, LSP, formatting and session sharing
are disabled. Only read/search tools are allowed; the CLI still contacts the model provider.

OpenCode Agent remains installed with **Only select repositories → aladh/Spotty**, as verified by
the initial availability spike. This iteration does not use its broad installation token or OIDC.
The separate publisher uses the short-lived Actions token with `contents: read` and
`pull-requests: write`; the model runner has read-only repository permissions and receives no token
in its subprocess environment. Do not broaden the App installation. This is an owner-controlled
trial: orchestration code comes from this PR. Before enabling arbitrary contributors or making it
a required gate, move orchestration and policy to a protected revision.

Each source tree is bounded to 25 MB of eligible blobs, individual files to 1 MB, and each diff
to 200 KB. Oversized diffs/snapshots fail rather than silently truncate. Non-text, oversized files,
symlinks and submodules omitted from snapshots are explicitly listed in the input and comment.
Findings must name an existing line in a text file changed by the PR. The model has a ten-minute
budget and 30 steps. Provider errors, incomplete output, invalid JSON, missing finding dispositions,
invalid locations and oversized comments fail visibly without replacing the prior comment.

The free contributor offering is temporary and permits using prompts/completions to train future
Meta models. Use public source only: no account data, credentials, diagnostic exports or confidential
code. Runner usage is separate from model pricing. Source access and structural validation reduce
some errors; they do not prove findings or resolutions are semantically correct.

## Evidence and adoption

The initial [App availability run](https://github.com/aladh/Spotty/actions/runs/33947896871) succeeded
with Muse `xhigh`. A local synthetic Swift bounds-check review found the seeded regression at
reported cost zero. The first diff-only PR response confidently misidentified the official upstream
and the exported prompt; its [disposition](https://github.com/aladh/Spotty/pull/268#issuecomment-5549761593)
is retained as a quality warning. Later diff-only responses had seen other reviewers' comments and
are not independent benchmarks.

The source-aware iteration is evaluated in #268 with deterministic lifecycle/validation tests and
live Actions results. Before making it authoritative, evaluate known bugs and clean changes without
other reviewers' answers, measure false positives and latency, and implement validated inline-thread
lifecycle and revision-bound approval/check publication using trusted orchestration. Do not promote
this comment-only trial to a required review gate solely because its Actions jobs pass.

Official references: [GitHub integration](https://opencode.ai/docs/github/),
[model/privacy terms](https://opencode.ai/docs/zen/), and
[tool permissions](https://opencode.ai/docs/permissions/), and
[GitHub comment permissions](https://docs.github.com/en/rest/issues/comments).
