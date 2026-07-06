# Ampere — locked build spec (v1 + v2 dashboard addendum §9)

A free, self-built replacement for AlDente (free + Pro features) targeting exactly one
machine: **MacBook Pro 18,3 (M1 Pro), macOS 26.3 (Tahoe firmware), Apple Silicon.**
This spec is over-specified on purpose: every architectural decision is made here.
Workers build what §s say; they never re-litigate a locked decision.

---

## §1 Product definition

A menu bar app + root daemon that:

1. **Charge limit** — stops battery charging at a user-set limit (50–100%), with
   hysteresis (resume at limit − 5 by default).
2. **Sailing mode** — optional: instead of holding at the limit, let the battery
   drain to a lower bound (limit − configurable offset) before resuming charge.
3. **Discharge to limit** — one-shot action: electrically disable the adapter so the
   Mac runs on battery until it reaches the limit, then re-enable.
4. **Top-up** — one-shot action: charge to 100% once, then return to limit mode.
5. **Heat protection** — pause charging while battery temperature ≥ threshold
   (default 35 °C), resume at threshold − 2 °C.
6. **Stats** — battery health (AppleRawMaxCapacity vs DesignCapacity), cycle count,
   temperature, wattage in/out, charge history chart.
7. **Calibration mode** — manual or monthly: discharge to 15%, charge to 100%,
   hold 1 h, return to limit. Abortable at any moment; abort restores limit mode.

Failure philosophy (locked): **every failure path ends with charging enabled.**
Worst case at all times = the Mac charges normally like a stock Mac.

## §2 Locked stack

- Swift, SPM package, `// swift-tools-version: 6.0`, **`swiftLanguageMode(.v5)` on every
  target** (avoid strict-concurrency churn). Min platform `macOS(.v14)`.
- Test framework: **Swift Testing** (`import Testing`, built into the toolchain; amended
  from XCTest 2026-07-05 — CLT ships no XCTest, user-approved). No third-party dependencies anywhere.
- Targets:
  - `AmpereCore` (library) — SMC client, battery reader, pure control logic, socket
    protocol codec, config model. No `main`.
  - `ampered` (executable) — the root daemon.
  - `Ampere` (executable) — SwiftUI `MenuBarExtra` app.
  - `ampere-cli` (executable) — spike/debug/install CLI.
  - `AmpereCoreTests` — Swift Testing target for `AmpereCore`.
- UI: SwiftUI `MenuBarExtra` (`.menuBarExtraStyle(.window)`), Swift Charts for stats.
  The app sets `NSApp.setActivationPolicy(.accessory)` at launch.
- App bundle: `scripts/make-app.sh` assembles `dist/Ampere.app` (Contents/MacOS/Ampere,
  Info.plist with `LSUIElement=true`, bundle id `com.ampere.app`, `codesign -s -` ad-hoc).
  Launch-at-login: `SMAppService.mainApp.register()` from the bundled app.

## §3 Locked architecture

```
Ampere.app (user)  ──JSON lines over /var/run/ampere.sock──▶  ampered (root, launchd)
ampere-cli (user/sudo)  ──same socket──▶                      │ owns ALL SMC writes
                                                              │ control loop + telemetry
```

- **Only `ampered` (and `ampere-cli` in Phase 0 spike commands) ever writes SMC.**
- Daemon: launchd label `com.ampere.daemon`, plist `/Library/LaunchDaemons/com.ampere.daemon.plist`,
  binary installed at `/Library/PrivilegedHelperTools/ampered`, `RunAtLoad=true`, `KeepAlive=true`.
- Socket: `/var/run/ampere.sock`, owner `root:staff`, mode `0660` (single-user machine;
  acceptable trust boundary — locked, do not add auth).
- Config: `/Library/Application Support/Ampere/config.json` (daemon owns writes; clients
  change config only via socket commands).
- Telemetry: `/Library/Application Support/Ampere/telemetry.jsonl`, one JSON object per
  line, one sample/60 s, ring-capped at 20,000 lines (rewrite file when exceeded).
- Daemon event sources: 30 s poll timer + `IOPSNotificationCreateRunLoopSource` (power
  events) + `IORegisterForSystemPower` (sleep/wake). On wake and on any power event:
  re-evaluate immediately (firmware may silently re-enable charging).
