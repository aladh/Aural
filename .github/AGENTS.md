# GitHub automation agent guidance

GitHub workflows and pull-request metadata are part of the verification and release boundary. Read
[agent operations](../CONTRIBUTING.md) and the
[enforcement inventory](../docs/architecture-enforcement.md) before changing them.

- Pin every GitHub Action to a full commit SHA and keep a readable version comment.
- Use least permissions and never expose credentials to untrusted pull-request code or logs.
- The required `Debug quality gate` must aggregate Rust verification, Swift/architecture
  verification, and the release compile. Parallelism and caches may reduce latency, never coverage.
- Preserve content-keyed Rust archive reuse and configuration-safe SwiftPM cache isolation. Treat
  cache contents, restore prefixes, and timestamp refreshes as correctness-sensitive build behavior.
- Do not install a second Swift formatter/linter in CI; use the selected Xcode toolchain and the
  repository wrappers. Prefer an existing runner `rg`, with the documented fallback only.
- Pull-request text must record outcome, design/risk, exact verification, live activity, and review
  resolution. Do not add human sign-off or manual-tester handoffs.
- Tags, releases, credentials, repository settings, and publication require explicit authorization.
  Never push a tag or publish an artifact merely to test a workflow.

Run `./Scripts/check-clean.sh` for workflow or release-boundary changes and inspect the workflow diff
for permissions, pins, trigger trust boundaries, shell interpolation, cache poisoning, and accidental
coverage reduction.
