#!/usr/bin/env bash
set -euo pipefail

write_batch_changeset() {
  local batch_fixture="$1"
  local changeset_file="$2"

  jq '
    {
      version: 1,
      batch_date: .batch_date,
      entries: [
        .prs[]
        | .candidate_results[]?
        | select(.verdict.verdict == "pass")
        | {
            status: "accepted",
            data: (
              .candidate
              + if .verdict.curation_queue_entry == null
                then {}
                else {
                  curation: [
                    {
                      related_id: .verdict.curation_queue_entry.related_id,
                      reason: .verdict.curation_queue_entry.reason
                    }
                  ]
                }
                end
            )
          }
      ]
    }
  ' "${batch_fixture}" > "${changeset_file}"
}

processed_pr_numbers_for_label_transition() {
  local batch_fixture="$1"

  jq -r '.prs[] | select(.outcome == "processed") | .number' "${batch_fixture}"
}

render_batch_report() {
  local batch_fixture="$1"
  local changeset_file="$2"
  local report_file="$3"

  local batch_date
  local source_pr_count
  local candidate_count
  local accepted_count
  local accepted_facts
  local accepted_antipatterns
  local rejected_count
  local insufficient_count

  batch_date="$(jq -r '.batch_date' "${batch_fixture}")"
  source_pr_count="$(jq '[.prs[]] | length' "${batch_fixture}")"
  candidate_count="$(jq '[.prs[] | .candidate_results[]?] | length' "${batch_fixture}")"
  accepted_count="$(jq '[.entries[] | select(.status == "accepted")] | length' "${changeset_file}")"
  accepted_facts="$(jq '[.entries[] | select(.status == "accepted" and .data.type == "fact")] | length' "${changeset_file}")"
  accepted_antipatterns="$(jq '[.entries[] | select(.status == "accepted" and .data.type == "anti-pattern")] | length' "${changeset_file}")"
  rejected_count="$(jq '[.prs[] | .candidate_results[]? | select(.verdict.verdict == "fail")] | length' "${batch_fixture}")"
  insufficient_count="$(jq '[.prs[] | select(.outcome == "insufficient")] | length' "${batch_fixture}")"

  {
    printf '## Knowledge Distillery Batch Report — %s\n\n' "${batch_date}"
    printf '### Summary\n'
    printf '| Metric | Value |\n'
    printf '|--------|-------|\n'
    printf '| Source PRs processed | %s |\n' "${source_pr_count}"
    printf '| Candidates extracted | %s |\n' "${candidate_count}"
    printf '| Accepted (fact / anti-pattern) | %s (%s / %s) |\n' "${accepted_count}" "${accepted_facts}" "${accepted_antipatterns}"
    printf '| Rejected | %s |\n' "${rejected_count}"
    printf '| Insufficient evidence (deferred) | %s |\n\n' "${insufficient_count}"

    printf '### Accepted Entries\n\n'
    printf '| ID | Type | Title | Domains | Source PR |\n'
    printf '|----|------|-------|---------|-----------|\n'
    jq -r '
      .entries[]
      | select(.status == "accepted")
      | .data as $entry
      | "| \($entry.id) | \($entry.type) | \($entry.title) | \($entry.applies_to.domains | join(", ")) | #\($entry._source_pr) |"
    ' "${changeset_file}"
    printf '\n'

    printf '### Rejected Candidates\n\n'
    printf '| Source PR | Code | Reason |\n'
    printf '|-----------|------|--------|\n'
    jq -r '
      .prs[]
      | .number as $pr_number
      | .candidate_results[]?
      | select(.verdict.verdict == "fail")
      | "| #\($pr_number) | \(.verdict.rejection_codes | join(", ")) | \(.verdict.notes) |"
    ' "${batch_fixture}"
    printf '\n'

    printf '### Curation Queue (Human Review Required)\n'
    if jq -e '.entries[] | select(.status == "accepted" and (.data.curation // []) != [])' "${changeset_file}" >/dev/null; then
      jq -r '
        .entries[]
        | select(.status == "accepted")
        | .data as $entry
        | ($entry.curation // [])[]
        | "- `\($entry.id)` <-> `\(.related_id)`: \(.reason)"
      ' "${changeset_file}"
    else
      printf 'No conflicts detected.\n'
    fi
    printf '\n'

    printf '### Domain Changes\n'
    if jq -e '.entries[] | select(.status == "accepted" and (.data._proposed_domain // []) != [])' "${changeset_file}" >/dev/null; then
      jq -r '
        .entries[]
        | select(.status == "accepted")
        | .data._proposed_domain[]?
        | "- New domain `\(.name)`: \(.description) (patterns: \(.suggested_patterns | join(", ")))"
      ' "${changeset_file}"
    else
      printf 'No new domains proposed in this batch.\n'
    fi
    printf '\n'

    printf '### Source PR Details\n'
    jq -r '
      .prs[]
      | if .outcome == "processed" then
          "- #\(.number) \"\(.title)\": processed, \([.candidate_results[]? | select(.verdict.verdict == "pass")] | length) accepted, \([.candidate_results[]? | select(.verdict.verdict == "fail")] | length) rejected."
        elif .outcome == "insufficient" then
          "- #\(.number) \"\(.title)\": insufficient evidence, deferred."
        else
          "- #\(.number) \"\(.title)\": failed during refinement (\(.error))."
        end
    ' "${batch_fixture}"
    printf '\n'

    printf '### Insufficient Evidence (Remains Pending)\n'
    if jq -e '.prs[] | select(.outcome == "insufficient")' "${batch_fixture}" >/dev/null; then
      jq -r '
        .prs[]
        | select(.outcome == "insufficient")
        | "- #\(.number) \"\(.title)\": \(.missing | join(", "))"
      ' "${batch_fixture}"
    else
      printf 'All PRs had sufficient evidence.\n'
    fi
  } > "${report_file}"
}
