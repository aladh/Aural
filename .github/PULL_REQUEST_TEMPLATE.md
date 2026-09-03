## Outcome

State the user-visible or repository outcome and why it is needed.

## Design and risk

Name the canonical owner, important design choice, affected failure modes, and remaining risk.

## Verification

List every command and result exactly; do not claim unperformed checks.

- [ ] Closest deterministic coverage was added or the absence of new coverage is explained
- [ ] Proportional repository gate passed, or the exact failure/constraint is recorded
- [ ] `git diff` / `git status --short` were inspected for unrelated, generated, or private files
- [ ] Canonical public/product/architecture/setup/security docs were updated when behavior changed
- [ ] No credentials, OAuth callbacks, diagnostics, real account payloads, or private screenshots are included

## Live and manual activity

State the macOS/build configuration and scenarios exercised. Explicitly say whether Aural was
launched and whether any Spotify playback, queue, device, library, playlist, follow, or account
mutation occurred. For authorized mutations, record scope and restoration.

## Review state

Reference issues in plain language such as `Contributes to #13`; never use issue-closing keywords.
Record how every actionable automated-review finding was fixed or explicitly declined, and leave no
valid review thread unresolved.
