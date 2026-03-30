#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="${ROOT}/plugins/knowledge-distillery/scripts/knowledge-gate"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$expected" != "$actual" ]; then
    fail "${message}: expected '${expected}', got '${actual}'"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${message}: missing '${needle}'"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "${message}: unexpectedly found '${needle}'"
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_DIR="${TMP_DIR}/repo"
mkdir -p \
  "${REPO_DIR}/.knowledge/reports" \
  "${REPO_DIR}/.github/workflows" \
  "${REPO_DIR}/app/services/payment" \
  "${REPO_DIR}/app/ui" \
  "${REPO_DIR}/app/ops" \
  "${REPO_DIR}/legacy/ui" \
  "${REPO_DIR}/src/bulk" \
  "${REPO_DIR}/src/tiny" \
  "${REPO_DIR}/docs/missing"

git -C "$TMP_DIR" init -q repo

cat > "${REPO_DIR}/CLAUDE.md" <<'EOF'
@AGENTS.md
EOF

cat > "${REPO_DIR}/AGENTS.md" <<'EOF'
## Knowledge Vault
- Query the vault before code changes.
EOF

cat > "${REPO_DIR}/.gitignore" <<'EOF'
.knowledge/tmp/
tmp/
EOF

touch "${REPO_DIR}/.github/workflows/mark-evidence.yml"
touch "${REPO_DIR}/.github/workflows/batch-refine.yml"

cat > "${REPO_DIR}/.github/workflows/apply-changeset.yml" <<'APPLY_EOF'
name: Apply Changeset
on:
  pull_request:
    types: [closed]
jobs:
  apply:
    runs-on: ubuntu-latest
    steps:
      - name: Extract batch date
        run: |
          if [[ ! "$BRANCH" =~ ^knowledge/batch-([0-9]{4}-[0-9]{2}-[0-9]{2})(-[0-9]+)?$ ]]; then
            exit 1
          fi
          DATE="${BASH_REMATCH[1]}"
      - name: Clean up batch artifacts
        run: echo "cleanup"
APPLY_EOF
touch "${REPO_DIR}/app/services/payment/orchestrator.rb"
touch "${REPO_DIR}/app/ui/button.tsx"
touch "${REPO_DIR}/app/ops/sync.rb"
touch "${REPO_DIR}/legacy/ui/controller.rb"
touch "${REPO_DIR}/src/tiny/rule.txt"
touch "${REPO_DIR}/docs/missing/a.md"
touch "${REPO_DIR}/docs/missing/b.md"
touch "${REPO_DIR}/docs/missing/c.md"

for i in $(seq 1 16); do
  touch "${REPO_DIR}/src/bulk/rule-${i}.txt"
done

git -C "${REPO_DIR}" add .

export KNOWLEDGE_VAULT_PATH="${REPO_DIR}/.knowledge/vault.db"
"${GATE}" init-db

if existing_output=$("${GATE}" init-db "${KNOWLEDGE_VAULT_PATH}" 2>&1); then
  fail "init-db should fail when the target already exists"
fi
assert_contains "${existing_output}" "Knowledge vault already exists" "init-db should reject existing targets"

"${GATE}" domain-add global "Global rules" >/dev/null
"${GATE}" domain-add payment "Payment domain" >/dev/null
"${GATE}" domain-add ui "UI domain" >/dev/null
"${GATE}" domain-add legacy "Legacy UI domain" >/dev/null
"${GATE}" domain-add bulk "Bulk rules domain" >/dev/null
"${GATE}" domain-add tiny "Tiny domain" >/dev/null
"${GATE}" domain-add orphan "Orphan domain" >/dev/null
"${GATE}" domain-add ops "Ops domain" >/dev/null
"${GATE}" domain-add src-all "Broad src domain" >/dev/null
"${GATE}" domain-add sunset "Deprecated domain" >/dev/null

