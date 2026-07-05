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
