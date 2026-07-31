#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=tests/lib/batch-refine-structure.sh
. "${ROOT}/tests/lib/batch-refine-structure.sh"

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
    fail "${message}: missing '${needle}'"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    fail "${message}: unexpected '${needle}'"
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

AUTH_WAVE_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-wave-auth.json"
if ! declare -F prepare_wave_results >/dev/null; then
  fail "prepare_wave_results helper must model the all-settled auth barrier"
fi
assert_eq \
  '[]' \
  "$(prepare_wave_results "${AUTH_WAVE_FIXTURE}")" \
  "an auth result must discard every result in its mixed wave"

ORDERED_WAVE_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-wave-ordered.json"
assert_eq \
  '[1401,1402,1403]' \
  "$(prepare_wave_results "${ORDERED_WAVE_FIXTURE}" | jq -c '[.[].pr_number]')" \
  "persist order must follow the original wave mergedAt order, not completion order"
assert_eq \
  'insufficient' \
  "$(prepare_wave_results "${ORDERED_WAVE_FIXTURE}" | jq -r '.[] | select(.pr_number == 1401) | .outcome')" \
  "insufficient results must cross the barrier for row and metadata persistence"
if ! declare -F wave_pr_numbers_for_label_transition >/dev/null; then
  fail "wave_pr_numbers_for_label_transition helper must keep insufficient PRs pending"
fi
assert_eq \
  $'1402\n1403' \
  "$(wave_pr_numbers_for_label_transition "${ORDERED_WAVE_FIXTURE}")" \
  "only processed wave results may transition to collected"

PAYLOAD_WAVE_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-wave-payloads.json"
prepared_payload_wave="$(prepare_wave_results "${PAYLOAD_WAVE_FIXTURE}")"
assert_eq \
  '[0,1,2]' \
  "$(jq -c '[.[].slot]' <<<"${prepared_payload_wave}")" \
  "prepared results must retain the authoritative slots in mergedAt order"
assert_eq \
  'true' \
  "$(jq -r 'all(.[]; has("slot") and has("pr_number") and has("outcome") and has("duration_seconds") and has("changed_files") and has("candidate_results") and has("missing") and has("reason") and has("error"))' <<<"${prepared_payload_wave}")" \
  "every persisted outcome must carry the complete common union contract"
assert_eq \
  '{"slot":0,"pr_number":1801,"outcome":"processed","duration_seconds":48,"changed_files":["app/services/billing/payment_router.rb"],"missing":[],"reason":null,"error":null}' \
  "$(jq -c '.[] | select(.outcome == "processed") | {slot,pr_number,outcome,duration_seconds,changed_files,missing,reason,error}' <<<"${prepared_payload_wave}")" \
  "processed results must retain authoritative identity and explicit non-applicable fields"
assert_eq \
  '{"slot":1,"pr_number":1802,"outcome":"insufficient","duration_seconds":16,"changed_files":["docs/adr/payment.md"],"candidate_results":[],"missing":["manifest"],"reason":"Evidence manifest is missing","error":null}' \
  "$(jq -c '.[] | select(.outcome == "insufficient")' <<<"${prepared_payload_wave}")" \
  "insufficient results must carry missing and reason without candidate or error data"
assert_eq \
  '{"slot":2,"pr_number":1803,"outcome":"failed","duration_seconds":27,"changed_files":[],"candidate_results":[],"missing":[],"reason":null,"error":"quality-gate subagent failed"}' \
  "$(jq -c '.[] | select(.outcome == "failed")' <<<"${prepared_payload_wave}")" \
  "failed results must carry error without candidate, missing, or reason data"
assert_eq \
  'true' \
  "$(jq -r 'all(.[] | .candidate_results[]?; .candidate.id == .verdict.candidate_id)' <<<"${prepared_payload_wave}")" \
  "every processed candidate must be paired with its verdict by candidate id"

INVALID_R3_WAVE_FIXTURE="${TMP_DIR}/input-wave-invalid-r3.json"
jq '
  (.results[]
    | select(.outcome == "processed")
    | .candidate_results[0].candidate
  ) |= (.type = "anti-pattern" | .alternative = null)
