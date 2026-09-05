# OpenCode reviewer spike (#233)

The target is a second authoritative reviewer that can replace Cursor's Thermos automation,
alongside CodeRabbit. First prove a free model can return a useful review in GitHub Actions.
This spike does not change the [PR acceptance criteria](../CONTRIBUTING.md#automated-pr-acceptance)
or repository protections. Issue #233 stays open for the implementation decision.

## Run and inspect

The `OpenCode review spike` workflow runs on updates to a same-repository PR whose head branch is
`codex/opencode-review-spike`. Open or push that PR, then inspect its Actions job summary and the
`opencode-spike-<head>-<attempt>` artifact. It records the input base/head revisions, model, CLI
version, runner log, and the App's posted review comment. Rerun a failed job to distinguish transient
provider failure from repeatable failure. A green job means the runner succeeded and the App posted
an advisory response, not that the review is complete or the PR approved.

OpenCode Agent is installed with **Only select repositories → aladh/Spotty**. The workflow uses
its official `opencode github run` integration and OIDC token exchange. The App requests read/write
access to code, issues, pull requests, secrets and workflows; GitHub's workflow-token permissions
do not reduce that installation token. Keep the installation confined to Spotty.

The [workflow's job environment](../.github/workflows/opencode-spike.yml) owns the CLI version,
release checksum, model and reasoning pins. The runner downloads that official release and verifies
its SHA-256.
This invokes the same entrypoint as the official composite action while avoiding its unpinned
latest-version installer. It uses the selected free model without a provider API key, with the
reasoning variant explicitly selected. There is no paid-model fallback.
Provider errors and timeouts fail the job. A successful run
also needs an advisory comment from `opencode-agent[bot]` linking to that Actions run.

The runner fetches a bounded public PR diff with a read-only GitHub token. The official integration
checks out the PR, obtains an App token, adds PR/comment context, and posts the response. Model
tools are denied, project configuration and external plugins are disabled, and session sharing is
off. The model receives the diff as text and cannot execute candidate code or inspect surrounding
source. This tests App authentication, model transport, and basic review usefulness, not full
agentic review quality. Diffs over 100 KB are rejected, not truncated. The official runner fetches
the live PR branch/context, so its output is advisory even when the supplied diff has recorded SHAs.

OpenCode lists this model as free for a limited time. Its contributor terms permit using prompts
and completions to train future Meta models. This experiment is for public source only; do not
provide private account data, credentials, diagnostic exports, or confidential code. GitHub runner
usage remains separate from model pricing.

## Evidence before adoption

The first [Actions run](https://github.com/aladh/Spotty/actions/runs/33947896871) at input head
`a84ec470972f99603328bfb09987d8167e87d97f` succeeded in 1m22s and posted an App comment with `xhigh`
selected. A separate local xhigh synthetic bounds-check review found the seeded bug and reported
cost zero. However, the first PR review incorrectly claimed the exported `PROMPT` was unused and
that the official upstream was a fork. The [maintainer disposition](https://github.com/aladh/Spotty/pull/268#issuecomment-5549761593)
records the evidence and remaining limitations. The integration works; this result does not justify
an authoritative gate. The official runner posts ordinary comments, with no built-in incremental
baseline, finding deduplication, or approval-state lifecycle.

Record the workflow run, reviewed revision, latency, errors, and findings in the spike PR. Compare
findings with existing reviewers and independently check each claim. A successful request is only
permission to proceed with the reviewer implementation, not evidence for making it required.

The next implementation needs immutable revision-bound input, surrounding-source access without
executing candidate configuration, structured and validated inline findings, deduplication, and
incremental reviews that recheck unresolved findings after fixes. It also needs a separate trusted
publisher for GitHub review threads/approval and a fail-closed check tied to the current head.
Unavailable models and stale or partial reviews must never yield an approval. Test those behaviors
before changing the authoritative gates or removing Cursor. Keep CodeRabbit's role unchanged.

Official references: [GitHub integration](https://opencode.ai/docs/github/),
[models and privacy](https://opencode.ai/docs/zen/),
[tool permissions](https://opencode.ai/docs/permissions/), and
[pinned release](https://github.com/anomalyco/opencode/releases/tag/v1.18.29).
