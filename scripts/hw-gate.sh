#!/bin/bash
# Ampere hardware gate — the human-present [HW] checks from .ailoop/oracle.md
# (Phases 1-4). Run from a normal Terminal (sudo will prompt): bash scripts/hw-gate.sh
# Requires: charger attached. Every step prints PASS/FAIL; script continues on
# failure so you get the full picture, and always restores a safe state at the end.
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=.build/release/ampere-cli
SOCK=/var/run/ampere.sock
FAILS=0

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS+1)); }

req()  { "$CLI" req "$1" 2>/dev/null; }

[ -x "$CLI" ] || { echo "release build missing — run: swift build -c release"; exit 1; }

say "Preflight: charger"
if pmset -g batt | grep -q "AC Power"; then pass "on AC power"; else
  fail "not on AC power — plug in the charger and re-run"; exit 1; fi

say "Phase 1: install daemon"
sudo "$CLI" uninstall >/dev/null 2>&1  # idempotent: clean slate
if sudo "$CLI" install; then pass "install ran"; else fail "install command failed"; fi
sleep 3
if launchctl print system/com.ampere.daemon >/dev/null 2>&1; then
  pass "launchd shows com.ampere.daemon"; else fail "daemon not in launchd"; fi

say "Phase 1: socket state (no sudo)"
STATE=$("$CLI" state 2>&1)
if [ $? -eq 0 ] && echo "$STATE" | grep -q '"percent"'; then
  pass "state over socket: $(echo "$STATE" | head -c 120)..."
else fail "state failed: $STATE"; fi

say "Phase 1: socket preflight (everything below needs it)"
if req '{"cmd":"get-state"}' | grep -q '"ok":true'; then
  pass "socket answers get-state"
else
  fail "cannot talk to daemon socket ($(ls -la "$SOCK" 2>&1)) — remaining checks will fail; fix the socket group first"
fi

say "Phase 1: limit enforcement (battery above limit -> charging inhibited)"
PCT=$(pmset -g batt | grep -oE '[0-9]+%' | tr -d '%')
LIMIT=$(( PCT > 80 ? 80 : PCT - 10 ))
req "{\"cmd\":\"set-limit\",\"value\":$LIMIT}" >/dev/null
echo "battery ${PCT}%, limit set to ${LIMIT}% — waiting up to 60 s for inhibit..."
OK=""
for _ in $(seq 1 12); do
  sleep 5
  # Authoritative signal: the daemon's own chargingPaused. pmset's "not
  # charging" is secondary — at 100% a full battery reads "charged" either way.
  if req '{"cmd":"get-state"}' | grep -q '"chargingPaused":true'; then OK=1; break; fi
  if pmset -g batt | grep -qi "not charging"; then OK=1; break; fi
done
if [ -n "$OK" ]; then pass "charging inhibited (chargingPaused/pmset) with charger attached"; else
  fail "charging not inhibited within 60 s (pmset: $(pmset -g batt | tail -1))"; fi

say "Phase 2: socket round-trip (set-limit 65 -> get-state reflects 65)"
req '{"cmd":"set-limit","value":65}' >/dev/null
sleep 1
GS=$(req '{"cmd":"get-state"}')
if echo "$GS" | grep -q '"limit":65'; then pass "get-state reports limit 65"; else
  fail "limit not reflected: $GS"; fi
req "{\"cmd\":\"set-limit\",\"value\":$LIMIT}" >/dev/null