"${GATE}" domain-paths-set global "*" >/dev/null
"${GATE}" domain-paths-set payment "app/services/payment/" >/dev/null
"${GATE}" domain-paths-set ui "app/ui/" "docs/ui/" >/dev/null
"${GATE}" domain-paths-set legacy "legacy/ui/" >/dev/null
"${GATE}" domain-paths-set bulk "src/bulk/" >/dev/null
"${GATE}" domain-paths-set tiny "src/tiny/" >/dev/null
"${GATE}" domain-paths-set ops "app/ops/" >/dev/null
"${GATE}" domain-paths-set src-all "src/" >/dev/null

if invalid_pattern_output=$("${GATE}" domain-paths-add payment "app/services/payment" 2>&1); then
  fail "domain-paths-add should reject invalid patterns"
fi
assert_contains "${invalid_pattern_output}" "Invalid pattern" "invalid patterns should explain the directory-prefix contract"

"${GATE}" domain-paths-add ui "docs/components/" >/dev/null
resolve_components="$("${GATE}" domain-resolve-path "docs/components/button.tsx")"
assert_contains "${resolve_components}" '"domain":"ui"' "domain-paths-add should make the new path resolvable"
"${GATE}" domain-paths-remove ui "docs/components/" >/dev/null
resolve_after_remove="$("${GATE}" domain-resolve-path "docs/components/button.tsx")"
assert_not_contains "${resolve_after_remove}" '"domain":"ui"' "domain-paths-remove should stop matching removed patterns"

"${GATE}" domain-deprecate sunset >/dev/null
ids_only="$("${GATE}" domain-list --ids-only)"
assert_eq '["bulk","global","legacy","ops","orphan","payment","src-all","tiny","ui"]' "${ids_only}" "domain-list --ids-only should return sorted active domain IDs"

all_ids="$("${GATE}" domain-list --status all --ids-only)"
assert_eq '["bulk","global","legacy","ops","orphan","payment","src-all","tiny","ui","sunset"]' "${all_ids}" "domain-list --status all --ids-only should include deprecated domains in order"

payment_info="$("${GATE}" domain-info payment)"
assert_contains "${payment_info}" '"patterns":"app/services/payment/"' "domain-info should include path mappings"
assert_contains "${payment_info}" '"status":"active"' "domain-info should include the current domain status"

payment_entry_id="$("${GATE}" add \
  --type fact \
  --title "Service Rule" \
  --claim "Use Service Objects for payment orchestration." \
  --body "## Background\nPayments need explicit orchestration.\n\n## Details\nService Objects coordinate retries and external APIs." \
  --domain payment \
  --considerations "Re-evaluate if orchestration moves to events." \
  --evidence "pr:#1234")"
assert_eq "service-rule" "${payment_entry_id}" "add should generate kebab-case IDs from titles"

ui_entry_id="$("${GATE}" add \
  --type anti-pattern \
  --title "Callback Ban" \
  --claim "MUST-NOT call external APIs from callbacks." \
  --body "## Background\nCallbacks caused retry storms.\n\n## Details\nUse explicit service boundaries.\n\n## Rejected Alternatives\nRetrying inside callbacks kept failing." \
  --alternative "Use service objects or jobs." \
  --domain ui \
  --considerations "Re-evaluate if callback isolation changes." \
  --evidence "pr:#1235")"
assert_eq "callback-ban" "${ui_entry_id}" "add should create anti-pattern entries"

"${GATE}" add \
  --type fact \
  --title "Global Convention" \
  --claim "Document global conventions before broad refactors." \
  --body "## Background\nGlobal conventions avoid repeated churn.\n\n## Details\nCapture cross-cutting rules early." \
  --domain global \
  --considerations "Re-evaluate when conventions change." \
  --evidence "pr:#1236" >/dev/null

"${GATE}" add \
  --type fact \
  --title "Tiny Rule" \
  --claim "Keep tiny-domain examples concise." \
  --body "## Background\nTiny examples exist for docs.\n\n## Details\nKeep them focused." \
  --domain tiny \
  --considerations "Re-evaluate if tiny grows into a larger module." \
  --evidence "pr:#1237" >/dev/null

