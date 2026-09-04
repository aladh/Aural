# Development launch script agent guidance

This directory owns the build, sign, terminate, and launch entry point. Read
[agent operations](../CONTRIBUTING.md#build-and-run) and
[development setup](../docs/development-setup.md) before changing it.

- `build_and_run.sh` is not a compile-only helper: it can rebuild Rust, package and sign the app,
  terminate a running Spotty executable process, launch a replacement, and touch an authenticated
  session.
  Require explicit current-request authorization for launch or interactive acceptance.
- Authenticated launches require an Apple-issued development identity with a stable Team ID. Do not
  weaken anchor or Team-ID validation, silently fall back to self-signing, or install generated
  identities in the login keychain to suppress prompts.
- Preserve non-destructive failure ordering: signing validation must fail before terminating the
  running app. Never erase credentials or unrelated generated state as recovery.
- `./Scripts/package-app.sh --debug` and `./Scripts/package-app.sh --release` package, sign, and
  validate the Spotty executable bundle without terminating or launching it.
