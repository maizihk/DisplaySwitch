# Support

Use GitHub Issues for reproducible bugs and feature requests. Before opening an issue:

1. Read `README.md`, [`COMPATIBILITY.md`](COMPATIBILITY.md), the platform README, and existing issues.
2. Confirm the problem still occurs on the latest `main` source build or newest clearly labelled test build.
3. Record the app version, operating system version, CPU architecture, connection type, and whether DDC/CI works through the current cable, adapter, dock, and GPU driver.
4. Remove pairing codes, IP addresses, user names, local paths, device serial numbers, and unrelated log content.

Hardware compatibility varies. A monitor supporting DDC/CI does not guarantee that every cable, adapter, dock, GPU, or operating-system API will pass the commands through. Maintainers may ask for a safe status check, but users should not run a real input-source or USB handover test unless they understand its effect.

Use the anonymized compatibility report template in [`COMPATIBILITY.md`](COMPATIBILITY.md). Review the in-app diagnostic preview before copying it and never attach raw device identifiers or configuration files.

Security vulnerabilities must follow `SECURITY.md`, not a public support issue.
