# Security Policy

## Reporting a vulnerability

Do not open a public issue with vulnerability details, credentials, OAuth callbacks, or account
data. Use GitHub's **Security → Report a vulnerability** flow for this repository. If private
vulnerability reporting is unavailable, contact the maintainer through the contact method on their
GitHub profile and include only a request for a private channel until one is established.

Reports should include the affected commit/version, impact, reproduction conditions, and a minimal
proof of concept with all Spotify account data and tokens removed. You should receive an initial
response within seven days.

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

Please allow reasonable time to investigate and prepare a fix before public disclosure. Never send
working Spotify credentials or another person's account data with a report.
