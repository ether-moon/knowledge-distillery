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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_DIR="${TMP_DIR}/repo"
mkdir -p "${REPO_DIR}/.knowledge/reports" "${REPO_DIR}/.github/workflows"

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
EOF

touch "${REPO_DIR}/.github/workflows/mark-evidence.yml"
touch "${REPO_DIR}/.github/workflows/batch-refine.yml"

export KNOWLEDGE_VAULT_PATH="${REPO_DIR}/.knowledge/vault.db"
"${GATE}" init-db

"${GATE}" domain-add zebra "Zebra domain" >/dev/null
"${GATE}" domain-add alpha "Alpha domain" >/dev/null
"${GATE}" domain-add sunset "Deprecated domain" >/dev/null
"${GATE}" domain-deprecate sunset >/dev/null

ids_only="$("${GATE}" domain-list --ids-only)"
assert_eq '["alpha","zebra"]' "${ids_only}" "domain-list --ids-only should return sorted active domain IDs"

all_ids="$("${GATE}" domain-list --status all --ids-only)"
assert_eq '["alpha","zebra","sunset"]' "${all_ids}" "domain-list --status all --ids-only should include deprecated domains in order"

doctor_output="$(cd "${REPO_DIR}" && "${GATE}" doctor)"
assert_contains "${doctor_output}" "PASS  AGENTS.md contains the Knowledge Vault section" "doctor should respect CLAUDE.md delegation to AGENTS.md"

help_output="$("${GATE}" help)"
assert_contains "${help_output}" "domain-list [--status X] [--ids-only]" "help should document the lightweight domain index flag"

echo "knowledge-gate tests passed"