' "${PAYLOAD_WAVE_FIXTURE}" > "${INVALID_R3_WAVE_FIXTURE}"
if prepare_wave_results "${INVALID_R3_WAVE_FIXTURE}" >/dev/null 2>&1; then
  fail "an anti-pattern without an alternative must abort before changeset persistence"
fi

assert_eq \
  '{"slot":1,"pr_number":1302,"outcome":"github_auth","duration_seconds":12,"changed_files":[],"candidate_results":[],"missing":["github_auth"],"reason":"Required GitHub baseline is unavailable","error":null}' \
  "$(jq -c '.results[] | select(.outcome == "github_auth")' "${AUTH_WAVE_FIXTURE}")" \
  "github_auth must carry its sentinel without partial candidate or changed-file data"

CRASH_WAVE_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-wave-crash.json"
assert_eq \
  '{"slot":1,"pr_number":1502,"outcome":"failed","duration_seconds":null,"changed_files":[],"candidate_results":[],"missing":[],"reason":null,"error":"subagent crashed without returning a payload"}' \
  "$(prepare_wave_results "${CRASH_WAVE_FIXTURE}" | jq -c '.[] | select(.pr_number == 1502)')" \
  "a payload-less settled crash must normalize the complete union against its authoritative slot"

INVALID_PR_WAVE_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-wave-invalid-pr.json"
if prepare_wave_results "${INVALID_PR_WAVE_FIXTURE}" >/dev/null 2>&1; then
  fail "a result whose PR number does not match its authoritative slot must abort before persistence"
fi

DUPLICATE_SLOT_WAVE_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-wave-duplicate-slot.json"
if prepare_wave_results "${DUPLICATE_SLOT_WAVE_FIXTURE}" >/dev/null 2>&1; then
  fail "duplicate results for one authoritative slot must abort before persistence"
fi

MALFORMED_OUTCOME_WAVE_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-wave-malformed-outcome.json"
if prepare_wave_results "${MALFORMED_OUTCOME_WAVE_FIXTURE}" >/dev/null 2>&1; then
  fail "a malformed non-auth outcome must abort the whole unpersisted wave before persistence"
fi

MISSING_CHANGED_FILES_WAVE_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-wave-missing-changed-files.json"
assert_eq \
  '[]' \
  "$(prepare_wave_results "${MISSING_CHANGED_FILES_WAVE_FIXTURE}" | jq -c '.[0].changed_files')" \
  "a returned payload may defensively normalize only a missing changed_files field"

if ! declare -F write_wave_changeset >/dev/null; then
  fail "write_wave_changeset must prepare and validate settled payloads before changeset generation"
fi
WAVE_CHANGESET="${TMP_DIR}/batch-2026-07-15.json"
write_wave_changeset "${PAYLOAD_WAVE_FIXTURE}" "${WAVE_CHANGESET}"
assert_eq \
  "1" \
  "$(jq '.entries | length' "${WAVE_CHANGESET}")" \
  "the sole writer must create one changeset entry from the accepted wave candidate"
assert_eq \
  "route-payments-through-services" \
  "$(jq -r '.entries[0].data.id' "${WAVE_CHANGESET}")" \
  "wave changeset generation must preserve the accepted candidate id"
assert_eq \
  $'## Background\nProvider calls were moved out of controllers.\n\n## Details\nUse one service boundary for retries and idempotency.' \
  "$(jq -r '.entries[0].data.body' "${WAVE_CHANGESET}")" \
  "wave changeset generation must preserve the accepted candidate full body"

MALFORMED_CHANGESET="${TMP_DIR}/malformed-wave.json"
if write_wave_changeset "${MALFORMED_OUTCOME_WAVE_FIXTURE}" "${MALFORMED_CHANGESET}" >/dev/null 2>&1; then
  fail "a malformed non-auth outcome must not reach changeset generation"
