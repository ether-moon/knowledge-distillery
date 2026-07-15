#!/usr/bin/env bash
set -euo pipefail

# Emits the results that may cross the all-settled auth barrier. An auth-dead
# result invalidates the entire wave, including otherwise successful peers.
prepare_wave_results() {
  local wave_fixture="$1"

  jq -c '
    .wave_prs as $wave_prs
    | .results as $results
    | if any($results[]; .outcome == "github_auth") then
      []
    elif ($results | group_by(.slot) | any(.[]; length > 1)) then
      error("duplicate result slot")
    elif any(
      $results[];
      . as $result
      | ([
          $wave_prs[]
          | select(.slot == $result.slot and .number == $result.pr_number)
        ] | length) != 1
    ) then
      error("result does not match its authoritative slot and PR")
    else
      [
          $wave_prs
          | sort_by(.merged_at)[]
          | . as $pr
          | ($results | map(select(.slot == $pr.slot))) as $matched
          | if ($matched | length) == 0 then
              {
                slot: $pr.slot,
                pr_number: $pr.number,
                outcome: "failed",
                duration_seconds: null,
                changed_files: [],
                error: "subagent crashed without returning a payload"
              }
            else
              $matched[0]
            end
        ]
    end
  ' "${wave_fixture}"
}

wave_pr_numbers_for_label_transition() {
  local wave_fixture="$1"

  prepare_wave_results "${wave_fixture}" | jq -r '.[] | select(.outcome == "processed") | .pr_number'
}

pending_pr_resume_action() {
  local report_file="$1"
  local pr_number="$2"

  if grep -Fq "| #${pr_number} | ✅ 처리 완료 (" "${report_file}"; then
    printf 'reconcile-label\n'
    return
  fi
  printf 'analyze\n'
}

persist_checkpoint_action() {
  local write_status="$1"
  local commit_status="$2"
  local push_status="$3"

  if [ "${write_status}" -ne 0 ] || [ "${commit_status}" -ne 0 ] || [ "${push_status}" -ne 0 ]; then
    printf 'abort\n'
    return
  fi
  printf 'continue\n'
}

build_atomic_label_transition_plan() {
  local labels_fixture="$1"

  jq -c '
    def transformed_labels:
      reduce .[] as $label (
        [];
        if $label == "knowledge:pending" then
          .
        elif $label == "knowledge:collected" then
          if index("knowledge:collected") == null then . + [$label] else . end
        else
          . + [$label]
        end
      )
      | if index("knowledge:collected") == null then
          . + ["knowledge:collected"]
        else
          .
        end;
    {
      reads: [{method: "get_labels"}],
      writes: [{method: "update", labels: transformed_labels}]
    }
  ' "${labels_fixture}"
}

simulate_atomic_label_update() {
  local labels_fixture="$1"
  local outcome="$2"

  case "${outcome}" in
    success)
      build_atomic_label_transition_plan "${labels_fixture}" | jq -c '.writes[0].labels'
      ;;
    update-failed)
      jq -c '.' "${labels_fixture}"
      ;;
    *)
      echo "simulate_atomic_label_update: unknown outcome '${outcome}'" >&2
      return 2
      ;;
  esac
}

label_transition_action() {
  local read_outcome="$1"
  local update_outcome="$2"

  if [ "${read_outcome}" = "auth" ] || [ "${update_outcome}" = "auth" ]; then
    printf 'auth-abort\n'
  elif [ "${read_outcome}" != "ok" ] || [ "${update_outcome}" != "ok" ]; then
    printf 'abort\n'
  else
    printf 'complete\n'
  fi
}

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

