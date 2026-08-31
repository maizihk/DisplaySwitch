# DisplaySwitch compatibility and validation boundaries

DisplaySwitch controls hardware through operating-system display APIs. A display supporting DDC/CI does not guarantee that every GPU, cable, adapter, dock, KVM, port, or operating-system release will pass the same command in both directions.

This document describes the current `main` branch. It is a capability boundary, not a universal hardware compatibility claim.

## Supported runtime paths

| Platform | Maintained DDC path | Current boundary |
| --- | --- | --- |
| macOS | Apple Silicon CoreDisplay/IOAVService | Uses private Apple interfaces. Intel Mac is reported as unsupported. There is no m1ddc process fallback or software-dimming fallback. |
| Windows | Native Dxva2 | Requires a unique current physical-monitor binding. There is no ControlMyMonitor process fallback. |

Native failure is reported as failure. Cached values may be shown as estimates, but they are not presented as a successful current read.

## macOS private-API risk

The Apple Silicon backend uses private CoreDisplay/IOAVService interfaces because macOS does not provide a public API for the required external-display DDC/CI operations. Apple can change these interfaces, service topology, entitlement behavior, or reply semantics without notice.

Consequences:

- a macOS update can break enumeration, reads, writes, or input-source switching even when the display and cable are unchanged;
- a successful build and local signature verification do not prove that the private API still works on the installed OS;
- every macOS major update, and any update that changes display firmware or drivers, requires renewed read-only enumeration and DDC validation before automatic switching is trusted;
- ambiguous service matching fails closed instead of guessing another display.

The local-network permission is separate from DDC. Denying local-network access can stop collaboration, but it does not explain a local DDC read or write failure. The macOS “协同” page contains a “本地网络权限” module; ambiguous timeouts are not labelled as an explicit system denial.

## Connection-path differences

Treat the complete path as the compatibility unit:

```text
computer and OS → GPU/display service → port → cable/adapter/dock/KVM → display input → VCP code
```

Changing any element can change behavior. In particular:

- read and write support can differ on the same path;
- brightness, contrast, volume, and input-source switching can each differ;
- USB-C to USB-C, USB-C to DisplayPort, built-in HDMI, and USB-C dock to HDMI must be tested separately;
- a dock may expose an HDMI output through an upstream DisplayPort-style service, so a transport label alone does not prove the downstream electrical path;
- the first successful read can be slower while a per-service strategy is learned; reconnecting or changing interfaces invalidates that strategy;
- two identical displays must remain uniquely matched. Ambiguity is a safe failure, not permission to try each device.

Observed project acceptance covers one Apple Silicon setup with built-in HDMI, direct USB-C to DisplayPort, and USB-C dock to HDMI reads. It also found lower input-source reliability on one USB-C to USB-C path than on the corresponding USB-C to DisplayPort path. These observations guide diagnostics but are not brand or model rules.

## What each validation result proves

| Level | Proves | Does not prove |
| --- | --- | --- |
| Source/type check | Code parses and type-checks with the selected SDK | App launch, UI layout, hardware access |
| Unit/contract tests | Pure state, protocol, privacy, cancellation, and simulated failure behavior | Real UDP routing, TCC prompts, USB notifications, DDC passthrough |
| Debug/Release build | Project compiles and links | Runtime behavior on another machine |
| Local/ad-hoc signature verification | Bundle/archive integrity and local signature structure | Developer ID trust, notarization, Gatekeeper acceptance on another Mac |
| CI artifact | Clean hosted-runner build and automated tests | Commercially signed release or hardware compatibility |
| GUI validation | Visible layout and interaction on the tested OS, scale, and theme | Other DPI/theme/OS combinations or hardware behavior |
| Hardware validation | The named operation worked on the tested complete connection path | Other ports, cables, docks, displays, OS releases, or VCP codes |

Current macOS ZIPs are locally/ad-hoc signed test builds. Current Windows packages are unsigned framework-dependent test builds. Neither is a notarized or commercially signed release.

## Safe compatibility test order

1. Record the app version, OS version, architecture, display count, and connection-path category.
2. Confirm DDC/CI is enabled in the display's own menu.
3. Open the app and verify the expected logical display count and unique names.
4. Use the explicit read action first. A read must not switch inputs or perform USB/network actions.
5. Test brightness, contrast, and volume separately only after a trustworthy read or after preparing a manual recovery method.
6. Test input-source switching last. Keep physical controls available so the previous input can be restored.
7. Re-test after hot-plug, interface change, dock change, sleep/resume, or an OS update.

Do not begin with unattended, remote-only, or whole-system sleep tests.

## Anonymized compatibility report template

Copy the template below into an Issue. Optional display make/model information may be included if it is already public and useful; never include a serial number.

```text
DisplaySwitch version/build:
Platform and OS version:
CPU architecture:
Display count:
Display make/model (optional; no serial number):
Connection path category: built-in HDMI / USB-C to USB-C / USB-C to DP / dock to HDMI / adapter / KVM / other
DDC/CI enabled in display menu: yes / no / unknown
Operation: enumerate / read brightness / read contrast / read volume / write / input source / collaboration / USB
Result: success count / attempt count / visible effect / exact user-facing error
Changed after reconnect, sleep/resume, interface change, or OS update: yes / no / not tested
Diagnostic preview reviewed and attached: yes / no
Manual recovery available before input-source or USB test: yes / no / not applicable
```

Before submitting, remove:

- pairing codes, authentication tags, endpoint IDs, IP addresses, host names, and event/nonce values;
- user names, home-directory paths, configuration paths, and local file names;
- display UUIDs, serial numbers, IORegistry paths, Windows device paths, Container IDs, EDID data, and USB identifiers;
- unrelated logs or screenshots containing personal information.

Use the in-app diagnostic preview when available, inspect the visible text before copying, and follow [`SECURITY.md`](SECURITY.md) for vulnerabilities.