fi
if [ -e "${MALFORMED_CHANGESET}" ]; then
  fail "a rejected malformed wave must leave no partial changeset file"
fi

RESUME_REPORT_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-resume-report.md"
if ! declare -F pending_pr_resume_action >/dev/null; then
  fail "pending_pr_resume_action helper must model label-only reconciliation"
fi
assert_eq \
  "reconcile-label" \
  "$(pending_pr_resume_action "${RESUME_REPORT_FIXTURE}" 1701)" \
  "a pending PR with a durable success row must reconcile only its label"
assert_eq \
  "analyze" \
  "$(pending_pr_resume_action "${RESUME_REPORT_FIXTURE}" 1702)" \
  "an insufficient row must remain eligible for fresh analysis"
assert_eq \
  "analyze" \
  "$(pending_pr_resume_action "${RESUME_REPORT_FIXTURE}" 1703)" \
  "a failed row must remain eligible for fresh analysis"

if ! declare -F persist_checkpoint_action >/dev/null; then
  fail "persist_checkpoint_action helper must abort after a durable-write failure"
fi
assert_eq "continue" "$(persist_checkpoint_action 0 0 0)" \
  "a fully successful checkpoint may continue to label transition"
assert_eq "abort" "$(persist_checkpoint_action 1 0 0)" \
  "a changeset/report write failure must abort the batch"
assert_eq "abort" "$(persist_checkpoint_action 0 1 0)" \
  "a commit failure must abort the batch"
assert_eq "abort" "$(persist_checkpoint_action 0 0 1)" \
  "a push failure after retry must abort the batch"

LABELS_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-labels.json"
if ! declare -F build_atomic_label_transition_plan >/dev/null; then
  fail "build_atomic_label_transition_plan must model one fresh read and one full-set update"
fi
label_plan="$(build_atomic_label_transition_plan "${LABELS_FIXTURE}")"
assert_eq \
  '["get_labels"]' \
  "$(jq -c '[.reads[].method]' <<<"${label_plan}")" \
  "label transition must issue exactly one fresh get_labels read"
assert_eq \
  '["update"]' \
  "$(jq -c '[.writes[].method]' <<<"${label_plan}")" \
  "label transition must issue exactly one atomic update write"
assert_eq \
  '["bug","priority:high","knowledge:collected"]' \
  "$(jq -c '.writes[0].labels' <<<"${label_plan}")" \
  "label update must preserve unrelated labels, remove pending, and dedupe collected"
LABELS_WITHOUT_COLLECTED_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-labels-no-collected.json"
assert_eq \
  '["bug","priority:high","knowledge:collected"]' \
  "$(build_atomic_label_transition_plan "${LABELS_WITHOUT_COLLECTED_FIXTURE}" | jq -c '.writes[0].labels')" \
  "label update must append collected when the fresh set does not contain it"
assert_eq \
  '0' \
  "$(jq '[.reads[], .writes[] | select(.method == "remove_label" or .method == "add_label")] | length' <<<"${label_plan}")" \
  "label transition must never split removal and addition into separate calls"

if ! declare -F simulate_atomic_label_update >/dev/null; then
  fail "simulate_atomic_label_update must preserve pending labels when the update fails"
fi
assert_eq \
  '["bug","knowledge:pending","priority:high","knowledge:collected"]' \
  "$(simulate_atomic_label_update "${LABELS_FIXTURE}" update-failed)" \
  "a failed atomic update must leave the fresh label set unchanged for reconciliation"
assert_eq \
  '["bug","priority:high","knowledge:collected"]' \
  "$(simulate_atomic_label_update "${LABELS_FIXTURE}" success)" \
  "a successful atomic update must install the transformed full label set"

if ! declare -F label_transition_action >/dev/null; then
  fail "label_transition_action must route read/update auth and non-auth failures"
fi
assert_eq "auth-abort" "$(label_transition_action auth not-run)" \
  "get_labels auth failure must enter the existing auth abort path"
assert_eq "auth-abort" "$(label_transition_action ok auth)" \
  "atomic update auth failure must enter the existing auth abort path"
