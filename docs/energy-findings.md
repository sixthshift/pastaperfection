# Energy findings — Apps Using Significant Energy sampler (SPEC §10.5)

Mechanism only. This file never records actual process names — that data
lives in view `@State` in-memory and nowhere else (SPEC §10.5 privacy rule).

## Mechanism

- Enumerate live pids: `proc_listallpids(nil, 0)` to size, then a second
  `proc_listallpids` call into an allocated `[pid_t]` buffer.
- Per pid: `proc_name(pid, ...)` for a display name; `proc_pid_rusage(pid,
  RUSAGE_INFO_V4, ...)` into a `rusage_info_v4` for cumulative metrics.
  Pids that error on either call are skipped (process exited, permission
  denied, etc.) — never a crash.
- Primary metric: `ri_billed_energy` (nanojoules), read once per pid per
  10 s snapshot (`EnergySampler`, app process only — not the daemon).
- Ranking: two consecutive snapshots are diffed by pid and ranked by the
  pure, unit-tested `EnergyRanking.topConsumers(previous:current:limit:)`
  in `PastaPerfectionCore` — pids present in only one snapshot dropped, a metric
  decrease (counter reset/pid reuse) dropped rather than underflowed,
  zero-delta entries dropped, sorted by delta descending (ties by name).

## Fallback rule (to be confirmed at the HW gate)

If `ri_billed_energy` deltas come back all-zero on this machine (some
Intel/older hardware doesn't populate it), switch the metric in
`EnergySampler.metric(from:)` to `info.ri_user_time + info.ri_system_time`
(CPU time, in the same struct) and note here which path this hardware
actually took. The metric selection is kept to that single function so the
swap is a one-line change.

## Status

**Confirmed on hardware 2026-07-07** (MacBookPro18,3, M1 Pro, macOS 26.3):
`ri_billed_energy` is populated and produces non-zero deltas — the dashboard's
energy card rendered a differentiated top-5 ranking (real app icons for
registered apps, gear fallback for background processes like `mdworker_shared`
/ `Firefox GPU Helper`). Since `topConsumers` drops all-zero deltas, a
populated list proves the primary metric works. The CPU-time fallback
(`ri_user_time + ri_system_time`) is therefore **not** in use on this machine
and remains available only if future hardware reports all-zero billed energy.
