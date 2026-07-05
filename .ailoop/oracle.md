# Oracle — ampere

The definition of done. Workers cite it; the coordinator gates against it.
Frozen means never *silently* changed (see SKILL.md amendment tiers).

## Locked decisions (never re-litigated)

Authoritative source: `SPEC.md` (repo root). Binding summary:

- Swift + SPM only, tools-version 6.0, **`swiftLanguageMode(.v5)` on every target**,
  min `macOS(.v14)`, **XCTest**, **zero third-party dependencies** (SPEC §2).
- Targets exactly: `AmpereCore` (lib), `ampered` (root daemon), `Ampere` (MenuBarExtra
  app), `ampere-cli`, `AmpereCoreTests` (SPEC §2).
- Architecture: daemon owns ALL SMC writes; app/cli talk to it over
  `/var/run/ampere.sock`, JSON lines, protocol exactly as SPEC §3.1; config exactly
  SPEC §3.2; paths/launchd label exactly SPEC §3 (SPEC §3).
- All control decisions live in the pure function `decide(...)` — SPEC §3.3 signature
  and decision rules are frozen, including hysteresis bounds, heat-always-wins,
  discharge floor 20%, calibration floor 15%.
- SMC write allowlist: `CHTE`, `CH0B`, `CH0C`, `CHIE`, `CH0I` — **only** these, only
  the enable/disable values in SPEC §4. Port from `docs/reference/bclm-SMC.swift`,
  keep its MIT header. Every write is followed by a read-back verification.
- Every failure/exit path re-enables charging and the adapter (SPEC §1, §3).
- Phase 0 writes `docs/smc-findings.md`; later SMC-touching tickets must follow it.

## Scope tripwire (halt if crossed)

- App Store / notarization / Developer-ID signing / auto-update
- Intel or pre-Tahoe Macs as targets
- Writing any SMC key outside the allowlist
- Analytics or ANY network call in any target
- Localization, extra preference panes, Shortcuts/AppleScript, MagSafe LED (SPEC §6)

## Baseline gate (every ticket, no exceptions)

Run from repo root (`~/Projects/ampere`):

- [ ] build: `swift build` → exit 0
- [ ] full test suite: `swift test` → exit 0, all tests pass
- [ ] new behavior ships with new XCTests, green under the above
      (exempt: pure scaffold/config tickets that say so)

No lint configured (locked: none in v1).

## Per-phase acceptance (executable)

Two tiers (SPEC §5): the baseline above is autonomous; the checks below marked
**[HW]** need the human present with charger + sudo and run at chunk checkpoints,
never inside worker sessions. A phase closes only when all its checks pass on the
merged tree.

### Phase 0 — SMC spike (go/no-go)
- [ ] `swift build && swift test` green
- [ ] `.build/debug/ampere-cli status` (no sudo) prints JSON; its `percent` matches
      `pmset -g batt` percentage ±1
- [ ] `.build/debug/ampere-cli keys` (no sudo) lists each allowlist key with
      exists/type/size from live SMC key-info
- [ ] `pause|resume|adapter` without root → clear error, exit code 1
- [ ] **[HW]** charger attached, battery <95%: `sudo .build/debug/ampere-cli pause` →
      ≤15 s `pmset -g batt` contains `not charging`; `resume` → charging resumes
- [ ] **[HW]** `sudo .build/debug/ampere-cli adapter off` → `pmset -g batt` shows
      `Battery Power` while plugged in; `adapter on` reverts
- [ ] **[HW]** `docs/smc-findings.md` records confirmed keys/types/values

### Phase 1 — Core + daemon
- [ ] control-core test suite covers the SPEC §3.3 decision table (hysteresis
      boundary cases 79/80/75 for limit 80, heat override, discharge floor,
      top-up completion) — tests enumerate contrasting inputs → differing commands
- [ ] socket loopback XCTest: real unix socket in temp dir, request → response
      round-trip for get-state/set-limit/error case
- [ ] `ampere-cli install --dry-run` prints plist path + bootstrap command
- [ ] **[HW]** `sudo ampere-cli install` → `launchctl print system/com.ampere.daemon`
      shows running; `ampere-cli state` (no sudo) returns live JSON
- [ ] **[HW]** limit set below current % → charging inhibited ≤60 s; survives
      10 min sleep; **[HW]** `sudo ampere-cli uninstall` → no launchd entry, no
      socket, charging normal

### Phase 2 — Menu bar app
- [ ] `scripts/make-app.sh` → `dist/Ampere.app` exists, `plutil -lint` passes,
      Info.plist has `LSUIElement=true`, binary present, `codesign -v` (ad-hoc) passes
- [ ] **[HW]** socket round-trip: set limit 65 via cli → app UI reflects 65; app
      launches showing menu bar item

### Phase 3 — Heat + stats
- [ ] telemetry ring-cap XCTest: >20,000 lines → file capped
- [ ] **[HW]** heatThresholdC set below current temp → `get-state` shows paused,
      reason heat, ≤60 s; cycles/capacity in stats match `ioreg -rn AppleSmartBattery`
- [ ] Stats window renders 24 h chart from telemetry fixture

### Phase 4 — Calibration
- [ ] calibration state machine fully covered by XCTests: discharge→charge→hold→done,
      abort from every phase restores limit mode, floors enforced (contrast cases)
- [ ] **[HW]** `action calibrate-start` → state `calibrating/discharge`, adapter
      disabled; `calibrate-abort` → limit mode, adapter enabled

## Caps

In `backlog.json`: maxAttempts 3 · thrash 2 · chunk 6 tickets/invocation.