assert_eq "abort" "$(label_transition_action error not-run)" \
  "non-auth get_labels failure must abort immediately"
assert_eq "abort" "$(label_transition_action ok error)" \
  "non-auth atomic update failure must abort immediately"
assert_eq "complete" "$(label_transition_action ok ok)" \
  "one successful read and update may complete the transition"

BATCH_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-batch.json"
CHANGESET="${TMP_DIR}/batch-2026-03-24.json"
REPORT="${TMP_DIR}/batch-2026-03-24.md"

write_batch_changeset "${BATCH_FIXTURE}" "${CHANGESET}"

assert_eq "1" "$(jq '[.entries[]] | length' "${CHANGESET}")" "only passed candidates should enter the changeset"
assert_eq "accepted" "$(jq -r '.entries[0].status' "${CHANGESET}")" "changeset entries should be accepted"
assert_eq "payment-service-object-pattern" "$(jq -r '.entries[0].data.id' "${CHANGESET}")" "changeset should preserve accepted candidate ids"
assert_eq "legacy-payment-controller-pattern" "$(jq -r '.entries[0].data.curation[0].related_id' "${CHANGESET}")" "curation queue entries should be mapped into changeset data"
assert_eq "billing-integration" "$(jq -r '.entries[0].data._proposed_domain[0].name' "${CHANGESET}")" "proposed domains should be preserved in the changeset"

assert_eq "1234" "$(processed_pr_numbers_for_label_transition "${BATCH_FIXTURE}")" "only successfully processed PRs should transition to collected"

render_batch_report "${BATCH_FIXTURE}" "${CHANGESET}" "${REPORT}"

report_output="$(cat "${REPORT}")"
assert_contains "${report_output}" "### 진행 상황" "report should render the progress section before summary metrics"
progress_line="$(grep -nF '### 진행 상황' "${REPORT}" | cut -d: -f1)"
summary_line="$(grep -nF '### Summary' "${REPORT}" | cut -d: -f1)"
if [ "${progress_line}" -ge "${summary_line}" ]; then
  fail "report should render the progress section before summary metrics"
fi
assert_contains "${report_output}" "| 항목 | 상태 |" "progress table schema should remain unchanged"
assert_contains "${report_output}" "| #1234 | ✅ 처리 완료 (1 accepted, 4m12s, run #100) |" "processed row should render the subagent duration"
assert_contains "${report_output}" "| #1235 | ⏸ 대기 중 (insufficient: manifest, 1m08s, run #100) |" "insufficient row should render the subagent duration"
assert_contains "${report_output}" "| #1236 | ❌ failed: extract-candidates subagent crashed (duration unknown, run #100) |" "payload-less failed row should render duration unknown"
assert_contains "${report_output}" "| Source PRs processed | 3 |" "report summary should count only persisted non-auth PR outcomes"
assert_not_contains "${report_output}" "#1299" "auth-dead PR number should not be persisted in the report"
assert_not_contains "${report_output}" "16460m54s" "auth-dead sentinel duration should remain Actions-log-only"
assert_contains "${report_output}" "| Candidates extracted | 2 |" "report summary should count extracted candidates"
assert_contains "${report_output}" "| Accepted (fact / anti-pattern) | 1 (1 / 0) |" "report summary should break down accepted entry types"
assert_contains "${report_output}" "| Rejected | 1 |" "report summary should count rejected candidates"
assert_contains "${report_output}" "| Insufficient evidence (deferred) | 1 |" "report summary should count deferred PRs"
assert_contains "${report_output}" "| 총 소요시간(wall-clock) | 7m05s (run #100) |" "summary should render orchestrator wall-clock timing rather than summing per-PR durations"
assert_contains "${report_output}" "| payment-service-object-pattern | fact | Use Service Objects for Payment Flows | payment | #1234 |" "report should list accepted entries"
assert_contains "${report_output}" "| #1234 | R6_DUPLICATE | Semantically identical to existing entry no-ar-callback-api. |" "report should list rejected candidates"
assert_contains "${report_output}" '- `payment-service-object-pattern` <-> `legacy-payment-controller-pattern`: Conflicts with the older controller-centric payment rule.' "report should include curation queue conflicts"
assert_contains "${report_output}" '- New domain `billing-integration`: Billing provider integration rules (patterns: app/services/billing/)' "report should summarize proposed domains"
assert_contains "${report_output}" '- #1235 "Capture missing evidence bundle": manifest' "report should keep insufficient PRs pending in a dedicated section"
assert_contains "${report_output}" '- #1236 "Attempted refinement with flaky Linear context": failed during refinement (extract-candidates subagent crashed).' "report should include failed PR outcomes"
assert_contains "${report_output}" '<!-- KD_BATCH_PR_META {"pr_number":1234,"changed_files":["app/services/payment/orchestrator.rb"]} -->' "processed PR details should retain compact changed-file metadata"
assert_contains "${report_output}" '<!-- KD_BATCH_PR_META {"pr_number":1235,"changed_files":[]} -->' "missing changed_files should normalize to an empty metadata array"
assert_contains "${report_output}" '<!-- KD_BATCH_PR_META {"pr_number":1236,"changed_files":[]} -->' "failed results should retain normalized metadata"
assert_not_contains "${report_output}" '<!-- KD_BATCH_PR_META {"pr_number":1299' "auth-dead PRs must not persist metadata"

