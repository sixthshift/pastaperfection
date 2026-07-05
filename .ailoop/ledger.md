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
