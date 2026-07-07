# Oracle — ampere

The definition of done. Workers cite it; the coordinator gates against it.
Frozen means never *silently* changed (see SKILL.md amendment tiers).

## Locked decisions (never re-litigated)

Authoritative source: `SPEC.md` (repo root). Binding summary:

- Swift + SPM only, tools-version 6.0, **`swiftLanguageMode(.v5)` on every target**,
  min `macOS(.v14)`, **Swift Testing** (amended, see ledger 0004), **zero third-party dependencies** (SPEC §2).
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
- [ ] full test suite: `bash scripts/test.sh` → exit 0, all tests pass
      (canonical runner; plain `swift test` does NOT work on this CLT-only
      machine — see ledger 0005. Wherever this oracle or a ticket says
      `swift test`, run `bash scripts/test.sh`.)
- [ ] new behavior ships with new Swift Testing tests, green under the above
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
- [ ] socket loopback Swift Testing test: real unix socket in temp dir, request → response
      round-trip for get-state/set-limit/error case
- [ ] `ampere-cli install --dry-run` prints plist path + bootstrap command
- [ ] **[HW]** `sudo ampere-cli install` → `launchctl print system/com.ampere.daemon`
      shows running; `ampere-cli state` (no sudo) returns live JSON
- [ ] **[HW]** limit set below current % → charging inhibited ≤60 s; survives
      10 min sleep; **[HW]** `sudo ampere-cli uninstall` → no launchd entry, no
      socket, charging normal

### Phase 2 — Menu bar app
- [ ] `scripts/make-app.sh` → `dist/PastaPerfection.app` exists (user-facing name
      renamed from Ampere, commit b1955c0, 2026-07-06 — see ledger; SPM targets
      unchanged), `plutil -lint` passes,
      Info.plist has `LSUIElement=true`, binary present, `codesign -v` (ad-hoc) passes
- [ ] **[HW]** socket round-trip: set limit 65 via cli → app UI reflects 65; app
      launches showing menu bar item

### Phase 3 — Heat + stats
- [ ] telemetry ring-cap Swift Testing test: >20,000 lines → file capped
- [ ] **[HW]** heatThresholdC set below current temp → `get-state` shows paused,
      reason heat, ≤60 s; cycles/capacity in stats match `ioreg -rn AppleSmartBattery`
- [ ] Stats window renders 24 h chart from telemetry fixture

### Phase 4 — Calibration
- [ ] calibration state machine fully covered by Swift Testing tests: discharge→charge→hold→done,
      abort from every phase restores limit mode, floors enforced (contrast cases)
- [ ] **[HW]** `action calibrate-start` → state `calibrating/discharge`, adapter
      disabled; `calibrate-abort` → limit mode, adapter enabled

### Phase 5 — v2 dashboard (SPEC §9, added 2026-07-06)

Locked additions (§9.2–§9.6 are binding on workers): telemetry archive via
downsample-on-rotate (15-min `ArchiveSample` buckets, 40,000-line ring,
`telemetry-archive.jsonl`); additive protocol deltas only (`StatsSample.chargingPaused`
default-`false` decode, `GetStatePayload.adapter: AdapterPayload?`,
`get-stats hours:0` = all history merged + server-downsampled ≤2,000);
`AdapterDetails` parsed from the same AppleSmartBattery dict, reads only —
**Phase 5 writes zero SMC keys**; pure derived logic (time-to-limit, sessions)
in `AmpereCore`; one scrolling dashboard window, timers no-op when window not
visible. Additional tripwires (SPEC §9.9): no export/sync, no per-app energy,
no history editing, no extra charts/zoom/pan, no menu-bar sparkline.

Autonomous checks (merged tree):
- [ ] bucketing: contrast test — samples spanning two 15-min buckets → 2 buckets,
      **numeric** avg/min/max + `pausedFraction`/`chargingFraction` asserted
      (not just bucket count)
- [ ] rotation: small-cap `TelemetryLog` driven past its cap → hot file ≤ cap AND
      archive buckets cover the **dropped** samples' time range; archive's own
      ring cap enforced (small-cap test)
- [ ] merge: `hours:0` → archive-mapped + hot samples, chronological, ≤2,000 after
      server downsample (input >2,000); mapping contrast: `pausedFraction` 0.6 →
      `chargingPaused == true`, 0.4 → `false`
- [ ] wire compat: `StatsSample` JSON **without** `chargingPaused` decodes `false`;
      `GetStatePayload` JSON without `adapter` decodes `nil`; both round-trip when
      present; paused/unpaused telemetry samples map to **differing** wire samples
- [ ] `AdapterDetails` parser total: present → watts/name; absent dict → nil;
      mistyped `Watts` → nil; missing `Name` → watts-only
- [ ] time-to-limit: two different rates → two different (exact, formula-derived)
      minute values; |rate| < 50 mA → nil; already past target → nil; sailing →
      target `limit − sailingOffset`
- [ ] sessions: gap > 5 min splits; runs < 5 min dropped; classification contrast
      (charging vs paused-hold vs discharging via `amperageMA <= -50`); from/to
      percents correct on merged runs
- [ ] dashboard pure helpers tested: range→hours (24/168/720/0), paused-run →
      x-span extraction (contrast fixture), session-row + time-estimate formatting
- [ ] `scripts/make-app.sh` still produces a lint-clean, ad-hoc-signed bundle

