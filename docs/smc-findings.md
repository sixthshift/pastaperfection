# SMC findings — MacBookPro18,3 (M1 Pro), macOS 26.3 Tahoe firmware

Empirical results from the Phase 0 hardware gate (2026-07-05, sudo, charger attached).
Later SMC-touching tickets MUST follow this table (SPEC §7).

## Key inventory (live probe via `pastaperfection-cli keys`)

| Key  | Exists | Type | Size | Purpose |
|------|--------|------|------|---------|
| CHTE | yes    | ui32 | 4    | charging inhibit (Tahoe) |
| CHIE | yes    | hex_ | 1    | adapter disable (Tahoe) |
| CH0B | no     | —    | —    | legacy charging inhibit |
| CH0C | no     | —    | —    | legacy charging inhibit |
| CH0I | no     | —    | —    | legacy adapter disable |

## Confirmed write values

- **CHIE (adapter) — CONFIRMED WORKING 2026-07-05:**
  - `[08]` → adapter electrically off: `pmset` flips to "Now drawing from 'Battery
    Power'; discharging" while physically plugged in.
  - `[00]` → adapter back on: "AC Power" restored.
- **CHTE (charging inhibit) — CONFIRMED WORKING 2026-07-05, LITTLE-ENDIAN:**
  - `[01 00 00 00]` → charging inhibited: `pmset` shows "AC attached; not
    charging" at 95% while plugged in; readback `[01 00 00 00]`; exit 0.
  - `[00 00 00 00]` → charging allowed (resume); readback confirmed; exit 0.
  - `[00 00 00 01]` (big-endian 1) → REJECTED, smcResult 137. Never write BE.

## Notes

- Reads of any key are unprivileged; writes require root (euid 0).
- OpenDente cross-reference: its BatteryState treats NotChargingReason bit 55
  (0x80000000000000) as "our CHTE inhibit" vs bit 24 as system-level inhibit —
  useful later for distinguishing our pause from macOS's own in `get-state`.
