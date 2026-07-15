#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=tests/lib/curate-report-structure.sh
. "${ROOT}/tests/lib/curate-report-structure.sh"

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CHANGESET="${TMP_DIR}/batch-2026-03-24.json"
PR_BODY="${ROOT}/tests/fixtures/structure/curate-report/report-pr-body.md"
WHITELIST="${TMP_DIR}/whitelist.txt"
ACTION_LOG="${TMP_DIR}/curation.log"
REPORT="${TMP_DIR}/batch-2026-03-24.md"
CURATE_HELPER="${ROOT}/tests/lib/curate-report-structure.sh"
EXPECTED_PROGRESS="${TMP_DIR}/expected-progress.md"
EXPECTED_METADATA="${TMP_DIR}/expected-metadata.md"
ACTUAL_PROGRESS="${TMP_DIR}/actual-progress.md"
ACTUAL_METADATA="${TMP_DIR}/actual-metadata.md"

helper_source="$(cat "${CURATE_HELPER}")"
assert_contains "${helper_source}" 'destination_file="$(mktemp "${report_dir}/.${report_name}.destination.XXXXXX")"' "curation should build the complete destination beside the report"
assert_contains "${helper_source}" 'trap cleanup_curation_report_temps EXIT' "curation should clean temporary files on every function exit"
metadata_append_line="$(grep -nF 'awk '\''{ print }'\'' "${metadata_snapshot}" >> "${destination_file}"' "${CURATE_HELPER}" | cut -d: -f1)"
replace_line="$(grep -nF 'mv "${destination_file}" "${report_file}"' "${CURATE_HELPER}" | cut -d: -f1)"
if [ -z "${metadata_append_line}" ] || [ -z "${replace_line}" ] || [ "${metadata_append_line}" -ge "${replace_line}" ]; then
  fail "curation must append all metadata to the destination before the single report replacement"
fi
assert_eq "1" "$(grep -cF 'mv "${destination_file}" "${report_file}"' "${CURATE_HELPER}")" "curation should replace the report exactly once"

cp "${ROOT}/tests/fixtures/structure/curate-report/input-changeset.json" "${CHANGESET}"
cp "${PR_BODY}" "${REPORT}"
: > "${ACTION_LOG}"
awk '
  /^### 진행 상황$/ { in_progress = 1 }
  in_progress && /^### / && $0 != "### 진행 상황" { exit }
  in_progress { print }
' "${REPORT}" > "${EXPECTED_PROGRESS}"
awk '/^<!-- KD_BATCH_PR_META .* -->$/' "${REPORT}" > "${EXPECTED_METADATA}"

extract_whitelist_from_pr_body "${PR_BODY}" > "${WHITELIST}"

assert_eq \
  $'payment-service-object-pattern\nno-api-in-callbacks' \
  "$(cat "${WHITELIST}")" \
  "accepted entries table should define the whitelist in order"

apply_reject_action \
  "${CHANGESET}" \
  "${WHITELIST}" \
  "no-api-in-callbacks" \
  "Reviewer requested explicit service boundary wording." \
  "${ACTION_LOG}" \
  "2026-03-24T12:00:00Z"

assert_eq \
  "rejected" \
  "$(jq -r '.entries[] | select(.data.id == "no-api-in-callbacks") | .status' "${CHANGESET}")" \
  "reject action should mark the entry as rejected"

assert_eq \
  "Reviewer requested explicit service boundary wording." \
  "$(jq -r '.entries[] | select(.data.id == "no-api-in-callbacks") | .reject_reason' "${CHANGESET}")" \
  "reject action should preserve the reviewer reason"

apply_claim_update_action \
  "${CHANGESET}" \
  "${WHITELIST}" \
  "payment-service-object-pattern" \
  "Use Service Objects for payment orchestration and retries." \
  "${ACTION_LOG}" \
  "2026-03-24T12:05:00Z"

assert_eq \
  "Use Service Objects for payment orchestration and retries." \
  "$(jq -r '.entries[] | select(.data.id == "payment-service-object-pattern") | .data.claim' "${CHANGESET}")" \
  "update action should change the requested field"

apply_claim_update_action \
  "${CHANGESET}" \
  "${WHITELIST}" \
  "no-api-in-callbacks" \
  "MUST-NOT call external APIs from callbacks or observers." \
  "${ACTION_LOG}" \
  "2026-03-24T12:10:00Z"

assert_eq \
  "MUST-NOT call external APIs from ActiveRecord callbacks." \
  "$(jq -r '.entries[] | select(.data.id == "no-api-in-callbacks") | .data.claim' "${CHANGESET}")" \
  "rejected entries must not be updated"

apply_reject_action \
  "${CHANGESET}" \
  "${WHITELIST}" \
  "entry-not-in-batch" \
  "Out-of-scope feedback." \
  "${ACTION_LOG}" \
  "2026-03-24T12:15:00Z"

assert_eq \
  "2" \
  "$(jq '[.entries[]] | length' "${CHANGESET}")" \
  "out-of-batch feedback must not mutate the changeset"

render_curation_report "${CHANGESET}" "${ACTION_LOG}" "${REPORT}"