say "Phase 2: discharge to limit (self-induced-unplug suppression, SPEC §3.3 amended)"
PCT=$(pmset -g batt | grep -oE '[0-9]+%' | tr -d '%')
if [ "$PCT" -gt 80 ]; then
  req '{"cmd":"set-limit","value":80}' >/dev/null
  req '{"cmd":"action","name":"discharge-to-limit"}' >/dev/null
  echo "battery ${PCT}%, limit 80 — waiting up to 15 s for adapter disable..."
  OK=""
  for _ in $(seq 1 15); do
    sleep 1
    if req '{"cmd":"get-state"}' | grep -q '"adapterDisabled":true' \
      && pmset -g batt | grep -q "Battery Power"; then OK=1; break; fi
  done
  if [ -n "$OK" ]; then
    pass "adapter disabled + pmset shows Battery Power (adapter off did not self-cancel via unplug suppression)"
  else
    fail "discharge-to-limit did not disable the adapter within 15 s (pmset: $(pmset -g batt | tail -1))"
  fi

  # Re-read current percent and set the limit to it: percent <= limit is
  # already true, so the one-shot completes (enableAdapter) immediately on
  # the daemon's next tick.
  PCT_NOW=$(pmset -g batt | grep -oE '[0-9]+%' | tr -d '%')
  req "{\"cmd\":\"set-limit\",\"value\":$PCT_NOW}" >/dev/null
  echo "limit set to current ${PCT_NOW}% — waiting up to 15 s for adapter re-enable..."
  OK=""
  for _ in $(seq 1 15); do
    sleep 1
    if req '{"cmd":"get-state"}' | grep -q '"adapterDisabled":false' \
      && pmset -g batt | grep -q "AC Power"; then OK=1; break; fi
  done
  if [ -n "$OK" ]; then pass "adapter re-enabled + pmset back on AC Power"; else
    fail "adapter not re-enabled within 15 s (pmset: $(pmset -g batt | tail -1))"; fi

  req '{"cmd":"set-limit","value":80}' >/dev/null
else
  fail "battery ${PCT}% <= 80 — skipping discharge-to-limit check (need >80% to discharge down to limit 80)"
fi

say "Phase 3: heat protection (threshold below current temp -> paused, reason heat)"
TEMP=$(echo "$GS" | grep -oE '"temperatureC":[0-9.]+' | cut -d: -f2)
req '{"cmd":"set-config","config":{"heatThresholdC":20}}' >/dev/null
echo "current temp ${TEMP}°C, threshold forced to 20°C — waiting up to 60 s..."
OK=""
for _ in $(seq 1 12); do
  sleep 5
  if req '{"cmd":"get-state"}' | grep -q '"pauseReason":"heat"'; then OK=1; break; fi
done
if [ -n "$OK" ]; then pass "pauseReason == heat"; else fail "heat pause not observed"; fi
req '{"cmd":"set-config","config":{"heatThresholdC":35}}' >/dev/null

say "Phase 3: stats vs ioreg"
# Match only the top-level '"CycleCount" = N' line — ioreg also embeds a
# CycleCount inside one-line nested dictionaries (BatteryData), which is why
# a loose grep returns garbage.
CY_IOREG=$(ioreg -rn AppleSmartBattery | grep -E '^[[:space:]|]*"CycleCount" = [0-9]+$' | grep -oE '[0-9]+$' | head -1)
CY_STATE=$(req '{"cmd":"get-state"}' | grep -oE '"cycleCount":[0-9]+' | cut -d: -f2)
if [ "$CY_IOREG" = "$CY_STATE" ]; then pass "cycle count matches ioreg ($CY_STATE)"; else
  fail "cycle count mismatch: ioreg=$CY_IOREG state=$CY_STATE"; fi

say "Phase 4: calibration start/abort"
CS=$(req '{"cmd":"action","name":"calibrate-start"}')
sleep 2
GS=$(req '{"cmd":"get-state"}')
if echo "$GS" | grep -q '"calibration":{'; then pass "calibration running: $(echo "$GS" | grep -oE '"calibration":\{[^}]*\}')"; else
  fail "calibrate-start did not start: $CS"; fi
req '{"cmd":"action","name":"calibrate-abort"}' >/dev/null
sleep 2
GS=$(req '{"cmd":"get-state"}')
if echo "$GS" | grep -q '"calibration":null'; then pass "abort restored limit mode"; else
  fail "calibration still present after abort"; fi

say "Restore + summary"
req '{"cmd":"set-limit","value":80}' >/dev/null
echo "limit restored to 80%. Daemon left INSTALLED and running."
echo
echo "Remaining passive check (can't be scripted): sleep the Mac ~10 min with"
echo "charger attached and battery at/above the limit; on wake, pmset -g batt"
echo "should still show 'not charging'."
echo
if [ "$FAILS" -eq 0 ]; then
  printf '\033[32mALL SCRIPTED [HW] CHECKS PASSED\033[0m\n'
else
  printf '\033[31m%d CHECK(S) FAILED\033[0m — paste this output back to the coordinator\n' "$FAILS"
fi
exit "$FAILS"