**[HW]** gate (chunk checkpoint, human + charger, after daemon reinstall):
- [ ] dashboard voltage/amperage within 1 unit of `ioreg -rn AppleSmartBattery`
- [ ] charger row = physical adapter watts; unplug → "No charger" ≤ 10 s; replug
      → returns ≤ 10 s (this also proves live refresh without pressing Refresh)
- [ ] below-limit + plugged → finite plausible time-to-limit; at/above limit → hidden
- [ ] all four ranges render; paused shading visible over a held period; power
      chart sign flips across plug/unplug
- [ ] session list consistent with the day's telemetry
- [ ] archive rotation is **test-gated only** (live rotation ≈ 14 days out)

### Phase 6 — v3 dashboard (SPEC §10, added 2026-07-07)

Locked additions (§10.2–§10.5 binding on workers): adapter V/A specs
(`AdapterVoltage` mV + `Current` mA parsed from the same `AdapterDetails`
dict, reads only; `AdapterPayload.voltageMV/currentMA` additive default-`nil`;
labelled as **negotiated specs**, never live); capacity history
(`TelemetrySample.maxCapacityMAh: Int?`, `ArchiveSample.maxCapacityMAhAvg:
Double?` = mean of non-nil only, `StatsSample.maxCapacityMAh: Int?`, all
additive default-`nil`; 4th chart plots `maxCapacityMAh/designCapacity×100`,
nil samples skipped, y-domain 50…100); Power Flow (**one pure `powerFlow(...)`
in AmpereCore**, four directions, captioned "Battery flow" — **not** system
watts); per-app energy (**app-side only**, libproc `proc_pid_rusage`
`ri_billed_energy` with CPU-time fallback recorded in `docs/energy-findings.md`;
pure `topConsumers(...)` ranking core in AmpereCore; top-5, **in-memory only,
never persisted, never crosses the socket**). §10.0 ratifies the 2026-07-07
AlDente-style restyle as the layout baseline; every §9.6 behavior stays binding.
**Phase 6 writes zero SMC keys, reads zero new SMC keys** (§10.9).

Autonomous checks (merged tree):
- [ ] adapter parser: `AdapterVoltage`/`Current` present → values; absent →
      those fields nil (watts/name unaffected); mistyped → that field nil, no crash
- [ ] `AdapterPayload` wire compat: JSON without new fields decodes nil/nil;
      round-trips when present
- [ ] capacity fields: old JSON (field absent) decodes nil for
      `TelemetrySample`/`StatsSample`/`ArchiveSample`; round-trip when present;
      bucketing averages **non-nil only** and yields nil for an all-nil bucket
      (contrast: bucket with values vs bucket without)
- [ ] merge path: archive bucket `maxCapacityMAhAvg` 7500.4 → merged
      `StatsSample.maxCapacityMAh == 7500`
- [ ] `powerFlow`: four contrasting inputs → four **different** directions;
      exact watts asserted for a charging case and a discharging case;
      paused-plugged vs unplugged differ
- [ ] `topConsumers`: ranking order + name tie-break; top-`limit` cap; pid in
      only one snapshot dropped; `current < previous` dropped (no underflow);
      zero-delta dropped; empty input → empty
- [x] `swift build` + `bash scripts/test.sh` green; `scripts/make-app.sh` still
      produces a lint-clean, ad-hoc-signed bundle

**[HW]** gate — PASSED 2026-07-07 (human + charger; daemon reinstalled, installed
`ampered` hash == fresh build). Escaped-bug caught + fixed at this gate: see below.
- [x] Power Adapter card V/max-current match `ioreg -rn AppleSmartBattery`
      `AdapterDetails` — EXACT: 20000 mV / 2250 mA / 45 W / "pd charger"
- [x] Power Flow: plugged+charging → adapter-side, +watts; unplug → battery ≤10 s
      (45 W → 6.5 W draw); replug → adapter (41 W). Watts = battery-side magnitude.
- [x] Maximum Capacity chart renders, headline 85.8% == Battery Health card
      (after the AreaMark-baseline fix; before it, the fill spilled the frame)
- [x] Energy card: differentiated top-5 with icon fallback; `ri_billed_energy`
      CONFIRMED working on this M1 Pro (populated list ⇒ non-zero deltas), no
      CPU-time fallback needed — `docs/energy-findings.md` updated
- [x] regression: ranges (24h/7d/30d/All) render, sessions list today's runs,
      power chart sign-flips across plug/unplug

**Escaped-bug (§ oracle amendment — escaped-bug rule).** The Maximum Capacity
`AreaMark` filled to y=0 (below its 50…100 domain floor), spilling the gradient
out of the plot frame over the Sessions card. It passed T034's acceptance because
that acceptance was an *existence* check ("a Maximum Capacity chart … is present")
— the weakest, most-gameable kind, which cannot catch a rendering-containment
defect. STRENGTHENED CHECK: any chart whose y-domain floor is > 0 MUST give its
`AreaMark` an explicit `yStart` at that floor (an x/y-only AreaMark baselines at 0
and overflows). Enforced in code via the shared `capacityChartYFloor` constant +
comment; future changes to a domain-floored chart get scrutinized against this.

## Caps

In `backlog.json`: maxAttempts 3 · thrash 2 · chunk **2** tickets/invocation
(amended from 6 at user request, 2026-07-06 — session-budget conservation;
mechanical, see ledger).