"${GATE}" add \
  --type fact \
  --title "Ops Rule" \
  --claim "Keep ops synchronization scripts explicit." \
  --body "## Background\nOps scripts need clear checkpoints.\n\n## Details\nAvoid hidden side effects." \
  --domain ops \
  --considerations "Re-evaluate if ops automation changes." \
  --evidence "pr:#1238" >/dev/null

"${GATE}" add \
  --type fact \
  --title "Legacy Rule" \
  --claim "Document legacy UI edge cases before replacement." \
  --body "## Background\nLegacy UI behavior is still referenced.\n\n## Details\nCapture edge cases before migration." \
  --domain legacy \
  --considerations "Remove once the legacy UI disappears." \
  --evidence "pr:#1239" >/dev/null

for i in $(seq 1 16); do
  "${GATE}" add \
    --type fact \
    --title "Bulk Rule ${i}" \
    --claim "Track bulk rule ${i} explicitly." \
    --body "## Background\nBulk rules populate the split-candidate report.\n\n## Details\nRule ${i} remains active." \
    --domain bulk \
    --considerations "Bulk rule ${i} can be revisited later." \
    --evidence "pr:#20${i}" >/dev/null
done

list_output="$("${GATE}" list)"
assert_eq "22" "$(echo "${list_output}" | jq 'length')" "list should return every active entry"
assert_contains "${list_output}" '"id":"service-rule"' "list should include added fact entries"
assert_contains "${list_output}" '"id":"callback-ban"' "list should include added anti-pattern entries"

payment_query="$("${GATE}" query-domain payment)"
assert_contains "${payment_query}" '"id":"service-rule"' "query-domain should return entries for the requested domain"
assert_contains "${payment_query}" '"title":"Service Rule"' "query-domain should expose lightweight summary fields"
assert_not_contains "${payment_query}" '"id":"callback-ban"' "query-domain should not leak unrelated domains"
assert_not_contains "${payment_query}" '"body":' "query-domain should stay in summary mode by default"

payment_query_ids="$("${GATE}" query-domain --ids-only payment)"
assert_eq '["service-rule"]' "${payment_query_ids}" "query-domain --ids-only should emit only matching entry IDs"

path_query="$("${GATE}" query-paths "app/services/payment/orchestrator.rb")"
assert_contains "${path_query}" '"id":"service-rule"' "query-paths should include domain-matched entries"
assert_contains "${path_query}" '"id":"global-convention"' "query-paths should include global entries"
assert_not_contains "${path_query}" '"id":"callback-ban"' "query-paths should exclude non-matching domains"

path_query_ids="$(echo "$("${GATE}" query-paths --ids-only "app/services/payment/orchestrator.rb")" | jq -c 'sort')"
assert_eq '["global-convention","service-rule"]' "${path_query_ids}" "query-paths --ids-only should emit just the matching entry IDs"

search_output="$("${GATE}" search callback)"
assert_contains "${search_output}" '"id":"callback-ban"' "search should use FTS over active entries"
assert_contains "${search_output}" '"title":"Callback Ban"' "search should expose lightweight summary fields"
assert_not_contains "${search_output}" '"body":' "search should stay in summary mode by default"

search_ids="$("${GATE}" search --ids-only callback)"
assert_eq '["callback-ban"]' "${search_ids}" "search --ids-only should emit ranked matching entry IDs"

entry_output="$("${GATE}" get service-rule)"
assert_eq "payment" "$(echo "${entry_output}" | jq -r '.[0].domains[0]')" "get should enrich entries with domains"
assert_eq "#1234" "$(echo "${entry_output}" | jq -r '.[0].evidence[0].ref')" "get should enrich entries with evidence"
assert_contains "$(echo "${entry_output}" | jq -r '.[0].body')" "## Background" "get should include the full body"

