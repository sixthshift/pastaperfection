# PastaPerfection

PastaPerfection is a free, self-built replacement for AlDente (free + Pro features),
targeting exactly one machine: **MacBook Pro 18,3 (M1 Pro), macOS 26.3 (Tahoe
firmware), Apple Silicon.** It's a DIY charge-limit / battery-health tool for
that machine only — think "AlDente, but I own the whole stack": a menu bar
app plus a small root daemon that talks directly to SMC to hold your battery
at a charge limit, protect it from heat, and (later) run calibration cycles.

It is **not** a general-purpose app. Fallback SMC keys and values recorded in
this repo are empirically confirmed on this specific machine's firmware only
— see `SPEC.md` and `docs/smc-findings.md`.

## What it does

- **Charge limit** — stop charging at a user-set limit (50–100%), resume with
  hysteresis.
- **Sailing mode** — let the battery drain below the limit before resuming,
  instead of holding right at it.
- **Discharge to limit / Top-up** — one-shot actions: run on battery down to
  the limit, or charge to 100% once.
- **Heat protection** — pause charging above a temperature threshold.
- **Stats** — battery health, cycle count, temperature, wattage, history.
- **Calibration** — scheduled/manual discharge → charge → hold cycle.

Full design is locked in `SPEC.md`.

## Architecture

```
PastaPerfection.app (menu bar, user)   ─┐
                                ├─ JSON lines over /var/run/ampere.sock ──▶ pastaperfectiond (root, launchd)
pastaperfection-cli (user/sudo)        ─┘                                            owns ALL SMC writes
```

Only `pastaperfectiond` ever writes SMC keys, and only the keys on the allowlist in
`SPEC.md` §4. The menu bar app and CLI are thin clients over a local Unix
socket.

## Building

Requires the Swift 6.3 toolchain (Command Line Tools; no full Xcode install
needed) on macOS 14+.

```sh
swift build              # build all targets in debug
bash scripts/test.sh     # run the full Swift Testing suite (see note below)
```

`scripts/test.sh` is the canonical test runner. Plain `swift test` does not
work on a CLT-only machine (no bundled XCTest); the script supplies the
flags needed to run Swift Testing directly. Always use it instead of
`swift test`.

### Building the menu bar app bundle

```sh
bash scripts/make-app.sh
```

This builds a release build of every target and assembles
`dist/PastaPerfection.app` (`LSUIElement=true`, ad-hoc code-signed with
`codesign -s -`). It also copies the `pastaperfectiond` daemon and `pastaperfection-cli` into
`Contents/Resources/` so the app's "daemon not installed" prompt can point at
a known-good, bundled copy of the CLI. Re-running the script is safe — it
always rebuilds and re-assembles the bundle from scratch.

Open `dist/PastaPerfection.app` to run the menu bar app. It shows a battery-percent
item in the menu bar; there's no Dock icon or app-switcher entry
(`LSUIElement`).

## Installing / uninstalling the daemon

The menu bar app talks to a root daemon (`pastaperfectiond`) that must be installed
once via `pastaperfection-cli`, either the bundled copy
(`PastaPerfection.app/Contents/Resources/pastaperfection-cli`) or the one built by
`swift build` at `.build/debug/pastaperfection-cli` / `.build/release/pastaperfection-cli`.
When the app can't reach the daemon it shows the exact command to run,
derived from wherever `pastaperfection-cli` actually is:

```sh
sudo <path-to-pastaperfection-cli> install
```

This installs `pastaperfectiond` to `/Library/PrivilegedHelperTools/`, writes the
launchd plist at `/Library/LaunchDaemons/com.ampere.daemon.plist`, and
bootstraps it into `launchd` (`RunAtLoad=true`, `KeepAlive=true`).

To remove it:

```sh
sudo <path-to-pastaperfection-cli> uninstall
```

Uninstalling boots the daemon out of `launchd`, removes the installed files
and socket, and restores normal charging before it exits (every daemon
failure/exit path re-enables charging — see `SPEC.md` §1).

## Launch at login

The popover has a "Launch at login" toggle, backed by
`SMAppService.mainApp`. It only appears when PastaPerfection is running from a real
app bundle (`dist/PastaPerfection.app`) — a bare binary built by `swift build` has no
bundle identifier and can't register as a login item, so the toggle is
hidden in that case rather than shown broken.

## IMPORTANT: turn off macOS's native charge limit

**macOS Settings → Battery → Charge Limit must stay OFF (or set to 100%)
while PastaPerfection is active.** PastaPerfection and Apple's built-in charge limit both try
to control the same SMC charging-inhibit keys; running both at once means
two controllers fighting over the same hardware state, with unpredictable
results. Use one or the other, not both. (SPEC.md §8.)

## Firmware canary: `writeVerified`

Every SMC write PastaPerfection makes is followed by a read-back to confirm it took
effect (SPEC.md §4). If a write appears to have had no effect — e.g. PastaPerfection
asked for charging to be inhibited but the readback still shows the old
value — `get-state` reports `writeVerified: false`. This is a canary for
firmware drift: **a macOS update can silently change SMC key behavior**,
and if that happens, PastaPerfection's SMC control may stop working until the keys
are re-probed and, if necessary, this repo's key table
(`docs/smc-findings.md`) is updated for the new firmware. Treat
`writeVerified: false` as "stop trusting the current mode until this is
re-checked," not as a transient glitch to ignore.
