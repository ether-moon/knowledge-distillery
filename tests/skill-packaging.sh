#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE_SKILL="${ROOT}/plugins/knowledge-distillery/skills/knowledge-gate"
GATE="${GATE_SKILL}/scripts/knowledge-gate"
SETUP_SKILL="${ROOT}/plugins/knowledge-distillery/skills/setup"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_file() {
  local path="$1"
  local message="$2"
  if [ ! -f "$path" ]; then
    fail "${message}: missing ${path}"
  fi
}

assert_not_exists() {
  local path="$1"
  local message="$2"
  if [ -e "$path" ]; then
    fail "${message}: unexpectedly found ${path}"
  fi
}

assert_file "${GATE}" "knowledge-gate CLI should be bundled with its skill"
assert_file "${GATE_SKILL}/assets/schema/vault.sql" "knowledge-gate schema should be bundled as a skill asset"
assert_not_exists "${ROOT}/plugins/knowledge-distillery/scripts/knowledge-gate" "plugin-root CLI should not be required"
assert_not_exists "${ROOT}/plugins/knowledge-distillery/schema/vault.sql" "plugin-root schema should not be required"
assert_not_exists "${ROOT}/plugins/knowledge-distillery/hooks/hooks.json" "plugin hooks should be installed by setup instead of auto-loaded"

for workflow_name in \
  mark-evidence.yml \
  batch-refine.yml \
  curate-report.yml \
  apply-changeset.yml
do
  assert_file "${SETUP_SKILL}/assets/workflows/${workflow_name}" "setup should bundle ${workflow_name}"
  if ! cmp -s \
    "${ROOT}/.github/workflows/${workflow_name}" \
    "${SETUP_SKILL}/assets/workflows/${workflow_name}"
  then
    fail "setup workflow asset should match the dogfood workflow: ${workflow_name}"
  fi
done

if [ "$(wc -l < "${GATE_SKILL}/SKILL.md")" -gt 200 ]; then
  fail "knowledge-gate SKILL.md should stay within the progressive-disclosure target"
fi

if [ "$(wc -l < "${SETUP_SKILL}/SKILL.md")" -gt 200 ]; then
  fail "setup SKILL.md should stay within the progressive-disclosure target"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INSTALLED_SKILL="${TMP_DIR}/knowledge-gate"
cp -R "${GATE_SKILL}" "${INSTALLED_SKILL}"

export KNOWLEDGE_VAULT_PATH="${TMP_DIR}/project/.knowledge/vault.db"
mkdir -p "$(dirname "${KNOWLEDGE_VAULT_PATH}")"

"${INSTALLED_SKILL}/scripts/knowledge-gate" init-db

schema_version="$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" 'PRAGMA user_version;')"
if [ "${schema_version}" -lt 1 ]; then
  fail "standalone skill copy should initialize a versioned vault"
fi

table_count="$(sqlite3 "${KNOWLEDGE_VAULT_PATH}" \
  "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('entries','entry_domains','domain_registry','domain_paths','evidence');")"
if [ "${table_count}" != "5" ]; then
  fail "standalone skill copy should initialize all vault tables"
fi

echo "skill packaging tests passed"