multi_entry_output="$("${GATE}" get-many global-convention service-rule)"
assert_eq "global-convention" "$(echo "${multi_entry_output}" | jq -r '.[0].id')" "get-many should preserve requested ID order"
assert_eq "service-rule" "$(echo "${multi_entry_output}" | jq -r '.[1].id')" "get-many should include later requested entries"
assert_eq "global" "$(echo "${multi_entry_output}" | jq -r '.[0].domains[0]')" "get-many should enrich each entry with domains"
assert_eq "#1234" "$(echo "${multi_entry_output}" | jq -r '.[1].evidence[0].ref')" "get-many should enrich each entry with evidence"
assert_contains "$(echo "${multi_entry_output}" | jq -r '.[1].body')" "## Background" "get-many should include the full body for each entry"

list_ids="$(echo "$("${GATE}" list --ids-only)" | jq -c 'sort')"
assert_eq "22" "$(echo "${list_ids}" | jq 'length')" "list --ids-only should emit every active entry ID"
assert_contains "${list_ids}" '"service-rule"' "list --ids-only should include fact IDs"
assert_contains "${list_ids}" '"callback-ban"' "list --ids-only should include anti-pattern IDs"

"${GATE}" domain-merge ui payment >/dev/null
merged_info="$("${GATE}" domain-info ui)"
assert_contains "${merged_info}" '"status":"deprecated"' "domain-merge should deprecate the source domain"
payment_after_merge="$("${GATE}" query-domain payment)"
assert_contains "${payment_after_merge}" '"id":"callback-ban"' "domain-merge should transfer source entries into the target domain"
payment_domain_info="$("${GATE}" domain-info payment)"
assert_contains "${payment_domain_info}" 'docs/ui/' "domain-merge should transfer path mappings"

if deprecate_payment_output=$("${GATE}" domain-deprecate payment 2>&1); then
  fail "domain-deprecate should refuse active domains without merge target"
fi
assert_contains "${deprecate_payment_output}" "active entries" "domain-deprecate should explain why active domains cannot be deprecated"

"${GATE}" domain-deprecate legacy --merge-into payment >/dev/null
legacy_info="$("${GATE}" domain-info legacy)"
assert_contains "${legacy_info}" '"status":"deprecated"' "domain-deprecate --merge-into should delegate to domain-merge"
payment_after_legacy_merge="$("${GATE}" query-domain payment)"
assert_contains "${payment_after_legacy_merge}" '"id":"legacy-rule"' "domain-deprecate --merge-into should transfer entry ownership"

"${GATE}" domain-split ops ops-core "Ops core rules" ops-edge "Ops edge rules" >/dev/null
ops_core_info="$("${GATE}" domain-info ops-core)"
ops_edge_info="$("${GATE}" domain-info ops-edge)"
ops_info="$("${GATE}" domain-info ops)"
assert_contains "${ops_core_info}" '"status":"active"' "domain-split should create the first target domain"
assert_contains "${ops_edge_info}" '"status":"active"' "domain-split should create the second target domain"
assert_contains "${ops_info}" '"status":"deprecated"' "domain-split should deprecate the source domain"
assert_eq "2" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT COUNT(*) FROM entry_domains WHERE entry_id = 'ops-rule' AND domain IN ('ops-core', 'ops-edge');")" "domain-split should attach source entries to both target domains"
assert_eq "0" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT COUNT(*) FROM domain_paths WHERE domain = 'ops';")" "domain-split should clear source path mappings"

invalid_pipeline_json='[
  {
    "id": "invalid-entry",
    "type": "fact",
    "title": "Invalid Entry",
    "claim": "Missing evidence should fail.",
    "body": "## Background\nNo evidence.\n\n## Details\nThis should be rejected.",
    "considerations": "Missing evidence should fail.",
    "applies_to": {"domains": ["payment"]},
    "evidence": []
  }
]'
if invalid_pipeline_output=$(printf '%s' "${invalid_pipeline_json}" | "${GATE}" _pipeline-insert 2>&1); then
  fail "_pipeline-insert should reject entries without evidence"
fi
assert_contains "${invalid_pipeline_output}" "has no evidence" "_pipeline-insert should validate evidence"

