#!/usr/bin/env bash
set -euo pipefail

# Pure-bash helpers exercising the time-budget / handoff invariants
# documented in the batch-refine skill. Used by tests/handoff-structure.sh.

# Usage: should_start_pr <now_ts> <start_ts> <deadline_seconds>
# Returns 0 (truthy) when there is enough budget left to start a new PR,
# 1 (falsy) when the deadline has been reached or exceeded.
should_start_pr() {
  local now="$1"
  local start="$2"
  local deadline="$3"
  local elapsed=$(( now - start ))
  if [ "$elapsed" -lt "$deadline" ]; then
    return 0
  fi
  return 1
}

# Usage: should_retrigger <retry_count> <max_retry_count> <pending_pr_count>
# Returns 0 when the workflow should retrigger itself, 1 otherwise.
# Retrigger requires both: retry budget left AND at least one pending PR.
should_retrigger() {
  local retry_count="$1"
  local max_retry_count="$2"
  local pending_count="$3"
  if [ "$retry_count" -ge "$max_retry_count" ]; then
    return 1
  fi
  if [ "$pending_count" -le 0 ]; then
    return 1
  fi
  return 0
}

# Usage: format_handoff_row <run_id> <retry_count> <max_retry_count> <processed> <remaining> <action>
# action ∈ { retriggered, max-reached, no-pending }
# Returns a single Markdown table row for the Report PR progress table.
# 401/403 (auth-dead) does NOT produce a row — the handoff procedure is skipped
# entirely per the skill's "Unexpected 401" section. Use classify_handoff with
# auth_dead=1 to confirm "skip-handoff" before deciding to call this.
format_handoff_row() {
  local run_id="$1"
  local retry_count="$2"
  local max_retry_count="$3"
  local processed="$4"
  local remaining="$5"
  local action="$6"
  local body
  case "$action" in
    retriggered)
      body="시간 예산 도달 — 처리 ${processed}개, 남은 ${remaining}개, 재트리거함"
      ;;
    max-reached)
      body="시간 예산 도달 — 처리 ${processed}개, 남은 ${remaining}개, ❗ 재시도 한도 도달, 다음 cron까지 대기"
      ;;
    no-pending)
      body="시간 예산 도달 — 처리 ${processed}개, 남은 0개"
      ;;
    *)
      echo "format_handoff_row: unknown action '$action'" >&2
      return 2
      ;;
  esac
  printf '| run #%s | ⏱ %s (재시도 %s/%s) |\n' \
    "$run_id" "$body" "$retry_count" "$max_retry_count"
}

# Usage: classify_handoff <retry_count> <max_retry_count> <pending_pr_count> <auth_dead>
# Echoes the action label that the orchestrator should pass to format_handoff_row,
# or "skip-handoff" when auth_dead=1 (in which case the orchestrator must NOT enter
# the handoff procedure and must NOT call format_handoff_row — every handoff step
# requires a valid token).
classify_handoff() {
  local retry_count="$1"
  local max_retry_count="$2"
  local pending_count="$3"
  local auth_dead="$4"
  if [ "$auth_dead" = "1" ]; then
    echo "skip-handoff"
    return 0
  fi
  if [ "$pending_count" -le 0 ]; then
    echo "no-pending"
    return 0
  fi
  if [ "$retry_count" -ge "$max_retry_count" ]; then
    echo "max-reached"
    return 0
  fi
  echo "retriggered"
}
