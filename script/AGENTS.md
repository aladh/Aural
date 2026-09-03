# Development launch script agent guidance

This directory owns the build, sign, terminate, and launch entry point. Read
[agent operations](../CONTRIBUTING.md#build-and-run) and
[development setup](../docs/development-setup.md) before changing it.

- `build_and_run.sh` is not a compile-only helper: it can rebuild Rust, package and sign the app,
  terminate a running Aural process, launch a replacement, and touch an authenticated session.
  Require explicit current-request authorization for launch or interactive acceptance.
- Authenticated launches require an Apple-issued development identity with a stable Team ID. Do not
  weaken anchor or Team-ID validation, silently fall back to self-signing, or install generated
  identities in the login keychain to suppress prompts.
- Preserve non-destructive failure ordering: signing validation must fail before terminating the
  running app. Never erase credentials or unrelated generated state as recovery.
- Quote paths and values, propagate failures, avoid exposing identities or credential material in
  logs, and keep behavior aligned with the supported Apple Silicon macOS environment.
- Packaging, notarization, tag, release, credential, or repository-setting actions remain outside
  this script's routine verification authority.

For changes here, run `./Scripts/check-clean.sh`, then use
`./Scripts/package-app.sh --debug` as the standard non-publishing packaging verification. Use
`./Scripts/package-app.sh --release` when the affected change requires a release build. Both modes
package, sign, and validate Aural without terminating or launching it. State whether a launch occurred
and whether any live Spotify action was performed.