valid_pipeline_json='[
  {
    "id": "service-rule",
    "type": "fact",
    "title": "Service Rule Followup",
    "claim": "Use service-rule followups for handoff notes.",
    "body": "## Background\nFollowup notes reduce drift.\n\n## Details\nCapture handoff notes with the service rule.",
    "alternative": null,
    "considerations": "Re-evaluate if handoff notes are automated.",
    "applies_to": {"domains": ["new-auto"]},
    "evidence": [{"type": "pr", "ref": "#1240"}],
    "_proposed_domain": [{"name": "new-auto", "description": "Auto-created pipeline domain", "suggested_patterns": ["app/new-auto/"]}],
    "curation": [{"related_id": "service-rule", "reason": "Potential overlap with the original service rule."}]
  },
  {
    "id": "queue-rule",
    "type": "anti-pattern",
    "title": "Queue Rule",
    "claim": "MUST-NOT enqueue retries from callbacks.",
    "body": "## Background\nCallback retries masked failures.\n\n## Details\nQueue retries from explicit services.\n\n## Rejected Alternatives\nCallback retries were too implicit.",
    "alternative": "Move retries to explicit service-layer jobs.",
    "considerations": "Re-evaluate if callback execution becomes transactional.",
    "applies_to": {"domains": ["payment"]},
    "evidence": [{"type": "pr", "ref": "#1241"}]
  }
]'
pipeline_output="$(printf '%s' "${valid_pipeline_json}" | "${GATE}" _pipeline-insert)"
assert_contains "${pipeline_output}" "Inserted 2 entries" "_pipeline-insert should insert valid batches"
assert_eq "1" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT COUNT(*) FROM entries WHERE id = 'service-rule-2';")" "_pipeline-insert should uniquify colliding IDs"
assert_eq "Auto-created pipeline domain" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT description FROM domain_registry WHERE domain = 'new-auto';")" "_pipeline-insert should auto-create proposed domains"
assert_eq "1" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT COUNT(*) FROM domain_paths WHERE domain = 'new-auto' AND pattern = 'app/new-auto/';")" "_pipeline-insert should apply proposed path mappings"
assert_eq "1" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT COUNT(*) FROM curation_queue WHERE entry_id = 'service-rule-2' AND related_id = 'service-rule' AND status = 'pending';")" "_pipeline-insert should create curation queue entries"

update_output="$(printf '%s' '{"title":"Queue Rule Updated","claim":"MUST-NOT enqueue retries from callbacks or observers.","domains":["payment","new-auto"]}' | "${GATE}" _pipeline-update queue-rule)"
assert_contains "${update_output}" "Updated queue-rule" "_pipeline-update should modify active entries"
updated_queue="$(echo "$("${GATE}" get queue-rule)" | jq -r '.[0].title')"
assert_eq "Queue Rule Updated" "${updated_queue}" "_pipeline-update should change scalar fields"
assert_eq "2" "$(echo "$("${GATE}" get queue-rule)" | jq '.[0].domains | length')" "_pipeline-update should replace domains"

if remove_alt_output=$(printf '%s' '{"alternative":""}' | "${GATE}" _pipeline-update callback-ban 2>&1); then
  fail "_pipeline-update should block removing alternatives from anti-patterns"
fi
assert_contains "${remove_alt_output}" "Cannot remove alternative from anti-pattern" "_pipeline-update should preserve anti-pattern alternatives"

archive_output="$("${GATE}" _pipeline-archive service-rule --reason "Replaced by followup rule.")"
assert_contains "${archive_output}" "Archived service-rule" "_pipeline-archive should archive active entries"
if archive_again_output=$("${GATE}" _pipeline-archive service-rule --reason "duplicate" 2>&1); then
  fail "_pipeline-archive should reject already archived entries"
fi
assert_contains "${archive_again_output}" "already archived" "_pipeline-archive should report archived entries"
if update_archived_output=$(printf '%s' '{"title":"Archived"}' | "${GATE}" _pipeline-update service-rule 2>&1); then
  fail "_pipeline-update should reject archived entries"