- Signal handling (locked): SIGTERM/SIGINT → enable charging, enable adapter, exit 0.
  Any uncaught error path → same restoration before exit.

### §3.1 Socket protocol (JSON lines; one request line → one response line)

Requests / responses:
- `{"cmd":"get-state"}` → `{"ok":true,"data":{"percent":75,"isCharging":false,"externalConnected":true,"chargingPaused":true,"adapterDisabled":false,"mode":"limit","limit":80,"temperatureC":30.1,"health":{"maxCapacity":4382,"designCapacity":5088,"cycleCount":412},"calibration":null}}`
- `{"cmd":"set-limit","value":80}` → value clamped to 50–100
- `{"cmd":"set-config","config":{...partial Config...}}` → merge + persist
- `{"cmd":"get-config"}`
- `{"cmd":"action","name":"discharge-to-limit"|"top-up"|"calibrate-start"|"calibrate-abort"}`
- `{"cmd":"get-stats","hours":24}` → `{"ok":true,"data":{"samples":[...]}}`
- errors: `{"ok":false,"error":"<message>"}`

### §3.2 Config model (Codable, all fields have defaults)

```json
{ "limitPercent": 80, "sailingEnabled": false, "sailingOffset": 5,
  "heatProtectionEnabled": true, "heatThresholdC": 35.0,
  "calibrationScheduleEnabled": false, "calibrationDayOfMonth": 1,
  "mode": "limit" }
```
`mode`: `"off"` (daemon touches nothing) | `"limit"` | one-shot states are runtime,
not config: `discharging`, `topping-up`, `calibrating`.

### §3.3 Pure control core (locked shape — this is what makes the logic testable)

```swift
struct BatteryState { percent: Int; isCharging: Bool; externalConnected: Bool;
                      temperatureC: Double }
enum ChargingCommand { case allowCharging, inhibitCharging, disableAdapter, enableAdapter }
struct ControlState { /* one-shot mode, calibration phase, timestamps */ }
func decide(_ b: BatteryState, _ c: Config, _ s: ControlState, now: Date)
     -> (commands: [ChargingCommand], next: ControlState)
```
All limit/hysteresis/sailing/heat/discharge/top-up/calibration decisions live in
`decide` (pure, no IOKit). The daemon is a thin shell: read state → `decide` → apply
commands via the SMC adapter idempotently.

Decision rules (locked):
- limit mode: inhibit when `percent >= limit`; allow when `percent <= limit − 5`
  (or `limit − sailingOffset` when sailing); between bounds → keep previous.
