#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local message="$3"
  if ! grep -Fq "$needle" "$file"; then
    fail "${message}: missing '${needle}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local message="$3"
  if grep -Fq "$needle" "$file"; then
    fail "${message}: unexpectedly found '${needle}' in ${file}"
  fi
}

EXTRACT="${ROOT}/plugins/knowledge-distillery/skills/extract-candidates/SKILL.md"
BATCH="${ROOT}/plugins/knowledge-distillery/skills/batch-refine/SKILL.md"
GATE_SKILL="${ROOT}/plugins/knowledge-distillery/skills/knowledge-gate/SKILL.md"
HOOK="${ROOT}/plugins/knowledge-distillery/hooks/pre-prompt-knowledge-gate.sh"
SETUP="${ROOT}/plugins/knowledge-distillery/skills/setup/SKILL.md"
MEMENTO_COMMIT="${ROOT}/plugins/knowledge-distillery/skills/memento-commit/SKILL.md"
DESIGN_EN="${ROOT}/docs/design-implementation.md"
DESIGN_KO="${ROOT}/docs/ko/design-implementation.md"

assert_contains "${EXTRACT}" '_domain_maintenance' "extract-candidates should define the structured domain maintenance annotation"
assert_contains "${EXTRACT}" '"issue": "too-broad | too-narrow | ambiguous-name | near-duplicate"' "extract-candidates should enumerate domain maintenance issue types"
assert_contains "${BATCH}" '_domain_maintenance' "batch-refine should preserve and report domain maintenance annotations"
assert_contains "${BATCH}" '<knowledge-gate> domain-list --ids-only' "batch-refine should explicitly fetch the registry baseline"
assert_contains "${GATE_SKILL}" '<knowledge-gate> get-many "<id-1>" "<id-2>" ...' "knowledge-gate skill should document batch detail retrieval"
assert_contains "${GATE_SKILL}" 'lightweight summary index by default' "knowledge-gate skill should explain summary-first queries"
assert_contains "${GATE_SKILL}" 'do NOT create or execute a shell variable such as `$GATE`' "knowledge-gate skill should forbid shell-variable execution examples"
assert_contains "${HOOK}" 'knowledge-gate get <id> or knowledge-gate get-many <id...>' "pre-prompt hook should mention detail fetch after summary queries"
assert_contains "${SETUP}" 'knowledge-gate get <id>` or `knowledge-gate get-many <id...>`' "setup skill should install the summary-first retrieval guidance"
assert_contains "${DESIGN_EN}" 'knowledge-gate get-many "<entry ID 1>" "<entry ID 2>"' "English design doc should include batch detail retrieval"
assert_contains "${DESIGN_KO}" 'knowledge-gate get-many "<항목 ID 1>" "<항목 ID 2>"' "Korean design doc should include batch detail retrieval"
assert_contains "${DESIGN_EN}" '_domain_maintenance' "English design doc should describe the structured follow-up signal"
assert_contains "${DESIGN_KO}" '_domain_maintenance' "Korean design doc should describe the structured follow-up signal"
assert_not_contains "${GATE_SKILL}" 'GATE query-paths "<filepath>"' "knowledge-gate skill should not present GATE as an executable Bash token"
assert_contains "${MEMENTO_COMMIT}" "git commit -F - <<'COMMIT_EOF'" "memento-commit should stream the commit message through stdin"
assert_contains "${MEMENTO_COMMIT}" "git notes --ref=refs/notes/commits add --force -F - HEAD <<'MEMENTO_EOF'" "memento-commit should stream the memento note through stdin"
assert_not_contains "${MEMENTO_COMMIT}" 'COMMIT_MSG_FILE="${TMPDIR:-/tmp}/kd_commit_msg' "memento-commit should not use temp-file variable expansion"
assert_not_contains "${MEMENTO_COMMIT}" 'git commit -F "$COMMIT_MSG_FILE"' "memento-commit should not read the commit message from a shell-expanded temp file"
assert_not_contains "${MEMENTO_COMMIT}" "trap 'rm -f \"\$COMMIT_MSG_FILE\" \"\$MEMENTO_FILE\"' EXIT" "memento-commit should not rely on trap-based temp-file cleanup"

echo "prompt contract tests passed"