fi
assert_contains "${update_archived_output}" "is archived" "_pipeline-update should block archived entries"
post_archive_list="$("${GATE}" list)"
assert_not_contains "${post_archive_list}" '"id":"service-rule"' "list should exclude archived entries"

cat > "${TMP_DIR}/changeset-invalid.json" <<'EOF'
{"version":2,"entries":[]}
EOF
if invalid_changeset_output=$("${GATE}" _changeset-apply "${TMP_DIR}/changeset-invalid.json" 2>&1); then
  fail "_changeset-apply should reject unsupported versions"
fi
assert_contains "${invalid_changeset_output}" "Unsupported or missing changeset version" "_changeset-apply should validate changeset versions"

cat > "${TMP_DIR}/changeset-empty.json" <<'EOF'
{"version":1,"batch_date":"2026-04-01","entries":[{"status":"rejected","data":{"id":"ignored"}}]}
EOF
empty_changeset_output="$("${GATE}" _changeset-apply "${TMP_DIR}/changeset-empty.json")"
assert_contains "${empty_changeset_output}" "No accepted entries to apply" "_changeset-apply should no-op when nothing is accepted"

cat > "${TMP_DIR}/changeset-apply.json" <<'EOF'
{
  "version": 1,
  "batch_date": "2026-04-02",
  "entries": [
    {
      "status": "accepted",
      "data": {
        "id": "service-rule-2",
        "type": "fact",
        "title": "Already Present",
        "claim": "Should be skipped because it already exists.",
        "body": "## Background\nExisting entry.\n\n## Details\nSkip it.",
        "alternative": null,
        "considerations": "Existing entry.",
        "applies_to": {"domains": ["new-auto"]},
        "evidence": [{"type": "pr", "ref": "#1242"}]
      }
    },
    {
      "status": "accepted",
      "data": {
        "id": "changeset-rule",
        "type": "fact",
        "title": "Changeset Rule",
        "claim": "Apply accepted changeset entries through the CLI.",
        "body": "## Background\nChangesets defer vault writes until merge.\n\n## Details\nOnly accepted entries should be inserted.",
        "alternative": null,
        "considerations": "Re-evaluate if merge-time behavior changes.",
        "applies_to": {"domains": ["changeset-auto"]},
        "evidence": [{"type": "pr", "ref": "#1243"}],
        "_proposed_domain": [{"name": "changeset-auto", "description": "Changeset-created domain", "suggested_patterns": ["app/changeset/"]}],
        "curation": [{"related_id": "service-rule-2", "reason": "Needs human review against service-rule-2."}]
      }
    },
    {
      "status": "rejected",
      "data": {
        "id": "ignored-rule",
        "type": "fact",
        "title": "Ignored Rule",
        "claim": "Rejected changeset entries should not be inserted.",
        "body": "## Background\nRejected.\n\n## Details\nIgnore me.",
        "alternative": null,
        "considerations": "Rejected.",
        "applies_to": {"domains": ["payment"]},
        "evidence": [{"type": "pr", "ref": "#1244"}]
      }
    }
  ]
}
EOF
changeset_apply_output="$("${GATE}" _changeset-apply "${TMP_DIR}/changeset-apply.json")"
assert_contains "${changeset_apply_output}" "Skipped 1 entries already in vault" "_changeset-apply should skip existing IDs"
assert_contains "${changeset_apply_output}" "Inserted 1 entries" "_changeset-apply should insert only new accepted entries"
assert_eq "1" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT COUNT(*) FROM entries WHERE id = 'changeset-rule';")" "_changeset-apply should insert accepted entries"
assert_eq "0" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT COUNT(*) FROM entries WHERE id = 'ignored-rule';")" "_changeset-apply should ignore rejected entries"
assert_eq "1" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT COUNT(*) FROM domain_paths WHERE domain = 'changeset-auto' AND pattern = 'app/changeset/';")" "_changeset-apply should create proposed domain mappings"
assert_eq "1" "$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" "SELECT COUNT(*) FROM curation_queue WHERE entry_id = 'changeset-rule' AND related_id = 'service-rule-2' AND status = 'pending';")" "_changeset-apply should preserve curation entries"