- heat: `temperatureC >= heatThresholdC` forces inhibit (overrides everything except
  calibration's charge phase, which it also inhibits — heat always wins);
  release at `heatThresholdC − 2`.
- discharge-to-limit: disableAdapter until `percent <= limit`, then enableAdapter,
  return to limit mode. **Hard floor: never let percent go below 20 — if it does,
  enableAdapter + allowCharging + revert to limit mode.**
- **Self-induced-unplug suppression (amended 2026-07-06, user-approved):** when the
  daemon itself has the adapter asserted off (`lastCommands` contains
  `.disableAdapter`), `externalConnected == false` is the EXPECTED consequence of
  our own switch and MUST NOT trigger the unplug rules below (no discharge-cancel,
  no calibration abort — macOS cannot distinguish our adapter-off from a pulled
  cable). The 20%/15% floors are the safety net during adapter-off operation. A
  REAL unplug is re-detected whenever the adapter is (re-)enabled: after emitting
  enableAdapter, allow a settle window (10 s, tracked via an
  `adapterEnabledAt: Date?` in ControlState) before treating a persisting
  `externalConnected == false` as a genuine unplug.
- top-up: allow until `percent >= 100` (or `isCharging == false` at ≥ 99), then limit mode.
- calibration: phases `discharge(→15) → charge(→100) → hold(1 h) → done(limit mode)`;
  floor 15% in discharge phase; unplug or abort at any point → restore limit mode.
- `externalConnected == false` → emit nothing except state bookkeeping (nothing to control).

## §4 SMC interface (locked)

- Port the IOKit user-client code from `docs/reference/bclm-SMC.swift` (MIT, keep the
  license header in the ported file). Connection: `AppleSMC` service,
  `IOConnectCallStructMethod` selector 2, 80-byte `SMCParamStruct`.
- **Write allowlist — the ONLY keys any code may write** (writing any other key = drift,
  halt): `CHTE`, `CH0B`, `CH0C`, `CHIE`, `CH0I`. Values written are only the enable/disable
  bytes below. Reads are unrestricted (stats/temperature/key info).
- Charging inhibit, in fallback order (first key that exists on this firmware wins;
  probe once at startup via key-info, cache the choice):
  - `CHTE` (Tahoe): confirmed on this machine ui32/4 bytes, **little-endian**:
    `[01 00 00 00]` = charging inhibited, `[00 00 00 00]` = allowed. Big-endian
    `[00 00 00 01]` is REJECTED by firmware (smcResult 137). Cross-checked against
    OpenDente's helper. Phase 0 records final values in `docs/smc-findings.md`.
  - `CH0B` + `CH0C` (pre-Tahoe, may be dead): ui8, `0x00` allow / `0x02` inhibit, write both.
- Adapter disable (discharge): `CHIE` hex_/1 byte, **confirmed live on this machine**:
  `0x08` = adapter off (Mac runs on battery while plugged in), `0x00` = adapter on.
  Fallback `CH0I` (ui8 `0x01`/`0x00`) — absent on this firmware.
- The adapter exposes exactly: `setChargingInhibited(Bool)`, `setAdapterDisabled(Bool)`,
  `probe() -> SMCCapabilities`, plus read helpers. After every write, read back battery
  state to verify effect; log (and surface in `get-state`) if the write had no effect
  (firmware-change canary).
- Battery data source: IOKit registry `AppleSmartBattery` (`IOServiceGetMatchingService`).
  Keys: `CurrentCapacity` (percent on Apple Silicon), `IsCharging`, `ExternalConnected`,
  `Temperature` (centi-°C: divide by 100), `CycleCount`, `AppleRawMaxCapacity`,
  `DesignCapacity`, `Amperage` (mA, signed), `Voltage` (mV). Parser takes a
  `[String: Any]` dictionary (injectable for tests).

## §5 Phases & oracles

Verification is two-tier (locked):
- **Baseline gate — every ticket, autonomous, no hardware:** `swift build` exit 0 and
  `bash scripts/test.sh` (canonical `swift test` wrapper — required on this CLT-only
  machine) all green, from repo root. New behavior ships with new Swift Testing tests.
- **Hardware gates — phase oracles, human present with charger + sudo.** Run at chunk
  checkpoints, never inside worker sessions.

### Phase 0 — SMC spike (go/no-go for the project)
Deliverables: package scaffold; SMC client in `AmpereCore`; `ampere-cli` commands
`keys` (print key-info for the §4 allowlist + existence), `status` (battery state, no
root), `pause`, `resume`, `adapter on|off`.
- Hardware gate: charger attached, battery < 95%: `sudo ampere-cli pause` →
  within 15 s `pmset -g batt` contains `not charging` (or `AC attached; not charging`);
  `sudo ampere-cli resume` → charging resumes. `adapter off` → `pmset -g batt` shows
  `Battery Power` while physically plugged in; `adapter on` reverts. Findings recorded
  in `docs/smc-findings.md`. If `CHTE` fails → try `CH0B`/`CH0C` before escalating.

### Phase 1 — Core + daemon
Deliverables: battery reader; config; pure control core (§3.3) fully unit-tested;
socket codec; `ampered` daemon (event loop, SMC adapter application, socket server,
signal-restore); `ampere-cli install|uninstall|state` (install = copy binary, write
plist, `launchctl bootstrap system`; uninstall = bootout, remove files, restore charging).
- Hardware gate: `sudo ampere-cli install` → `launchctl print system/com.ampere.daemon`
  healthy; `ampere-cli state` (no sudo) returns JSON; set limit 75 with battery > 75%
  → charging inhibited ≤ 60 s; sleep 10 min plugged in → still inhibited on wake;
  `sudo ampere-cli uninstall` → no launchd entry, socket gone, charging normal.

### Phase 2 — Menu bar app
Deliverables: `Ampere` MenuBarExtra (battery % + state glyph in the bar); popover with
limit slider (50–100, steps of 5), mode toggles (sailing), buttons (Discharge to limit,
Top up), daemon-not-installed state with install instructions; `scripts/make-app.sh`;
launch-at-login toggle.
- Gate: scripted socket round-trip (`ampere-cli` sets limit 65 → `get-state` reflects 65
  and UI shows 65 on next open); `scripts/make-app.sh` produces `dist/Ampere.app` that
  launches and shows the menu bar item.

### Phase 3 — Heat protection + stats
Deliverables: heat rules already in control core — wire config UI toggle + threshold
stepper; daemon telemetry sampler; `get-stats`; Stats window (health %, cycle count,
temperature, watts = Amperage×Voltage/1e6, 24 h charts via Swift Charts).
- Gate: `set-config` heatThresholdC below current battery temp → `get-state` shows
  `chargingPaused` with reason heat ≤ 60 s; stats values within 1 unit of
  `ioreg -rn AppleSmartBattery` for cycles/capacities.

### Phase 4 — Calibration
Deliverables: calibration phases in control core (unit-tested state machine incl. abort
+ floors); daemon scheduling (monthly, `calibrationDayOfMonth`); UI (start/abort,
progress line in popover).
- Gate: `action calibrate-start` with charger attached → state shows
  `calibrating/discharge` and adapter disabled; `calibrate-abort` → limit mode restored,
  adapter enabled. (Full multi-hour cycle observed opportunistically, not gated.)

### Phase 5 — v2 dashboard
Defined entirely in §9 (locked addendum, 2026-07-06). Same two-tier verification
(baseline gate every ticket; one hardware gate at the end of the phase, §9.7).

## §6 Out of scope (tripwires — building any of these = halt)

- App Store, notarization, Developer-ID signing, sparkle/auto-update
- Intel or pre-Tahoe Macs as *targets* (fallback keys are for this machine's firmware only)
- Any SMC key write outside the §4 allowlist
- Analytics, telemetry upload, any network call in any target
- Localization, onboarding wizards, preferences panes beyond the popover + stats window
- Shortcuts/AppleScript integration, MagSafe LED control (v2 candidates)

## §7 Reference material (vendored, cite in tickets)

- `docs/reference/bclm-SMC.swift` — complete SMC IOKit client (SMCKit, MIT). Port base.
- `docs/reference/bclm-main.swift` — example read/write usage of that client.
- `docs/smc-findings.md` — **written by Phase 0**, the empirically confirmed key table
  for this machine. Later SMC-touching tickets must follow it.
- Prior art (context only, do not fetch at build time): charlie0129/batt,
  will2022/ChargeControl, AppHouseKitchen/AlDente.

## §8 Environment preconditions

- This machine only; Swift 6.3 toolchain (present), Node ≥ 18 for the scheduler (present).
- Hardware gates need: the user present, charger attached, `sudo`, battery in a
  workable range (<95% for pause tests, >75% for limit-75 test — adjust the tested
  limit value to current charge rather than waiting for the battery).
- macOS native Charge Limit (Settings → Battery) must remain **off/100%** while Ampere
  is active (two controllers fighting). Documented in README by Phase 2.

---

## §9 v2 dashboard (Phase 5 — locked addendum, 2026-07-06, user-approved)

Goal: close the gap to AlDente's dashboard. Everything in v1 stays locked; this
section only *adds*. All §6 tripwires remain in force (no network, no analytics,
no SMC writes outside the §4 allowlist — this phase writes **zero** SMC keys).

User-approved decisions (2026-07-06): months+ history via downsample-on-rotate;
one scrolling dashboard window (no tabs); auto-refresh while open (~5 s live
values, 60 s charts); include time-to-limit estimate and charge session log.

### §9.1 Feature list

1. **Live power detail row** — voltage (V, 2 dp), amperage (mA, signed), power
   (W, signed, = Amperage×Voltage/1e6), refreshed live.
2. **Charger info row** — adapter rating watts + name when a charger is attached;
   "No charger" otherwise.
3. **Richer charts** — range picker (24 h / 7 d / 30 d / All); three charts:
   battery %, temperature, power (W); shaded regions where the daemon was
   inhibiting charging (`chargingPaused`), drawn behind the line.
4. **Long history** — hot telemetry stays as-is (60 s, 20,000-line ring ≈ 14 d);
   samples that would be dropped on rotation are aggregated into an archive
   (§9.2) giving ~13 months of coarse history.
5. **Time-to-limit estimate** — one line under the tiles (§9.5).
6. **Charge session log** — newest ≤ 20 derived events (held / charged /
   discharged), list at the bottom of the dashboard (§9.5).

### §9.2 Telemetry archive (downsample-on-rotate)

- New file: `/Library/Application Support/Ampere/telemetry-archive.jsonl`,
  JSONL, owned by the daemon, same crash-tolerant read rules as telemetry
  (corrupt lines skipped).
- `ArchiveSample` (Codable, in `AmpereCore/Telemetry.swift` or sibling file):
  ```json
  { "ts": "<bucket start, 15-min aligned>", "percentAvg": 79.5, "percentMin": 78,
    "percentMax": 81, "temperatureCAvg": 30.9, "amperageMAAvg": -412,
    "voltageMVAvg": 12630, "chargingFraction": 0.0, "pausedFraction": 1.0,
    "count": 15 }
  ```
- Rotation hook (locked): when `TelemetryLog.append` performs its ring rewrite,
  the lines it drops are first bucketed into 15-minute buckets (bucket key =
  `floor(ts / 900 s)`) and appended to the archive. No separate scheduler; the
  archive only grows when the hot ring rotates. Bucketing is a pure, unit-tested
  function `[TelemetrySample] -> [ArchiveSample]`.
- Archive cap: 40,000 lines (≈ 416 days at 15-min buckets), same
  rewrite-when-exceeded ring mechanism, dropping oldest.
- Migration: none needed — archive starts empty and fills as the hot ring rotates.

### §9.3 Protocol deltas (amend §3.1; all additive + default-decoding, so a new
app against an old daemon and vice versa must not crash)

- `StatsSample` (wire) gains `chargingPaused: Bool` — encoded always, decoded
  with default `false` (same hand-rolled `init(from:)` pattern already used for
  `amperageMA`/`voltageMV`). Daemon copies it from the telemetry sample. This is
  what feeds paused-region shading.
- `get-stats`: `hours` keeps its meaning; **`"hours":0` now means "all history"**.
  The daemon answers by merging: archive buckets older than the oldest hot
  sample, mapped into `StatsSample` (`percent = round(percentAvg)`,
  `isCharging = chargingFraction >= 0.5`, `chargingPaused = pausedFraction >= 0.5`,
  averages copied), followed by hot samples. Merged result is downsampled
  server-side to ≤ 2,000 samples (`StatsFormatting.downsample`) before encoding —
  the response must stay one JSON line of sane size.
- `GetStatePayload` gains `adapter: AdapterPayload?` — `nil` when
  `externalConnected == false` or details unavailable:
  ```json
  "adapter": { "watts": 96, "name": "96W USB-C Power Adapter" }
  ```
  `name` optional (`String?`); omit rather than invent when absent.

### §9.4 Adapter details reader (amend §4 — reads only, no new writes)

- Source: the same `AppleSmartBattery` registry dictionary already read by
  `BatteryReader` — sub-dictionary key `AdapterDetails` (`[String: Any]`), fields
  `Watts` (Int) and `Name`/`Description` (String, either may be absent). Parser is
  pure and total over an injected `[String: Any]` like the rest of
  `BatteryReader`; absent/mistyped → `nil` adapter, never a crash.
- Do **not** shell out to `ioreg` and do not add `IOPSCopyExternalPowerAdapterDetails`
  unless `AdapterDetails` proves absent on this machine (record the finding in
  `docs/smc-findings.md` if so).

### §9.5 Pure derived logic (in `AmpereCore`, fully unit-tested, no IOKit)

**Time-to-limit** — `func timeEstimate(samples: [StatsSample], state: GetStatePayload) -> TimeEstimate?`
- Rate = mean `amperageMA` of the newest ≤ 10 samples no older than 15 min.
- If |rate| < 50 mA → `nil` (UI shows nothing/"—").
- Charging (rate > 0): target = `limit` (or 100 when mode is topping-up or
  calibrating-charge); minutes = `(target − percent)/100 × maxCapacity / rate × 60`.
- Discharging (rate < 0): target = resume bound (`limit − 5`, or
  `limit − sailingOffset` when sailing; 20 during discharge-to-limit; 15 during
  calibration-discharge); same formula with |rate|.
- Already past target → `nil`. UI line: e.g. `≈ 1 h 40 m to 80%`.

**Session log** — `func sessions(from samples: [StatsSample]) -> [ChargeSession]`
- Classify each sample: `charging` if `isCharging`; `holding` if
  `chargingPaused && !isCharging`; `discharging` if `amperageMA <= -50` and not
  paused-holding; else `idle`.
- Merge consecutive same-class runs. A gap > 5 min between samples (sleep,
  daemon down) closes the current run. Drop runs shorter than 5 min.
- `ChargeSession { kind, start, end, fromPercent, toPercent }`; UI renders the
  newest ≤ 20, newest first, e.g. "Held at 80% — 3 h 12 m",
  "Charged 62% → 80% — 48 m", "Discharged 100% → 80% — 1 h 05 m".

### §9.6 Dashboard UI (rework `StatsView`; window stays the one
`StatsWindowPresenter` window)