report_output="$(cat "${REPORT}")"
awk '
  /^### 진행 상황$/ { in_progress = 1 }
  in_progress && /^### / && $0 != "### 진행 상황" { exit }
  in_progress { print }
' "${REPORT}" > "${ACTUAL_PROGRESS}"
awk '/^<!-- KD_BATCH_PR_META .* -->$/' "${REPORT}" > "${ACTUAL_METADATA}"
if ! cmp -s "${EXPECTED_PROGRESS}" "${ACTUAL_PROGRESS}"; then
  fail "curation regeneration should restore the complete progress block verbatim"
fi
if ! cmp -s "${EXPECTED_METADATA}" "${ACTUAL_METADATA}"; then
  fail "curation regeneration should restore every metadata marker verbatim and in order"
fi
assert_eq "1" "$(grep -cF '### 진행 상황' "${REPORT}")" "curation regeneration should retain exactly one progress block"
assert_eq "1" "$(grep -cF '<!-- KD_BATCH_PR_META {"pr_number":1234,"changed_files":["app/services/payment/orchestrator.rb"]} -->' "${REPORT}")" "curation regeneration should retain the first marker exactly once"
assert_eq "1" "$(grep -cF '<!-- KD_BATCH_PR_META {"pr_number":1235,"changed_files":[]} -->' "${REPORT}")" "curation regeneration should retain the second marker exactly once"
assert_contains "${report_output}" "### 진행 상황" "curation regeneration should preserve the append-only progress heading"
assert_contains "${report_output}" "| #1234 | ✅ 처리 완료 (1 accepted, 4m12s, run #100) |" "curation regeneration should preserve prior PR progress verbatim"
assert_contains "${report_output}" "| run #100 | ⏱ 시간 예산 도달 — 처리 1개, 남은 1개, 재트리거함 → run #101 |" "curation regeneration should preserve handoff history verbatim"
assert_contains "${report_output}" '<!-- KD_BATCH_PR_META {"pr_number":1234,"changed_files":["app/services/payment/orchestrator.rb"]} -->' "curation regeneration should preserve changed-file metadata verbatim"
assert_contains "${report_output}" '<!-- KD_BATCH_PR_META {"pr_number":1235,"changed_files":[]} -->' "curation regeneration should preserve empty changed-file metadata verbatim"
progress_line="$(grep -nF '### 진행 상황' "${REPORT}" | cut -d: -f1)"
summary_line="$(grep -nF '### Summary' "${REPORT}" | cut -d: -f1)"
if [ "${progress_line}" -ge "${summary_line}" ]; then
  fail "curation regeneration should restore progress before summary"
fi
assert_contains "${report_output}" "| Accepted entries | 1 |" "report summary should update accepted count"
assert_contains "${report_output}" "| Rejected via curation | 1 |" "report summary should update rejected count"
assert_contains "${report_output}" "### Rejected Entries (via Curation)" "report should include rejected entries section"
assert_contains "${report_output}" "| no-api-in-callbacks | Reviewer requested explicit service boundary wording. |" "report should list rejected entries with reasons"
assert_contains "${report_output}" "| payment-service-object-pattern | fact | Use Service Objects for Payment Flows | Use Service Objects for payment orchestration and retries. |" "report should retain updated accepted entries"
assert_contains "${report_output}" "| Rejected | no-api-in-callbacks | Reason: Reviewer requested explicit service boundary wording. | 2026-03-24T12:00:00Z |" "curation log should record reject actions"
assert_contains "${report_output}" "| Updated | payment-service-object-pattern | Changed: claim | 2026-03-24T12:05:00Z |" "curation log should record update actions"
assert_contains "${report_output}" "| Failed | no-api-in-callbacks | Cannot update rejected entry | 2026-03-24T12:10:00Z |" "curation log should record blocked updates"
assert_contains "${report_output}" "| Unresolved | entry-not-in-batch | Entry not in this batch | 2026-03-24T12:15:00Z |" "curation log should record out-of-batch feedback"

FAILURE_REPORT="${TMP_DIR}/batch-2026-03-24-failure.md"
FAILURE_ORIGINAL="${TMP_DIR}/batch-2026-03-24-failure.original.md"
cp "${PR_BODY}" "${FAILURE_REPORT}"
cp "${FAILURE_REPORT}" "${FAILURE_ORIGINAL}"
set +e
(
  set -e
  render_curation_report \
    "${CHANGESET}" \
    "${TMP_DIR}/missing-action.log" \
    "${FAILURE_REPORT}"
) 2>/dev/null
failure_status=$?
set -e
if [ "${failure_status}" -eq 0 ]; then
  fail "curation failure probe should fail before replacing the report"
fi
if ! cmp -s "${FAILURE_ORIGINAL}" "${FAILURE_REPORT}"; then
  fail "curation failure before final replace must leave the original report untouched"
fi
failure_temps=("${TMP_DIR}/.batch-2026-03-24-failure.md."*)
if [ -e "${failure_temps[0]}" ]; then
  fail "curation failure should clean every same-directory temporary file"
fi

echo "curate-report structure tests passed"
