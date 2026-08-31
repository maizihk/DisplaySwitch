# Security policy

## Supported versions

Security fixes target the latest released version and the current `main` branch. Older builds may not receive backports.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature under the repository Security tab. If private reporting is not available, open a minimal issue asking the maintainer for a private contact method; do not include exploit details, pairing codes, IP addresses, device identifiers, logs, or credentials in that issue.

Please include the affected platform and version, impact, reproduction conditions, and whether real USB/DDC hardware is required. Allow maintainers reasonable time to investigate before public disclosure.

## Security boundaries

- Protocol v2 derives direction-specific HMAC-SHA256 keys from the pairing code with PBKDF2, validates endpoints and timestamps, and rejects replay. It authenticates messages but does not encrypt their contents; use it only on a trusted local network.
- Status probes must not trigger display wake, USB actions, or DDC input changes.
- The macOS native DDC backend uses private CoreDisplay/IOAVService interfaces and runs without App Sandbox. Treat downloaded builds and update sources accordingly.
- Never attach a real pairing code or unredacted diagnostic log to a public report.