- Single **scrolling** layout, default size 480×640, min 440×480: header tiles
  (Health, Cycles, Temp, Power — unchanged semantics) → live detail rows
  (voltage/amperage; charger; time-to-limit) → range picker (segmented:
  24 h / 7 d / 30 d / All → `hours` 24 / 168 / 720 / 0) → three charts
  (battery % with y-domain 0…100, temperature, power W) → session list.
- Paused shading: contiguous `chargingPaused == true` runs become
  `RectangleMark` x-spans behind the `LineMark`, low-opacity accent fill, on the
  battery % and power charts.
- Client downsampling: ≤ 400 points per chart after range selection.
- Live refresh (locked mechanism): two `Timer`s owned by the view — 5 s tick
  re-fetches `get-state` (tiles, detail rows, time-to-limit), 60 s tick
  re-fetches `get-stats` for the selected range (charts, sessions). Each tick
  no-ops unless the hosting window `isVisible` — no timer teardown races with
  the retained-window presenter. Range change triggers an immediate re-fetch.
- Manual Refresh button stays (forces both fetches).

### §9.7 Phase 5 oracle

- **Baseline gate (every ticket):** `swift build` + `bash scripts/test.sh` green.
  New unit tests required for: bucketing, archive ring-cap, merge mapping +
  server downsample, `StatsSample.chargingPaused` default decoding,
  `AdapterPayload` parsing (present/absent/mistyped), time-to-limit (charging,
  discharging, below-threshold, past-target), session segmentation (merge, gap
  split, short-run drop).
