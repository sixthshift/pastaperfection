# Ledger — ampere

Append-only journal. Newest entry at the bottom. Never rewrite history.

## Run header
- **spec:** SPEC.md @ repo root (initial commit)
- **started:** 2026-07-05
- **caps:** max 3 attempts/ticket · thrash=2 · chunk=6/invocation
- **models:** builders=sonnet · verify/gates/coordinator=session model (Fable 5)

## Journal

[0001] intake — seeded backlog (19 tickets, T001–T019, phases 0–4), oracle derived
       from SPEC.md, schedule.mjs copied from skill templates
  decision: proceed
  why: every phase oracle is executable; hardware ([HW]) checks are explicitly
       human-present and run at chunk checkpoints, never inside worker sessions
  evidence: SPEC.md §5 two-tier oracle; toolchain detected: swift 6.3.3
       (arm64-apple-macosx26.0), node v26.4.0; git repo initialized

[0002] intake — red-team pass over seeded acceptances; 7 sharpenings applied
  decision: proceed
  why: acceptance checks must not be satisfiable by a lazy builder
  findings applied to backlog:
    1. T007 `status` could hardcode plausible JSON → verifier cross-checks
       percent against live `pmset -g batt` ±1 (live contrast, unfakeable).
    2. T002 struct-size test alone is gameable (any 80-byte struct) → added
       field-level construction assertions; ultimate check is the Phase 0 [HW]
       gate, which cannot be gamed.
    3. T006 hysteresis could pass with inverted comparisons under vague tests →
       acceptance enumerates the exact SPEC §3.3 contrast table (79/80/78/75).
    4. T009 could fake sockets in memory → acceptance requires binding a REAL
       unix socket in a temp dir + post-malformed-line usability check.
    5. UI tickets (T012/T016/T019) have no autonomous behavioral oracle (SwiftUI)
       → explicit verifier diff-review contracts + launch-without-crash check;
       weakest oracles by design, compensated by Phase 2–4 [HW] gates.
    6. T014 ring cap could truncate the wrong end → acceptance asserts the
       OLDEST lines are dropped, newest survive.
    7. T017 could weaken T006 tests to pass → acceptance requires all
       pre-existing T006 tests pass UNMODIFIED.

[0003] intake — environment preconditions probed
  decision: proceed with noted constraint
  why: SPEC §8 — hardware gates need user + charger + sudo; machine currently on
       battery power. Worker tickets are baseline-only; Phase 0 [HW] gate will be
       requested from the user at the first checkpoint with charger attached.
  evidence: pmset reports 'Battery Power' at intake; swift build toolchain OK

[0004] run — oracle amendment (semantic, USER-APPROVED): test framework XCTest →
       Swift Testing
  decision: amend-oracle
  why: CLT-only machine ships no XCTest.framework for macOS; full Xcode (~15 GB)
       rejected by user. Behavioral checks unchanged; only test syntax changes.
  evidence: T001 worker escalation (import XCTest -> no such module); user chose
       "Swift Testing" via explicit question. SPEC §2, oracle.md, backlog
       acceptances updated.

[0005] run — oracle amendment (mechanical): baseline test command = `bash scripts/test.sh`
  decision: amend-oracle
  why: plain `swift test` cannot locate Testing.framework/macro plugin/
       lib_TestingInterop.dylib under CLT; wrapper supplies -F, -plugin-path,
       and two rpaths. Check meaning unchanged ("full suite passes").
  evidence: swift test → "no such module 'Testing'"; wrapper → "Test run with
       1 test in 1 suite passed". Flags recorded in scripts/test.sh.

