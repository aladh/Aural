# Thermos-style OpenCode advisory reviews (#233)

PR #268 tests a replacement for Cursor Thermos alongside CodeRabbit. It remains advisory and
confined to the same-repository `codex/opencode-review-spike` branch. It does not change the
[PR acceptance criteria](../CONTRIBUTING.md#automated-pr-acceptance), protections, or either existing
reviewer's role. #233 stays open for the adoption decision.

## Run and inspect

Push the trial PR or rerun **all jobs** in `OpenCode advisory review`. The workflow has two jobs:

1. `Source-aware OpenCode review` tests the reviewer, builds immutable source snapshots, runs
   independent correctness/security and maintainability audits in parallel, then synthesizes their
   findings. Each model process runs without GitHub credentials and returns validated JSON.
2. `Publish advisory findings` uses a scoped Actions token in a separate runner,
   checks that the PR is still open at the expected base/head, and updates one advisory overview
   plus inline diff comments as `github-actions[bot]`. Only this job has `pull-requests: write`;
   neither job has OIDC access.

The comment lists active findings with stable IDs and links to exact source revisions, plus
explicit resolution reasons for previously open findings. Each finding also appears on the diff.
Unchanged findings update their own bot thread; moved findings receive a current anchor, and
explicitly resolved findings close only the corresponding OpenCode-owned thread. Resolution
reasons are model assessments, not proof of correctness. Human and other reviewers' threads are
never changed. The workflow never submits `APPROVE` or `REQUEST_CHANGES`. A green run means a validated advisory response was published,
not that the PR is correct.

`opencode-review-<run>-<attempt>` contains the validated report for 14 days. Diagnostic events
are retained separately for 7 days. Rerun all jobs after a transient failure: a publisher-only
rerun deliberately cannot reuse an artifact from a different attempt.

## Thermos review process

The rubrics are vendored verbatim from [Cursor Thermos](https://github.com/cursor/plugins/tree/93b00b89ef425a9c1bac0d0b317dfc49c930ac99/thermos),
pinned to commit `93b00b89ef425a9c1bac0d0b317dfc49c930ac99`, under
[`.github/review/thermos/`](../.github/review/thermos/). Cursor's MIT license is retained alongside
correctness, code-quality and orchestration references. There is no runtime download of prompts.

Like `/thermos`, this workflow performs two independent audits of the same source/diff context:

- **Correctness/security:** bugs, cross-module breakage, developer setup regressions, feature-gate
  leaks, intended changes and calibrated severity. Findings require completed source investigation.
- **Maintainability:** substantial simplification, branching growth, abstractions, typed contracts,
  canonical layers, needless sequential work and non-atomic updates. The rubric explicitly checks
  files growing from below 1,000 lines to above that threshold and rejects low-value cosmetic nits.

After both finish, a separate synthesis pass deduplicates findings, weighs independent agreement,
resolves disagreements against source, and produces one prioritized report. If the correctness
pass found P1/P2 risks, a read-only workflow step first gathers bounded PR discussion for the
synthesis pass. Borrowed findings must be verified and attributed by author and comment URL;
other reviewers' claims are not independent corroboration. Neither initial audit sees that
material or the other audit's result.

The adaptation uses parallel isolated CLI processes instead of Cursor's Task subagents, all on
Muse contributor-free with `xhigh`. The checked-in common prompt retains the review-only tool
limits and structured finding lifecycle. It overrides upstream instructions to invoke CLI tools,
edit files or issue approval; the upstream quality bar remains review guidance. Compared with
Cursor's interactive workflow, GitHub discussion is gathered by orchestration, publication remains
one advisory overview with tracked diff comments, and failed passes stop publication. This is process/rubric parity, not a
claim that Muse matches Cursor's review quality.

## Source access and incremental behavior

The model can read, glob and search `source/` at the PR head and `before/` at the comparison
revision. Raw Git blobs are used, so candidate export-ignore attributes cannot hide source and
symlinks/submodules are never followed. The full PR diff remains available. Prior OpenCode findings
and bounded event-snapshot PR intent are supplied as untrusted context. Other reviewers' discussion
is available only to the later synthesis pass under the Thermos condition above.

A prior result narrows the review to new commits only when its repository, PR, base SHA and
reviewer-policy digest match, its head is an ancestor, and its recorded workflow run/attempt
completed successfully. The model must still recheck **every** previously open finding. Each ID
must be retained or explicitly resolved; omissions, unknown IDs and duplicate IDs fail validation.
New findings receive deterministic IDs, and the publisher updates its existing comment instead
of posting duplicate overview comments on each push. Inline comments use the same finding IDs;
source locations must be valid right-side anchors in the full PR diff.

Missing/incompatible baselines, changed base commits, rewritten history, and changes to the
reviewer implementation, prompt, workflow or pins cause a full review. Rerunning the same head
also performs a full review and rechecks previous findings. Failed or stale runs never become
incremental baselines. Publication checks base/head immediately before and after the comment
write, and before inline mutations. GitHub cannot atomically bind all comment writes to a PR SHA;
a racing push or API failure can leave a partial set of explicitly revision-bound comments. The
run fails, retries reconcile owned finding IDs, and the overview is updated only after inline
publication succeeds, so incomplete state is not reused as a successful baseline.

## Boundaries and limits

The [workflow environment](../.github/workflows/opencode-spike.yml) owns the CLI version, release
checksum, free model and `xhigh` reasoning selection. The CLI release checksum is verified; there
is no provider key or paid fallback. The model process receives a small environment allowlist
without GitHub, OIDC, Actions runtime or local authentication tokens. Its working directory is a
source snapshot with no `.git` directory. Shell, writes, network tools, external directories,
subagents, skills, project configuration, external plugins, LSP, formatting and session sharing
are disabled. Only read/search tools are allowed; the CLI still contacts the model provider.

The initial availability spike tested OpenCode Agent with access only to `aladh/Spotty`. The App
was subsequently uninstalled: this CLI-based workflow needs neither its installation nor its broad
token or OIDC.
The separate publisher uses the short-lived Actions token with `contents: read` and
`pull-requests: write`; the model runner has read-only repository permissions and receives no token
in its subprocess environment. No GitHub App installation is required. This is an owner-controlled
trial: orchestration code comes from this PR. Before enabling arbitrary contributors or making it
a required gate, move orchestration and policy to a protected revision.

Discussion collection reads at most three pages per kind, retaining the newest 20 records within
that bounded history and at most 2,000 characters per body. Truncation and omitted records are
recorded for synthesis; this is not an exhaustive scan of a long PR history. Inline publication
currently requires a right-side hunk anchor in a text file present at the head; removed-only files
and non-text changes remain a coverage limitation.

Each source tree is bounded to 25 MB of eligible blobs, individual files to 1 MB, and each diff
to 200 KB. Oversized diffs/snapshots fail rather than silently truncate. Non-text, oversized files,
symlinks and submodules omitted from snapshots are explicitly listed in the input and comment.
Findings must name an existing line in a text file changed by the PR. Each model pass has a
ten-minute budget and 30 steps; the two independent audits run concurrently. The review job has
a 25-minute limit including synthesis and setup. Provider errors, incomplete output, invalid JSON, missing finding dispositions,
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

The first source-aware [Actions run](https://github.com/aladh/Spotty/actions/runs/33950084958)
passed on `d2302e1`: the model made nine source reads in 126 seconds, returned a validated
no-findings result, and the separate scoped-token publisher posted the
[advisory comment](https://github.com/aladh/Spotty/pull/268#issuecomment-5550007223).
All 14 deterministic reviewer tests and normal PR CI passed. Separate local source-aware fixtures
found a seeded Swift bounds regression, then retained its finding ID in an explicit resolution
when the next revision fixed it. These are integration checks, not a review-quality benchmark.

After uninstalling the App, the [incremental run](https://github.com/aladh/Spotty/actions/runs/33950370819)
passed on `55e8853`. Its report selected `d2302e1` as the verified baseline, and the publisher updated
the same comment ID. The model made 14 reads in 156 seconds and reported no findings. This proves
baseline selection and comment reuse without the App; it does not demonstrate a latency saving.

The Thermos adaptation passed a local source-only fixture with both a bounds-check crash and a
60-branch structural regression: the independent passes found their respective issues and synthesis
kept both. Early synthesis retained an unsupported future-edit-count claim; an explicit
counterexample check removed that claim in the revised run. The fixed snapshot then produced zero
active findings and explicit resolutions for both original IDs across all three passes. This
fixture is an integration/calibration check, not a representative accuracy benchmark. Thirty
standard-library tests cover lifecycle, parallel isolation, validation, and owned inline publication;
the live GitHub GraphQL thread query was also verified read-only.

The earlier Actions runs predate the two-audit Thermos adaptation. The current iteration is evaluated in #268 with deterministic lifecycle/validation tests and
live Actions results. Before making it authoritative, evaluate known bugs and clean changes without
other reviewers' answers, measure false positives and latency, and implement revision-bound
approval/check publication using trusted orchestration. Do not promote
this advisory trial to a required review gate solely because its Actions jobs pass.

Official references: [GitHub integration](https://opencode.ai/docs/github/),
[model/privacy terms](https://opencode.ai/docs/zen/),
[tool permissions](https://opencode.ai/docs/permissions/), and
[GitHub comment permissions](https://docs.github.com/en/rest/issues/comments).