- **Hardware gate (human, charger attached, after `sudo ampere-cli install`
  upgrade of the daemon):**
  1. Dashboard voltage/amperage within 1 unit of `ioreg -rn AppleSmartBattery`
     `Voltage`/`Amperage` read at the same time.
  2. Charger row shows the physical adapter's rating watts; unplug → row shows
     "No charger" ≤ 10 s; replug → row returns ≤ 10 s.
  3. Battery-below-limit + plugged: time-to-limit shows a finite, plausible
     estimate; at/above limit: the line disappears.
  4. Range picker switches all four ranges without error; paused shading visible
     over a period the daemon held at the limit; power chart shows sign flips
     across a plug/unplug.
  5. Session list shows today's hold/charge/discharge events consistent with the
     day's telemetry.
  6. Archive rotation is **test-gated only** (live rotation takes ~14 days):
     unit test drives a small-cap `TelemetryLog` through rotation and asserts
     archive contents; live archive observed opportunistically, not gated.
- Live values updating without pressing Refresh (watch the Power tile change
  within ~10 s of plugging/unplugging) is part of gate step 2.

### §9.8 Suggested ticket decomposition (non-binding; intake may re-cut)

1. T-V2-A: wire `chargingPaused` into `StatsSample` + `AdapterDetails` parser +
   `adapter` in `get-state` (protocol + reader + daemon, tests).
2. T-V2-B: archive — `ArchiveSample`, bucketing, rotation hook, archive ring,
   `get-stats hours:0` merge + server downsample (tests).
3. T-V2-C: pure logic — time-to-limit + session segmentation (tests).
4. T-V2-D: dashboard UI — layout, live refresh, range picker, three charts +
   shading, charger/detail rows, session list.

### §9.9 v2 out of scope (additional tripwires)

- CSV/JSON export, printing, iCloud/anything sync
- Per-app energy attribution, process lists
- Editing/deleting history from the UI
- Charts beyond the three listed; annotations/zoom/pan gestures
- Menu-bar-icon sparkline or extra menu bar items
