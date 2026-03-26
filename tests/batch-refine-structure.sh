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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
assert_contains "${report_output}" "| Source PRs processed | 3 |" "report summary should include all discovered PRs"
assert_contains "${report_output}" "| Candidates extracted | 2 |" "report summary should count extracted candidates"
assert_contains "${report_output}" "| Accepted (fact / anti-pattern) | 1 (1 / 0) |" "report summary should break down accepted entry types"
assert_contains "${report_output}" "| Rejected | 1 |" "report summary should count rejected candidates"
assert_contains "${report_output}" "| Insufficient evidence (deferred) | 1 |" "report summary should count deferred PRs"
assert_contains "${report_output}" "| payment-service-object-pattern | fact | Use Service Objects for Payment Flows | payment | #1234 |" "report should list accepted entries"
assert_contains "${report_output}" "| #1234 | R6_DUPLICATE | Semantically identical to existing entry no-ar-callback-api. |" "report should list rejected candidates"
assert_contains "${report_output}" '- `payment-service-object-pattern` <-> `legacy-payment-controller-pattern`: Conflicts with the older controller-centric payment rule.' "report should include curation queue conflicts"
assert_contains "${report_output}" '- New domain `billing-integration`: Billing provider integration rules (patterns: app/services/billing/)' "report should summarize proposed domains"
assert_contains "${report_output}" '- #1235 "Capture missing evidence bundle": manifest' "report should keep insufficient PRs pending in a dedicated section"
assert_contains "${report_output}" '- #1236 "Attempted refinement with flaky Linear context": failed during refinement (extract-candidates subagent crashed).' "report should include failed PR outcomes"

ZERO_FIXTURE="${ROOT}/tests/fixtures/structure/batch-refine/input-batch-all-rejected.json"
ZERO_CHANGESET="${TMP_DIR}/batch-2026-03-31.json"
ZERO_REPORT="${TMP_DIR}/batch-2026-03-31.md"

write_batch_changeset "${ZERO_FIXTURE}" "${ZERO_CHANGESET}"
assert_eq "0" "$(jq '[.entries[]] | length' "${ZERO_CHANGESET}")" "all-rejected batches should still produce an empty changeset"

render_batch_report "${ZERO_FIXTURE}" "${ZERO_CHANGESET}" "${ZERO_REPORT}"
zero_report_output="$(cat "${ZERO_REPORT}")"
assert_contains "${zero_report_output}" "| Accepted (fact / anti-pattern) | 0 (0 / 0) |" "zero-accepted batches should still render accepted metrics"
assert_contains "${zero_report_output}" "| Rejected | 1 |" "zero-accepted batches should still report rejections"

echo "batch-refine structure tests passed"
