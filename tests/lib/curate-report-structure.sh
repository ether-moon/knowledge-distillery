#!/usr/bin/env bash
set -euo pipefail

extract_whitelist_from_pr_body() {
  local pr_body="$1"

  awk '
    /### Accepted Entries/ { in_section=1; next }
    in_section && /^### / { in_section=0 }
    in_section && /^\|/ {
      if ($0 ~ /^\| ID \|/ || $0 ~ /^\|----/) next
      split($0, columns, "|")
      id = columns[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      if (id != "") print id
    }
  ' "${pr_body}"
}

whitelist_includes() {
  local whitelist_file="$1"
  local entry_id="$2"

  grep -Fxq -- "${entry_id}" "${whitelist_file}"
}

append_action_log() {
  local log_file="$1"
  local action="$2"
  local entry_id="$3"
  local details="$4"
  local timestamp="$5"

  printf '%s\t%s\t%s\t%s\n' "${action}" "${entry_id}" "${details}" "${timestamp}" >> "${log_file}"
}

apply_reject_action() {
  local changeset_file="$1"
  local whitelist_file="$2"
  local entry_id="$3"
  local reason="$4"
  local log_file="$5"
  local timestamp="$6"
  local tmp_file

  if ! whitelist_includes "${whitelist_file}" "${entry_id}"; then
    append_action_log "${log_file}" "Unresolved" "${entry_id}" "Entry not in this batch" "${timestamp}"
    return 0
  fi

  if ! jq -e --arg entry_id "${entry_id}" '.entries[] | select(.data.id == $entry_id)' "${changeset_file}" >/dev/null; then
    append_action_log "${log_file}" "Failed" "${entry_id}" "Entry not in changeset" "${timestamp}"
    return 0
  fi

  if jq -e --arg entry_id "${entry_id}" '.entries[] | select(.data.id == $entry_id and .status == "rejected")' "${changeset_file}" >/dev/null; then
    append_action_log "${log_file}" "Skipped" "${entry_id}" "Already rejected" "${timestamp}"
    return 0
  fi

  tmp_file="$(mktemp)"
  jq --arg entry_id "${entry_id}" --arg reason "${reason}" '
    .entries |= map(
      if .data.id == $entry_id
      then . + {status: "rejected", reject_reason: $reason}
      else .
      end
    )
  ' "${changeset_file}" > "${tmp_file}"
  mv "${tmp_file}" "${changeset_file}"

  append_action_log "${log_file}" "Rejected" "${entry_id}" "Reason: ${reason}" "${timestamp}"
}

apply_claim_update_action() {
  local changeset_file="$1"
  local whitelist_file="$2"
  local entry_id="$3"
  local new_claim="$4"
  local log_file="$5"
  local timestamp="$6"
  local tmp_file

  if ! whitelist_includes "${whitelist_file}" "${entry_id}"; then
    append_action_log "${log_file}" "Unresolved" "${entry_id}" "Entry not in this batch" "${timestamp}"
    return 0
  fi

  if ! jq -e --arg entry_id "${entry_id}" '.entries[] | select(.data.id == $entry_id)' "${changeset_file}" >/dev/null; then
    append_action_log "${log_file}" "Failed" "${entry_id}" "Entry not in changeset" "${timestamp}"
    return 0
  fi

  if jq -e --arg entry_id "${entry_id}" '.entries[] | select(.data.id == $entry_id and .status == "rejected")' "${changeset_file}" >/dev/null; then
    append_action_log "${log_file}" "Failed" "${entry_id}" "Cannot update rejected entry" "${timestamp}"
    return 0
  fi

  tmp_file="$(mktemp)"
  jq --arg entry_id "${entry_id}" --arg new_claim "${new_claim}" '
    .entries |= map(
      if .data.id == $entry_id
      then .data.claim = $new_claim
      else .
      end
    )
  ' "${changeset_file}" > "${tmp_file}"
  mv "${tmp_file}" "${changeset_file}"

  append_action_log "${log_file}" "Updated" "${entry_id}" "Changed: claim" "${timestamp}"
}

render_curation_report() {
  local changeset_file="$1"
  local action_log_file="$2"
  local report_file="$3"
  local batch_date
  local accepted_count
  local rejected_count

  batch_date="$(jq -r '.batch_date' "${changeset_file}")"
  accepted_count="$(jq '[.entries[] | select(.status == "accepted")] | length' "${changeset_file}")"
  rejected_count="$(jq '[.entries[] | select(.status == "rejected")] | length' "${changeset_file}")"

  {
    printf '## Knowledge Distillery Batch Report — %s\n\n' "${batch_date}"
    printf '### Summary\n'
    printf '| Metric | Value |\n'
    printf '|--------|-------|\n'
    printf '| Accepted entries | %s |\n' "${accepted_count}"
    printf '| Rejected via curation | %s |\n\n' "${rejected_count}"

    printf '### Accepted Entries\n\n'
    printf '| ID | Type | Title | Claim |\n'
    printf '|----|------|-------|-------|\n'
    jq -r '
      .entries[]
      | select(.status == "accepted")
      | "| \(.data.id) | \(.data.type) | \(.data.title) | \(.data.claim) |"
    ' "${changeset_file}"
    printf '\n'

    printf '### Rejected Entries (via Curation)\n\n'
    printf '| ID | Reason |\n'
    printf '|----|--------|\n'
    jq -r '
      .entries[]
      | select(.status == "rejected")
      | "| \(.data.id) | \(.reject_reason // "No reason provided") |"
    ' "${changeset_file}"
    printf '\n'

    printf '### Curation Log\n\n'
    printf '| Action | Entry ID | Details | Timestamp |\n'
    printf '|--------|----------|---------|-----------|\n'
    awk -F '\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "${action_log_file}"
  } > "${report_file}"
}
