#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE_SKILL="${ROOT}/plugins/knowledge-distillery/skills/knowledge-gate"
GATE="${GATE_SKILL}/scripts/knowledge-gate"
INSTALL_ROOT="${ROOT}/plugins/knowledge-distillery/install"
README="${ROOT}/README.md"
INSTALL_GUIDE="${ROOT}/docs/agent-installation.md"

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

assert_file_contains() {
  local path="$1"
  local needle="$2"
  local message="$3"
  if ! grep -Fq -- "$needle" "$path"; then
    fail "${message}: missing '${needle}' in ${path}"
  fi
}

assert_file_not_contains() {
  local path="$1"
  local needle="$2"
  local message="$3"
  if grep -Fq -- "$needle" "$path"; then
    fail "${message}: unexpectedly found '${needle}' in ${path}"
  fi
}

assert_file "${GATE}" "knowledge-gate CLI should be bundled with its skill"
assert_file "${GATE_SKILL}/assets/schema/vault.sql" "knowledge-gate schema should be bundled as a skill asset"
assert_not_exists "${ROOT}/plugins/knowledge-distillery/scripts/knowledge-gate" "plugin-root CLI should not be required"
assert_not_exists "${ROOT}/plugins/knowledge-distillery/schema/vault.sql" "plugin-root schema should not be required"
assert_not_exists "${ROOT}/plugins/knowledge-distillery/hooks/hooks.json" "plugin hooks should be installed from README assets instead of auto-loaded"
assert_not_exists "${ROOT}/plugins/knowledge-distillery/skills/setup/SKILL.md" "README should replace the persistent setup skill"
assert_not_exists "${ROOT}/plugins/knowledge-distillery/skills/setup/scripts/install-hooks" "README should replace the bootstrap installer"
assert_file "${INSTALL_GUIDE}" "repository should publish the agent installation contract"

for runtime_skill in knowledge-gate memento-commit memento-summary record-decision
do
  assert_file \
    "${ROOT}/plugins/knowledge-distillery/skills/${runtime_skill}/SKILL.md" \
    "installation-guide-selected runtime skill should be packaged: ${runtime_skill}"
done

assert_file_contains \
  "${README}" \
  'docs/agent-installation.md' \
  "README should link the agent installation contract"
assert_file_not_contains \
  "${README}" \
  'npx skills add' \
  "README should not inline the installation procedure"
assert_file_contains \
  "${INSTALL_GUIDE}" \
  '--skill knowledge-gate --skill memento-commit' \
  "installation guide should install only the first pair of runtime skills"
assert_file_contains \
  "${INSTALL_GUIDE}" \
  '--skill memento-summary --skill record-decision' \
  "installation guide should install only the second pair of runtime skills"
assert_file_contains \
  "${INSTALL_GUIDE}" \
  'Do not install `setup`' \
  "installation guide should replace the setup skill"

for workflow_name in \
  mark-evidence.yml \
  batch-refine.yml \
  curate-report.yml \
  apply-changeset.yml
do
  assert_file "${INSTALL_ROOT}/workflows/${workflow_name}" "installation assets should include ${workflow_name}"
  if ! cmp -s \
    "${ROOT}/.github/workflows/${workflow_name}" \
    "${INSTALL_ROOT}/workflows/${workflow_name}"
  then
    fail "installation workflow asset should match the dogfood workflow: ${workflow_name}"
  fi
done

assert_file_contains \
  "${ROOT}/.github/workflows/apply-changeset.yml" \
  "validate-changeset:" \
  "apply workflow should validate Report PR changesets before merge"
assert_file_contains \
  "${ROOT}/.github/workflows/apply-changeset.yml" \
  '_changeset-validate "$CHANGESET"' \
  "pre-merge workflow job should use the read-only CLI validator"
assert_file_contains \
  "${ROOT}/plugins/knowledge-distillery/skills/batch-refine/SKILL.md" \
  '_changeset-validate' \
  "batch-refine should validate a changeset before checkpointing it"
assert_file_contains \
  "${ROOT}/plugins/knowledge-distillery/skills/curate-report/SKILL.md" \
  '_changeset-validate' \
  "curation should validate the updated changeset before committing it"

if [ "$(wc -l < "${GATE_SKILL}/SKILL.md")" -gt 200 ]; then
  fail "knowledge-gate SKILL.md should stay within the progressive-disclosure target"
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
