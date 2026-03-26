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

cp "${ROOT}/tests/fixtures/structure/curate-report/input-changeset.json" "${CHANGESET}"
: > "${ACTION_LOG}"

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
assert_contains "${report_output}" "| Accepted entries | 1 |" "report summary should update accepted count"
assert_contains "${report_output}" "| Rejected via curation | 1 |" "report summary should update rejected count"
assert_contains "${report_output}" "### Rejected Entries (via Curation)" "report should include rejected entries section"
assert_contains "${report_output}" "| no-api-in-callbacks | Reviewer requested explicit service boundary wording. |" "report should list rejected entries with reasons"
assert_contains "${report_output}" "| payment-service-object-pattern | fact | Use Service Objects for Payment Flows | Use Service Objects for payment orchestration and retries. |" "report should retain updated accepted entries"
assert_contains "${report_output}" "| Rejected | no-api-in-callbacks | Reason: Reviewer requested explicit service boundary wording. | 2026-03-24T12:00:00Z |" "curation log should record reject actions"
assert_contains "${report_output}" "| Updated | payment-service-object-pattern | Changed: claim | 2026-03-24T12:05:00Z |" "curation log should record update actions"
assert_contains "${report_output}" "| Failed | no-api-in-callbacks | Cannot update rejected entry | 2026-03-24T12:10:00Z |" "curation log should record blocked updates"
assert_contains "${report_output}" "| Unresolved | entry-not-in-batch | Entry not in this batch | 2026-03-24T12:15:00Z |" "curation log should record out-of-batch feedback"

echo "curate-report structure tests passed"