[0006] T001 — done (attempt 1; blocked-escalation resolved by amendment 0004)
  decision: continue
  why: independent re-verify green after coordinator applied amendment to
       ScaffoldTests.swift (mechanical application of 0004, not a build patch —
       worker's code untouched otherwise). Scope check clean: only contracted
       files in diff. Gaming read: trivial scaffold, nothing to game.
  attempt: 1/3
  evidence: swift build exit 0; scripts/test.sh 1/1 passed; targets =
       Ampere, AmpereCore, AmpereCoreTests, ampere-cli, ampered;
       ampere-cli prints "ampere-cli 0.0.1"

[0007] T004 — done (attempt 1)
  decision: continue
  why: independent re-verify green on worker worktree; scope exact; diff
       faithful to SPEC §3.2 (no gaming: tests assert the acceptance table,
       impl uses per-field decodeIfPresent, atomic save)
  attempt: 1/3
  evidence: build exit 0; 6/6 tests; merged --no-ff to main

[0008] T003 — done (attempt 1)
  decision: continue
  why: independent re-verify green on worker worktree; scope exact; diff
       faithful to SPEC §3.3/§4 (contrast fixtures assert B differs from A
       in exactly the intended fields — not gameable by hardcoding)
  attempt: 1/3
  evidence: build exit 0; 5/5 tests; merged --no-ff to main

[0009] T002 — done (attempt 1)
  decision: continue
  why: independent re-verify green; scope exact; gaming read on the
       safety-critical port: selector bytes, struct layout, and read/write
       param construction all match docs/reference/bclm-SMC.swift; tests
       contrast read vs write selectors (not gameable by stub structs)
  attempt: 1/3
  evidence: build exit 0; 10/10 tests; MIT header line 17; merged --no-ff

[0010] T007 — done (attempt 1)
  decision: continue
  why: re-verify green incl. LIVE contrast checks (status matches pmset 85==85;
       root guards fire; keys probe live). Gaming read on write paths: all
       writeData call sites target SPEC §4 allowlist keys only, root guard
       precedes any SMC open. Firmware finding: CHTE ui32/4 + CHIE hex_/1
       present; CH0B/CH0C/CH0I absent (Tahoe layout confirmed pre-gate).
  attempt: 1/3
  evidence: merged gate 39/39; CLI smoke on merged tree green

[0011] T005 — done (attempt 1)
  decision: continue
  why: re-verify green; scope exact; 20 new contrast tests (set-limit 65 vs 80,
       heat vs limit pauseReason strings) — codec not gameable by stubs
  attempt: 1/3
  evidence: 39/39 on worktree and merged tree

[0012] run — chunk 1 boundary: 6 tickets closed (T001–T005, T007), cap reached
  decision: end-chunk
  why: caps.chunk = 6; ending healthy. Phase 0 code complete; [HW] gate is the
       only open Phase 0 item — charger now attached per user, gate commands
       handed to human (sudo required, cannot run inside coordinator session).
  evidence: merged tree: build exit 0, 39 tests/5 suites green; scheduler next
       ready = T006 (control core), then T008+ after

[0013] phase-0 — hardware gate PARTIAL RED; repair ticket T020 spawned
  decision: decompose (repair) + amend-oracle (mechanical: SPEC §4 encoding detail)
  why: [HW] adapter checks GREEN (CHIE 0x08/0x00 confirmed live: Battery Power
       while plugged in, reversible). [HW] pause check RED: CHTE rejected
       big-endian [00 00 00 01], smcResult 137; [00 00 00 00] accepted. Root
       cause: T007 encoded probed-size big-endian; OpenDente (cross-referenced
       source) writes little-endian [01 00 00 00]. Escaped-bug rule applied:
       T020 fixes encoding AND adds --dry-run byte assertion so encoding is
       checkable without sudo from now on.
  evidence: user-run gate transcript (pmset flips for CHIE both ways; CHTE
       error 137); OpenDente HelperDelegate.swift:262-263 writes [01 00 00 00];
       docs/smc-findings.md created with confirmed table

[0014] T020 — done (attempt 1, repair)
  decision: continue
  why: re-verify green; dry-run assertion prints derive from the same
       chteBytes()/adapter byte helpers as the real writes — the strengthened
       check is structurally tied to behavior. Root guard unchanged.
  attempt: 1/3
  evidence: dry-runs CHTE [01 00 00 00] / [00 00 00 00], CHIE [08]/[00];
       39/39 on worktree and merged tree

[0015] phase-0 — CLOSE: all oracle checks green (gate re-run after T020)
  decision: close-phase
  why: every Phase 0 check in oracle.md now passed on the merged tree:
       baseline 39/39; status==pmset ±1 (85==85, verified live); keys probe
       lists allowlist with live key-info; root guards exit 1; [HW] pause →
       "95%; AC attached; not charging" with CHTE readback [01 00 00 00];
       [HW] resume restores (readback [00 00 00 00], exit 0; charging
       confirmed resumed in earlier run); [HW] adapter off/on → Battery
       Power/AC Power flips both ways; docs/smc-findings.md records the
       confirmed key table. GO decision for the project.
  evidence: user-run gate transcripts (2026-07-05); docs/smc-findings.md

[0016] run — interruption: session limit hit mid-dispatch; T006/T009 workers
       terminated before producing results
  decision: retry (not counted as attempts — no build output, no diagnosis to log)
  why: workers died to an API limit, not a build failure; worktrees auto-cleaned,
       tickets still todo. Re-dispatching identical briefs on resume.

[0017] T009 — done (attempt 1)
  decision: continue
  why: re-verify green twice (socket flake check); scope exact; gaming read
       clean — tests bind real sockets, malformed-then-valid contrast on the
       same connection, permissions asserted against requested mode
  attempt: 1/3
  evidence: 46/46 on worktree x2 and merged tree; merged --no-ff

[0018] T006 — done (attempt 1)
  decision: continue
  why: re-verify green; scope exact; gaming read on the safety-critical
       decision table: all SPEC §3.3 rules implemented literally, heat
       override early-returns above one-shots, floor 20 aborts discharge with
       full restore. Tests enumerate the spec contrast table — not gameable.
  attempt: 1/3
  evidence: 58/58 on worktree and merged tree; merged --no-ff

[0019] T011 — done (attempt 1)
  decision: continue
  why: re-verify green incl. live launch-alive check with socket absent;
       scope exact; glyph distinctness asserted as a Set (not gameable by
       duplicate symbols)
  attempt: 1/3
  evidence: 72/72 worktree + merged tree; alive after 3 s, SIGTERM clean

[0020] T017 — done (attempt 1)
  decision: continue
  why: re-verify green; append-only test rule held (escaped-bug guard from
       red-team finding 7); calibration transitions driven by now: Date only;
       merged cleanly over T011 (disjoint files), combined gate green
  attempt: 1/3
  evidence: 73/73 worktree; 80/80 merged tree

[0021] T008 — done (attempt 1)
  decision: continue
  why: re-verify green; safety audit passed (allowlist key literals only,
       byte values match hardware findings, signal-restore present, non-root
       refusal); 17 new fake-transport tests incl. byte-exactness contrasts,
       fallback, idempotence, verify-after-write canary
  attempt: 1/3
  evidence: 82/82 worktree; 97/97 merged tree

[0022] run — chunk 2 boundary: 6 tickets closed (T020, T009, T006, T011, T017,
       T008); cap reached
  decision: end-chunk
  why: caps.chunk = 6; ending healthy. Phase 0 closed this run (gate green
       after T020 repair). Core engine complete: control logic, SMC adapter,
       daemon loop, socket layer, app shell, calibration machine all merged.
  evidence: merged tree 97 tests/8 suites green; scheduler next: T010
       (install/uninstall + socket wiring) unblocks the Phase 1 [HW] gate

[0023] T012 — ticket enrichment before dispatch (chunk 3 start)
  decision: continue
  why: T012's acceptance requires all mutations to route through
       DaemonClientModel, but T011 built the model read-only; the model file
       must be in T012's contract to add send methods. Files contract
       extended by one file; still disjoint from T010/T013.

[0024] chunk 3 — dispatch note: T012 and T013 intentionally overlap on
       MenuBarView.swift (T013 needs to wire InstallPromptView + login toggle)
  decision: continue (deviation from strict disjointness, acknowledged)
  why: both edits are small and target different branches of the view
       hierarchy; merge order T012 -> T013; if the textual conflict is
       non-trivial at merge, per SKILL.md the conflicting ticket is
       re-dispatched serially instead of hand-merging semantics.

[0025] T010 — done (attempt 1)
  decision: continue
  why: re-verify green; daemon now serves the full SPEC §3.1 protocol; install/
       uninstall dry-runs match SPEC §3 paths exactly
  evidence: 100/100; dry-run transcripts in backlog evidence

[0026] T012 — done (attempt 1)
  decision: continue
  why: re-verify green; verifier contract greps all pass (no SocketClient in
       views, release-send slider, live-temp heat row)
  evidence: 97/97 worktree, 100/100 merged

[0027] T013 — done (attempt 1); MenuBarView conflict resolved as trivial
  decision: continue
  why: conflict was the anticipated placeholder-vs-ControlsView overlap; both
       features kept (ControlsView + login toggle + InstallPromptView), no
       semantic judgment required; merged-tree gate green incl. bundle build
  evidence: 100/100; plutil+codesign OK; app alive daemon-absent

[0028] T016 — done (attempt 1)
  decision: continue
  why: re-verify green; single-file scope; follows established binding pattern
  evidence: 100/100 worktree + merged

[0029] T014 — done (attempt 1)
  decision: continue
  why: re-verify green; oldest-dropped assertion present (red-team finding 6
       guard held); injectable cap for testability without 20k-line fixtures
  evidence: 104/104 worktree + merged

[0030] T018 — done (attempt 1)
  decision: continue
  why: re-verify green; worker correctly identified pre-existing action
       handlers (T010 overlap) and added only the missing scheduler/sidecar/
       shutdown pieces — no duplication; all guards grep-verified
  evidence: 104/104 worktree + merged

[0031] T015 — done (attempt 1); spec-gap repair T021 spawned
  decision: continue + decompose (repair)
  why: re-verify green; worker correctly refused to touch out-of-contract
       Protocol.swift and degraded wattage to N/A instead of fabricating.
       SPEC §1.6 lists wattage as a product feature -> T021 closes the gap
       end-to-end (protocol fields + daemon projection + tile).
  evidence: 113/113 worktree + merged; StatsView.swift:85 documented N/A

[0032] run — chunk 3 boundary: 7 tickets closed (T010, T012, T013, T016,
       T014, T018, T015) — one over cap (final batch dispatched at 5 closed)
  decision: end-chunk
  why: batch [T015, T018] was dispatched while under cap and judged to
       completion rather than abandoned in-flight (per SKILL.md: never
       abandon in-flight work). Chunk 4 = T019 + T021, the final two.
  evidence: merged tree 113 tests/12 suites green

[0033] T019 — done (attempt 1)
  decision: continue
  evidence: 113/113 worktree; contract greps pass

[0034] T021 — done (attempt 1, repair)
  decision: continue
  why: SPEC §1.6 wattage gap closed end-to-end; backward-compatible decode
  evidence: 114/114 worktree + merged

[0035] run — BACKLOG DRAINED: 21/21 tickets done, all baseline + autonomous
       phase checks green on the merged tree
  decision: final-report
  why: every ticket independently re-verified; remaining oracle items are the
       [HW] human-present checks for Phases 1-4 (install/limit/sleep, socket
       round-trip via UI, heat trigger, calibrate start/abort), which require
       the user at the machine with charger + sudo.
  evidence: 114 tests/12 suites; dist/Ampere.app builds + codesigns; app
       alive daemon-absent; pause --dry-run prints CHTE [01 00 00 00];
       cli status matches live battery (100%, unplugged)

[0036] run — oracle tooling: scripts/hw-gate.sh added (coordinator-authored)
  decision: continue (mechanical — automates the existing [HW] checks verbatim,
       changes nothing about what counts as done)
  why: the remaining oracle items are human-present; a single self-reporting
       harness beats hand-copied command blocks and is re-runnable after
       future macOS updates (firmware-canary drills).
  evidence: bash -n clean; release build + signed bundle rebuilt at drain

[0037] phase-1 — [HW] gate RED at socket-state check; repair T022 spawned
  decision: decompose (repair)
  why: errno 13 EACCES — daemon socket root:wheel 0660, unprivileged staff
       user cannot connect; SPEC §3 locks root:staff. Root cause: coordinator
       ticket text told T009/T010 builders "ownership happens naturally" — a
       wrong assumption that no autonomous check could catch (needs root).
       Escaped-bug rule: hw-gate.sh IS the strengthened check (it caught it);
       repair also fixes the misleading ENOENT-vs-EACCES client error.
  evidence: user gate transcript (errno 13); connect() perms require write
       on socket inode; natural root group on macOS is wheel

[0038] run — gate rerun red as expected (T022 not yet merged); two gate-script
       defects found and fixed
  decision: amend-oracle (mechanical — tooling only, checks' meaning unchanged)
  why: (1) ioreg CycleCount grep matched a nested one-line dictionary ->
       garbage; now anchored to the top-level line (verified locally: prints
       one number). (2) limit check ambiguous at 100% ("charged" masks
       inhibit); now uses daemon get-state chargingPaused as the
       authoritative signal with pmset secondary. Added socket preflight so
       a perms failure fails fast instead of cascading.
  evidence: user gate transcript 2026-07-06; bash -n clean

[0039] T022 — done (attempt 1, repair)
  decision: continue
  why: re-verify green; the live EACCES reproduction on this machine's
       still-buggy socket doubles as a behavioral test of the new error
       path; chown is root-only so unprivileged loopback tests unaffected.
       Awaiting user gate re-run for the end-to-end confirmation.
  attempt: 1/3
  evidence: 114/114; live 'permission denied … socket group mismatch' exit 1

[0040] phase-1 — [HW] gate RED (severe): daemon permanent main-queue deadlock
  decision: decompose (repairs T023 core + T024 tooling)
  why: telemetry heartbeat (60 s, main queue) ran 09:12→13:00:50 then stopped
       forever, coinciding exactly with the first client to disconnect
       mid-request (nc -w 1). All socket requests hang in
       DispatchQueue.main.sync; control loop AND SIGTERM restore path share
       the dead main queue — safety rail broken (charging stayed inhibited
       with no live restore path). Contributing defects: CFRunLoopRun+main.sync
       bridging, blocking accept() parking the server queue (missing
       O_NONBLOCK), no SIGPIPE guard, and nc-based gate tooling that
       disconnects mid-request (trigger) or hangs (persistent connections).
       Escaped-bug rule: T023 acceptance encodes the exact trigger
       (disconnect-without-reading then next client must get a response) as a
       permanent regression test.
  evidence: telemetry.jsonl last ts 2026-07-06T03:00:50Z vs date 13:22 AEST;
       state requests hang; runs=1 pid stable (no crash); user's 11:58
       config.json mtime proves requests served before the trigger

[0041] T024 — done (attempt 1, tooling repair)
  decision: continue
  why: re-verify green; gate no longer depends on nc semantics; req exits
       promptly on ENOENT. Minor doc gap noted: usage text (SpikeCommands.swift)
       was outside contract and already omits install/state — fold into any
       future tidy, not worth a ticket.
  evidence: 114/114; grep nc count 0

[0042] T023 — done (attempt 1, critical repair)
  decision: continue
  why: re-verify green twice; all grep contracts pass; the exact live trigger
       is now a permanent regression test; worker's minimal repro crashed
       ~70-100% pre-fix and 0/40+ post-fix (SIGPIPE + fd-reuse both fixed).
       Append-only deviation (@Suite -> @Suite(.serialized)) reviewed and
       judged benign: harness attribute, zero test-body changes.
  attempt: 1/3
  evidence: 116/116 x2 on worktree and merged tree; release + bundle rebuilt

[0043] phase-4 — [HW] gate red root-caused: SPEC design flaw (self-induced
       unplug); SEMANTIC oracle amendment USER-APPROVED; T025 spawned
  decision: amend-oracle (semantic, escalated per SKILL.md — user chose
       "suppress while adapter-off") + decompose (repair T025)
  why: coordinator diagnostics (temporary DiagT025 test, deleted after use)
       proved decide()/protocol/payload all correct in isolation; live
       sequence: calibrate-start -> discharge -> disableAdapter -> macOS
       reports externalConnected=false -> IOPS re-evaluate -> pre-amendment
       unplug rule aborts calibration <1s. Same flaw self-cancels the
       discharge-to-limit one-shot (gate previously had no discharge check —
       added in T025). Secondary: get-state omits "calibration" key when nil
       vs SPEC §3.1 explicit null (broke the abort check's grep).
  evidence: raw get-state transcripts pre/post calibrate-start (ok:true, no
       calibration key, adapterDisabled false, mode limit 2s later); DiagT025
       output (decide preserves calibration; decode -> calibrateStart;
       payload encodes object when present); SPEC §3.3 amended in place

[0044] T025 — done (attempt 1, semantic-amendment repair)
  decision: continue
  why: re-verify green twice; test modifications audited — exactly the 3
       amendment-contradicting tests changed, each with its genuine-unplug
       counterpart preserved unmodified (no coverage lost, no weakening);
       settle-window boundary tested both sides (5s/15s).
  attempt: 1/3
  evidence: 121/121 x2; grep-verified suppression + encodeNil + gate section

[0045] run — PHASES 1–4 CLOSED: full hardware gate green (user-run, 2026-07-06)
  decision: close-phase (1, 2, 3, 4) → final report
  why: every scripted [HW] check in oracle.md passed on the live machine:
       install/launchd/socket (root:staff, staff client OK); limit 80
       enforced <60 s ("not charging" on AC); set-limit round-trip;
       discharge-to-limit ran WITHOUT self-cancel (amended SPEC §3.3 rule
       verified live: adapter off → "Battery Power" → completion → AC
       restored); heat pause with pauseReason==heat; cycle count matches
       ioreg (238); calibration start reported
       {"phase":"discharge",...} and abort restored limit mode.
       "calibration":null explicit encoding confirmed in state output.
  evidence: user gate transcript "ALL SCRIPTED [HW] CHECKS PASSED";
       outstanding: passive 10-min sleep check (oracle Phase 1, user-run at
       leisure — daemon left installed at limit 80)

[0046] post-gate — live dashboard red: get-stats connection closed; T026 spawned
  decision: decompose (repair)
  why: telemetry healthy on disk (fresh 60 s samples) but get-stats (~60KB
       response) is dropped mid-write: accepted fds inherit the listen fd's
       O_NONBLOCK on macOS/BSD; writeAll treats EAGAIN as fatal once the
       socket buffer fills. Small responses (get-state) fit the buffer —
       which is why every prior gate check passed. Escaped from T023 (its
       loopback tests used small payloads); T026 encodes a >200KB response
       as a permanent regression test. Daemon does NOT crash (pid stable);
       failure is per-connection and fails safe.
  evidence: req get-stats -> "connection closed by server", pid unchanged
       before/after; writeAll source (EINTR-only handling); fcntl O_NONBLOCK
       on listen fd at SocketServer.swift:152

[0047] T026 — done (attempt 1, repair)
  decision: continue
  why: re-verify green; builder performed a true red/green check reproducing
       the live failure before fixing; regression test is size-anchored
       (250KB + trailing marker) so buffer-boundary regressions cannot hide.
  attempt: 1/3
  evidence: 122/122; append-only verified; fix at SocketServer.swift:222

[0048] post-project — coordinator patch: Quit button in popover (spec omission:
       LSUIElement app had no quit path at all)
  decision: continue (loop closed; trivial UI addition applied directly,
       baseline re-run green, bundle rebuilt)
  evidence: 122/122; NSApp.terminate button + ⌘Q shortcut; comment documents
       that quitting the app leaves the daemon enforcing

[0049] Phase 5 intake — SPEC §9 v2 dashboard (user-approved addendum 2026-07-06)
  decision: extend backlog T027–T030; oracle.md gains Phase 5 section
  why: v1 shipped 26/26; user requested v2 dashboard per SPEC §9 (locked:
       archive downsample-on-rotate, additive protocol deltas, AdapterDetails
       read, pure derived logic, single scrolling dashboard, §9.9 tripwires).
       Dependency spine: T027 → {T028, T029} → T030. Phase writes ZERO SMC keys.
  caps: chunk amended 6 → 2 at user request (session-budget conservation).
       Mechanical amendment: changes run pacing, not what counts as done.
       maxAttempts 3 / thrash 2 unchanged.

[0050] Phase 5 red-team (coordinator pass, pre-dispatch)
  decision: acceptances sharpened before any build spend
  findings baked into tickets/oracle:
  - T027: hardcoded chargingPaused would pass a single-fixture test → require
    contrast pair (paused vs unpaused → differing wire samples). Daemon-bypass
    risk (mapping added to AmpereCore but Daemon keeps a hand-rolled copy) →
    ticket says duplicate mapping = fail; gaming read checks the call site.
  - T028: bucket-count-only tests are gameable → NUMERIC avg/fraction
    assertions required; rotation test must prove archive covers the DROPPED
    samples' time range, not merely "archive non-empty".
  - T029: "returns non-nil" is gameable → two rates must yield two EXACT
    formula-derived minute values; rate-window exclusion proven by fixture.
  - T030: UI existence checks are unverifiable autonomously → all judgeable
    logic forced into pure StatsFormatting/StatsDerived helpers with contrast
    tests; visual checks live ONLY in the phase [HW] gate. make-app.sh output
    lint+codesign checked mechanically.

[0051] T027 — done (attempt 1)
  decision: continue
  why: re-verify green on worktree AND merged tree (133/133, was 122); scope
       diff = exactly the 5 contracted files; gaming read clean — genuine
       contrast test (paused vs unpaused telemetry → wire samples differ only
       in chargingPaused, all other fields asserted equal); daemon call site
       uses the AmpereCore mapping (.map(StatsSample.init)), duplicate removed.
       Accepted deviation, builder-flagged honestly: BatteryReading is frozen,
       so adapter details ship as BatteryReader.parseAdapter/readLiveAdapter +
       injectable Daemon.AdapterReader closure — additive, in contract files.
  attempt: 1/3
  evidence: on ticket; merged at main

[0052] T028 — done (attempt 1)
  decision: continue
  why: re-verify green on worktree AND merged tree (144/144, was 133); scope
       exact; gaming read clean. Red-team requirements held up: bucket test
       asserts NUMERIC aggregates (1/3 pausedFraction ±0.001), rotation test
       spaces samples 1000 s apart so each archive bucket is attributable to
       a specific dropped line (not merely "archive non-empty"). Notable good
       call by builder: get-stats "hours":0=all implemented via new readAll()
       instead of changing read(hoursBack:0)'s pre-existing empty-window
       contract — existing call sites untouched and documented.
  attempt: 1/3
  evidence: on ticket; merged at main

[0053] chunk boundary — cap 2 reached (T027, T028 closed)
  decision: end chunk healthy
  state: 28/30 done. Scheduler next: T029 (pure derived logic — StatsDerived
       time-to-limit + sessions) ready now; T030 (dashboard UI) blocked on
       T029 only. Phase 5 [HW] gate runs at the checkpoint AFTER T030 merges
       (needs human + charger + daemon reinstall). No escalations, no gaming,
       no decompositions this chunk; both tickets first-attempt green.

[0054] T029 — done (attempt 1)
  decision: continue
  why: re-verify green on worktree AND merged tree (163/163, was 144); scope
       exact (2 new files only); gaming read clean — formula asserted exactly
       (62 vs 31 min contrast), 15-min rate-window exclusion proven by
       fixture, all four target-selection branches and the classification
       precedence covered. Third consecutive first-attempt ticket.
  attempt: 1/3
  evidence: on ticket; merged at main

[0055] T030 — done (attempt 1)
  decision: continue
  why: re-verify green on worktree AND merged tree (176/176, was 163); scope
       exact; §9.9 tripwire scan negative; live-refresh no-ops on
       window.isVisible (locked mechanism, no onDisappear reliance);
       autonomous phase-oracle items re-run on merged tree: tests + make-app
       + plutil + codesign all green. Fourth consecutive first-attempt ticket.
  attempt: 1/3
  evidence: on ticket; merged at main

[0056] chunk boundary + backlog drained — Phase 5 autonomous oracle GREEN
  decision: end chunk; phase NOT closed yet
  state: 30/30 done. All autonomous Phase 5 checks pass on the merged tree.
       Phase 5 closes only after the [HW] gate (oracle.md Phase 5): human +
       charger + daemon reinstall (new protocol fields need the new ampered:
       sudo ampere-cli uninstall && sudo ampere-cli install, or equivalent),
       then: voltage/amperage vs ioreg ±1; charger row watts + unplug/replug
       ≤10 s (also proves live refresh); time-to-limit finite below limit,
       hidden at limit; four ranges render; paused shading over a held
       period; power sign flips across plug/unplug; session list consistent
       with the day. Archive rotation stays test-gated (live rotation ≈14 d).