format_duration_seconds() {
  local duration_seconds="${1:-}"

  if [ -z "${duration_seconds}" ] || [ "${duration_seconds}" = "null" ]; then
    printf 'duration unknown'
    return
  fi

  printf '%dm%02ds' "$((duration_seconds / 60))" "$((duration_seconds % 60))"
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
  local run_id
  local run_wall_clock_seconds

  batch_date="$(jq -r '.batch_date' "${batch_fixture}")"
  source_pr_count="$(jq '[.prs[] | select(.outcome != "github_auth")] | length' "${batch_fixture}")"
  candidate_count="$(jq '[.prs[] | .candidate_results[]?] | length' "${batch_fixture}")"
  accepted_count="$(jq '[.entries[] | select(.status == "accepted")] | length' "${changeset_file}")"
  accepted_facts="$(jq '[.entries[] | select(.status == "accepted" and .data.type == "fact")] | length' "${changeset_file}")"
  accepted_antipatterns="$(jq '[.entries[] | select(.status == "accepted" and .data.type == "anti-pattern")] | length' "${changeset_file}")"
  rejected_count="$(jq '[.prs[] | .candidate_results[]? | select(.verdict.verdict == "fail")] | length' "${batch_fixture}")"
  insufficient_count="$(jq '[.prs[] | select(.outcome == "insufficient")] | length' "${batch_fixture}")"
  run_id="$(jq -r '.run_id' "${batch_fixture}")"
  run_wall_clock_seconds="$(jq -r '.run_wall_clock_seconds // empty' "${batch_fixture}")"

  {
    printf '## Knowledge Distillery Batch Report — %s\n\n' "${batch_date}"
    printf '### 진행 상황\n\n'
    printf '| 항목 | 상태 |\n'
    printf '|------|------|\n'
    while IFS= read -r pr; do
      local pr_number
      local outcome
      local duration
      pr_number="$(jq -r '.number' <<<"${pr}")"
      outcome="$(jq -r '.outcome' <<<"${pr}")"
      duration="$(format_duration_seconds "$(jq -r '.duration_seconds // empty' <<<"${pr}")")"

      case "${outcome}" in
        processed)
          local pr_accepted_count
          pr_accepted_count="$(jq '[.candidate_results[]? | select(.verdict.verdict == "pass")] | length' <<<"${pr}")"
          printf '| #%s | ✅ 처리 완료 (%s accepted, %s, run #%s) |\n' \
            "${pr_number}" "${pr_accepted_count}" "${duration}" "${run_id}"
          ;;
        insufficient)
          local missing
          missing="$(jq -r '.missing | join(", ")' <<<"${pr}")"
          printf '| #%s | ⏸ 대기 중 (insufficient: %s, %s, run #%s) |\n' \
            "${pr_number}" "${missing}" "${duration}" "${run_id}"
          ;;
        failed)
          local error
          error="$(jq -r '.error' <<<"${pr}")"
          printf '| #%s | ❌ failed: %s (%s, run #%s) |\n' \
            "${pr_number}" "${error}" "${duration}" "${run_id}"
          ;;
        github_auth)
          ;;
      esac
    done < <(jq -c '.prs[]' "${batch_fixture}")
    printf '\n'

    printf '### Summary\n'
    printf '| Metric | Value |\n'
    printf '|--------|-------|\n'
    printf '| Source PRs processed | %s |\n' "${source_pr_count}"
    printf '| Candidates extracted | %s |\n' "${candidate_count}"
    printf '| Accepted (fact / anti-pattern) | %s (%s / %s) |\n' "${accepted_count}" "${accepted_facts}" "${accepted_antipatterns}"
    printf '| Rejected | %s |\n' "${rejected_count}"
    printf '| Insufficient evidence (deferred) | %s |\n' "${insufficient_count}"
    if [ -n "${run_wall_clock_seconds}" ]; then
      printf '| 총 소요시간(wall-clock) | %s (run #%s) |\n\n' \
        "$(format_duration_seconds "${run_wall_clock_seconds}")" "${run_id}"
    else
      printf '| 총 소요시간(wall-clock) | N/A (run #%s) |\n\n' "${run_id}"
    fi

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
      | select(.outcome != "github_auth")
      | (
          (if .outcome == "processed" then
             "- #\(.number) \"\(.title)\": processed, \([.candidate_results[]? | select(.verdict.verdict == "pass")] | length) accepted, \([.candidate_results[]? | select(.verdict.verdict == "fail")] | length) rejected."
           elif .outcome == "insufficient" then
             "- #\(.number) \"\(.title)\": insufficient evidence, deferred."
           else
             "- #\(.number) \"\(.title)\": failed during refinement (\(.error))."
           end),
          "<!-- KD_BATCH_PR_META \({pr_number: .number, changed_files: (.changed_files // [])} | tojson) -->"
        )
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
