# Security Policy

## Reporting a vulnerability

Do not open a public issue with vulnerability details, credentials, OAuth callbacks, or account
data. Use GitHub's **Security → Report a vulnerability** flow for this repository. If private
vulnerability reporting is unavailable, open a public issue containing only a request to enable a
private reporting channel; include no vulnerability details until that channel exists.

Reports should include the affected commit/version, impact, reproduction conditions, and a minimal
proof of concept with all Spotify account data and tokens removed. Security triage and remediation
are agent-owned and best-effort; this experimental personal project does not promise a response or
fix timeline.

## Supported versions

Only the latest commit on the default branch is supported. There are currently no supported binary
releases.

## Scope

Useful reports include:

- Exposure of OAuth credentials, tokens, or account data beyond the local user
- Loopback OAuth callback validation or local-request attacks
- Unsafe Keychain or development credential-storage behavior
- Code execution, arbitrary file access, or memory-safety bugs reachable from network data
- Rust/Swift FFI lifetime, ownership, bounds, or concurrency vulnerabilities
- Diagnostics or logs that include credentials or private response payloads

Expected Spotify protocol breakage, policy questions, and the inherent risk of depending on private
interfaces are not security vulnerabilities. See the warning in [README.md](README.md).

## Disclosure

Allow reasonable time for agent-driven investigation and remediation before public disclosure. Never
send working Spotify credentials or another person's account data with a report.
