# Contributing to DisplaySwitch

Thank you for helping improve DisplaySwitch. Small, focused changes with reproducible validation are easiest to review.

## Before editing

1. Read `AGENTS.md`, `README.md`, and `PROTOCOL.md`.
2. macOS contributors must also read `macOS/DEVELOPMENT_CHECKLIST.md`; Windows contributors must also read `Windows/DEVELOPMENT_CHECKLIST.md` and `Windows/README.md`.
3. Check existing issues before starting a large change.
4. Do not commit pairing codes, IP addresses, local paths, device identifiers, signing credentials, logs containing private data, or build products.

## macOS development

- Open `macOS/DisplaySwitcher.xcodeproj` in Xcode.
- Keep the existing Swift/AppKit implementation and macOS 12 deployment target.
- Build and test with the shared `DisplaySwitcher` scheme.
- The command-line release build is `./macOS/scripts/build-app.sh`.
- Do not perform real DDC input switching or USB handover as part of automated tests.

## Windows development

- The maintained implementation is the C++/WinUI 3 project in `Windows/DisplaySwitcher.Native`.
- `Windows/DisplaySwitcher.Windows` is migration reference code and is not a release target.
- Work through the numbered items in `Windows/DEVELOPMENT_CHECKLIST.md`.

## Protocol changes

`PROTOCOL.md` is the source of truth for cross-platform messages. A protocol change must define compatibility and rejection behavior, include shared test vectors where practical, and be implemented on both platforms. Never weaken validation, replay protection, expiry checks, or hardware safety to reduce latency.

## Pull requests

- Keep unrelated formatting and refactoring out of the change.
- Explain the problem, the smallest solution, files changed, and tests run.
- Separate automatic validation from hardware validation.
- Update documentation when behavior or limitations change.
- Confirm `git status` does not contain `outputs/`, `dist/`, `bin/`, `obj/`, `.build/`, credentials, pairing codes, or local configuration.