marker_payloads="$({
  awk '/^<!-- KD_BATCH_PR_META / {
    sub(/^<!-- KD_BATCH_PR_META /, "")
    sub(/ -->$/, "")
    print
  }' "${REPORT}"
} | jq -s '.')"
assert_eq "3" "$(jq 'length' <<<"${marker_payloads}")" "report metadata should be valid compact JSON for every persisted PR"
assert_eq \
  '["app/services/payment/orchestrator.rb"]' \
  "$(jq -c '[.[] | select(.pr_number == 1234) | .changed_files[]] | unique' <<<"${marker_payloads}")" \
  "metadata should round-trip the processed PR changed-file list"

ZERO_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-batch-all-rejected.json"
ZERO_CHANGESET="${TMP_DIR}/batch-2026-03-31.json"
ZERO_REPORT="${TMP_DIR}/batch-2026-03-31.md"

write_batch_changeset "${ZERO_FIXTURE}" "${ZERO_CHANGESET}"
assert_eq "0" "$(jq '[.entries[]] | length' "${ZERO_CHANGESET}")" "all-rejected batches should still produce an empty changeset"

render_batch_report "${ZERO_FIXTURE}" "${ZERO_CHANGESET}" "${ZERO_REPORT}"
zero_report_output="$(cat "${ZERO_REPORT}")"
assert_contains "${zero_report_output}" "| Accepted (fact / anti-pattern) | 0 (0 / 0) |" "zero-accepted batches should still render accepted metrics"
assert_contains "${zero_report_output}" "| Rejected | 1 |" "zero-accepted batches should still report rejections"

ZERO_SPAWN_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-batch-zero-spawn.json"
ZERO_SPAWN_CHANGESET="${TMP_DIR}/batch-2026-04-07.json"
ZERO_SPAWN_REPORT="${TMP_DIR}/batch-2026-04-07.md"

write_batch_changeset "${ZERO_SPAWN_FIXTURE}" "${ZERO_SPAWN_CHANGESET}"
render_batch_report "${ZERO_SPAWN_FIXTURE}" "${ZERO_SPAWN_CHANGESET}" "${ZERO_SPAWN_REPORT}"

zero_spawn_report_output="$(cat "${ZERO_SPAWN_REPORT}")"
assert_contains "${zero_spawn_report_output}" "| Source PRs processed | 0 |" "zero-spawn runs should report zero persisted source PRs"
assert_contains "${zero_spawn_report_output}" "| 총 소요시간(wall-clock) | N/A (run #102) |" "zero-spawn runs should render exact N/A wall-clock timing"

echo "batch-refine structure tests passed"