curate_output="$(printf 'quit\n' | "${GATE}" curate)"
assert_contains "${curate_output}" "Curation Queue: 2 pending items" "curate should list pending curation items"
assert_contains "${curate_output}" "Action? [keep-both / keep-existing / keep-new / archive-both / skip / quit]" "curate should prompt for resolution actions"
sqlite3 "${KNOWLEDGE_VAULT_PATH}" "UPDATE curation_queue SET status = 'resolved', resolved_at = datetime('now') WHERE status = 'pending';"
no_pending_output="$("${GATE}" curate)"
assert_contains "${no_pending_output}" "No pending curation items." "curate should no-op when the queue is empty"

sqlite3 "${KNOWLEDGE_VAULT_PATH}" "
  UPDATE domain_registry
  SET created_at = datetime('now', '-40 days')
  WHERE domain IN ('orphan', 'tiny');
"

domain_report_output="$(cd "${REPO_DIR}" && "${GATE}" domain-report)"
assert_contains "${domain_report_output}" "bulk -- 16 entries" "domain-report should flag split candidates"
assert_contains "${domain_report_output}" "tiny -- 1 entries" "domain-report should flag merge candidates"
assert_contains "${domain_report_output}" "orphan -- created" "domain-report should flag orphan domains"
assert_contains "${domain_report_output}" "Broadest pattern: src/" "domain-report should warn about broad path patterns"
assert_contains "${domain_report_output}" "docs/missing/ -- no domain mapping" "domain-report should surface structural mismatches"

doctor_output="$(cd "${REPO_DIR}" && "${GATE}" doctor)"
assert_contains "${doctor_output}" "PASS  AGENTS.md contains the Knowledge Vault section" "doctor should respect CLAUDE.md delegation to AGENTS.md"
assert_contains "${doctor_output}" "PASS  batch-refine workflow exists" "doctor should verify workflow adoption"
assert_contains "${doctor_output}" "Summary: 12 passed, 0 failed" "doctor should pass in the fully configured fixture repo"

BAD_REPO="${TMP_DIR}/bad-repo"
mkdir -p "${BAD_REPO}/.knowledge"
git -C "${TMP_DIR}" init -q bad-repo
cat > "${BAD_REPO}/AGENTS.md" <<'EOF'
No vault section here.
EOF
export KNOWLEDGE_VAULT_PATH="${BAD_REPO}/.knowledge/vault.db"
"${GATE}" init-db >/dev/null
if bad_doctor_output="$(cd "${BAD_REPO}" && "${GATE}" doctor 2>&1)"; then
  fail "doctor should fail for incomplete repository adoption"
fi
assert_contains "${bad_doctor_output}" "FAIL  Directive file is missing the Knowledge Vault section" "doctor should fail when the directive file is incomplete"
assert_contains "${bad_doctor_output}" "FAIL  .knowledge/reports is missing" "doctor should fail when required directories are absent"

export KNOWLEDGE_VAULT_PATH="${REPO_DIR}/.knowledge/vault.db"
migrate_output="$("${GATE}" migrate)"
assert_contains "${migrate_output}" "Already at version" "migrate should no-op cleanly when no migrations apply"

help_output="$("${GATE}" help)"
assert_contains "${help_output}" "query-domain [--ids-only] <domain>" "help should document lightweight entry indexes"
assert_contains "${help_output}" "get-many <id>..." "help should document batch detail retrieval"
assert_contains "${help_output}" "domain-list [--status X] [--ids-only]" "help should document lightweight domain indexes"
assert_contains "${help_output}" "_pipeline-update <id>" "help should document pipeline update"

if unknown_output=$("${GATE}" does-not-exist 2>&1); then
  fail "unknown commands should fail"
fi
assert_contains "${unknown_output}" "Unknown command" "unknown commands should print usage guidance"

echo "knowledge-gate tests passed"
