#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=tests/lib/handoff-structure.sh
. "${ROOT}/tests/lib/handoff-structure.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "${expected}" != "${actual}" ]; then
    fail "${message}: expected '${expected}', got '${actual}'"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail "${message}: missing '${needle}' in '${haystack}'"
  fi
}

# -- Time budget gate -----------------------------------------------------

if ! declare -F should_start_wave >/dev/null; then
  fail "should_start_wave helper must define the wave-boundary cancellation point"
fi

# Plenty of budget left.
should_start_wave 100 0 2700 \
  || fail "should_start_wave: fresh run with 45min budget should permit start"

# Halfway through the budget.
should_start_wave 1350 0 2700 \
  || fail "should_start_wave: half-elapsed run should still permit start"

# Boundary: elapsed equals deadline → must refuse (otherwise we may overrun the token).
if should_start_wave 2700 0 2700; then
  fail "should_start_wave: elapsed == deadline must refuse start"
fi

# Boundary: elapsed = deadline - 1 → permit the whole wave. The deadline's
# provisional 15-minute margin must absorb that wave's tail and handoff.
should_start_wave 2699 0 2700 \
  || fail "should_start_wave: elapsed = deadline - 1 should permit start"

# Past the deadline.
if should_start_wave 5000 0 2700; then
  fail "should_start_wave: past-deadline run must refuse start"
fi

# Non-zero start timestamp (real workflow case).
should_start_wave 1700000100 1700000000 2700 \
  || fail "should_start_wave: real-world start ts should permit start"
if should_start_wave 1700002701 1700000000 2700; then
  fail "should_start_wave: real-world past-deadline must refuse start"
fi

# -- Retrigger eligibility ------------------------------------------------

should_retrigger 0 5 3 \
  || fail "should_retrigger: fresh run with pending PRs must retrigger"

should_retrigger 4 5 1 \
  || fail "should_retrigger: retry below max with pending must retrigger"

if should_retrigger 5 5 3; then
  fail "should_retrigger: retry == max must NOT retrigger (boundary)"
fi

if should_retrigger 6 5 3; then
  fail "should_retrigger: retry above max must NOT retrigger"
fi

if should_retrigger 0 5 0; then
  fail "should_retrigger: zero pending PRs must NOT retrigger even on fresh run"
fi

if should_retrigger 5 5 0; then
  fail "should_retrigger: max retry AND zero pending must NOT retrigger"
fi

# -- Handoff classification ----------------------------------------------

assert_eq "retriggered" "$(classify_handoff 0 5 3 0)" \
  "classify_handoff: fresh run with pending and no auth failure"

assert_eq "max-reached" "$(classify_handoff 5 5 3 0)" \
  "classify_handoff: retry exhausted with pending PRs"

assert_eq "full-completion" "$(classify_handoff 0 5 0 0)" \
  "classify_handoff: zero pending must run completion work instead of handoff"

assert_eq "skip-handoff" "$(classify_handoff 0 5 3 1)" \
  "classify_handoff: auth failure must skip handoff entirely (no row produced)"

assert_eq "skip-handoff" "$(classify_handoff 5 5 0 1)" \
  "classify_handoff: auth failure dominates retry/pending state"

# -- Handoff row formatting -----------------------------------------------

row="$(format_handoff_row 100 0 5 2 1 retriggered)"
assert_contains "${row}" "run #100" "retrigger row should embed run id"
assert_contains "${row}" "재시도 0/5" "retrigger row should show retry count"
assert_contains "${row}" "재트리거함" "retrigger row should mention retrigger"
assert_contains "${row}" "처리 2개, 남은 1개" "retrigger row should show progress"

row="$(format_handoff_row 200 5 5 0 3 max-reached)"
assert_contains "${row}" "❗ 재시도 한도 도달" "max-reached row should mark retry limit"
assert_contains "${row}" "다음 cron까지 대기" "max-reached row should explain wait"

# -- Auth-dead must NOT produce a row ------------------------------------
# Skill prose ("Unexpected 401" section) requires the handoff procedure to be
# skipped when auth is dead. format_handoff_row must reject any auth-related
# action so the orchestrator cannot accidentally write a row that requires a
# valid token to commit/push.

if format_handoff_row 1 0 5 0 0 auth-failure-skipped >/dev/null 2>&1; then
  fail "format_handoff_row: must reject auth-failure action (no row when token dead)"
fi

# -- Unknown action is rejected ------------------------------------------

if format_handoff_row 1 0 5 0 0 not-a-real-action >/dev/null 2>&1; then
  fail "format_handoff_row: unknown action must be rejected"
fi

# -- skip-handoff is a control signal, not a row action -------------------

if format_handoff_row 1 0 5 0 0 skip-handoff >/dev/null 2>&1; then
  fail "format_handoff_row: skip-handoff must not be accepted as a row action"
fi

# -- full-completion is a control signal, not a row action ----------------

if format_handoff_row 1 0 5 0 0 full-completion >/dev/null 2>&1; then
  fail "format_handoff_row: full-completion must not produce a handoff row"
fi

echo "handoff structure tests passed"
