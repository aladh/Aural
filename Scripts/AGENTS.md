# Build and verification script agent guidance

These scripts are repository policy executables, not convenience wrappers. Read the relevant
sections of [agent operations](../CONTRIBUTING.md) and the
[enforcement inventory](../docs/architecture-enforcement.md) before changing gate behavior.

- Run scripts from the repository root and preserve their fail-fast, warning-clean behavior.
- `check.sh` is the ordinary complete non-playback gate. CI scopes may partition it, but no scope or
  cache change may reduce aggregate coverage.
- Prefer compiler, behavior suite, ABI fixture, or package-graph enforcement. Add a source check only
  for an exact lexical/topology invariant; never encode concurrency, lifetime, queue provenance,
  rollback, or payload semantics as regex snapshots.
- Keep `check-clean.sh` the clean Debug-and-Release owner. Do not add destructive cleanup that can
  erase unrelated work or credentials.
- `script/build_and_run.sh` terminates a running Spotty executable and can touch an authenticated
  development session. Do not route compile-only verification through launch.
- Generated archives, app bundles, diagnostics, signing material, and caches stay outside Git. Never
  install project-generated identities in the login keychain or weaken signing to silence prompts.
- Shell changes must quote paths/values, propagate failures, use pinned inputs, and remain safe on the
  supported Apple-silicon macOS environment. Do not add Linux portability unless the product contract
  changes.
- Packaging, notarization, tag, release, credential, or repository-setting actions require explicit
  current-request authorization; never publish merely to exercise a script.
- `report-size.sh` is informational only: it reports release binary/archive size after
  `compile-release-spotty.sh` and must never fail the job over an optional tool (`size`, `nm`) being
  unavailable.

For script, build, CI, packaging, signing, or release-mechanics changes, run
`./Scripts/check-clean.sh` plus the affected command in its non-publishing mode. Report exact commands,
configuration, generated outputs, and any external action that was intentionally not performed.
