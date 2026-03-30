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

EXTRACT="${ROOT}/plugins/knowledge-distillery/skills/extract-candidates/SKILL.md"
BATCH="${ROOT}/plugins/knowledge-distillery/skills/batch-refine/SKILL.md"
GATE_SKILL="${ROOT}/plugins/knowledge-distillery/skills/knowledge-gate/SKILL.md"
HOOK="${ROOT}/plugins/knowledge-distillery/hooks/pre-prompt-knowledge-gate.sh"
INIT="${ROOT}/plugins/knowledge-distillery/skills/init/SKILL.md"
DESIGN_EN="${ROOT}/docs/design-implementation.md"
DESIGN_KO="${ROOT}/docs/ko/design-implementation.md"

assert_contains "${EXTRACT}" '_domain_maintenance' "extract-candidates should define the structured domain maintenance annotation"
assert_contains "${EXTRACT}" '"issue": "too-broad | too-narrow | ambiguous-name | near-duplicate"' "extract-candidates should enumerate domain maintenance issue types"
assert_contains "${BATCH}" '_domain_maintenance' "batch-refine should preserve and report domain maintenance annotations"
assert_contains "${BATCH}" 'GATE domain-list --ids-only' "batch-refine should explicitly fetch the registry baseline"
assert_contains "${GATE_SKILL}" 'GATE get-many "<id-1>" "<id-2>" ...' "knowledge-gate skill should document batch detail retrieval"
assert_contains "${GATE_SKILL}" 'lightweight summary index by default' "knowledge-gate skill should explain summary-first queries"
assert_contains "${HOOK}" 'knowledge-gate get or knowledge-gate get-many' "pre-prompt hook should mention detail fetch after summary queries"
assert_contains "${INIT}" 'knowledge-gate get <id>` or `knowledge-gate get-many <id...>`' "init skill should install the summary-first retrieval guidance"
assert_contains "${DESIGN_EN}" 'knowledge-gate get-many "<entry ID 1>" "<entry ID 2>"' "English design doc should include batch detail retrieval"
assert_contains "${DESIGN_KO}" 'bin/knowledge-gate get-many "<항목 ID 1>" "<항목 ID 2>"' "Korean design doc should include batch detail retrieval"
assert_contains "${DESIGN_EN}" '_domain_maintenance' "English design doc should describe the structured follow-up signal"
assert_contains "${DESIGN_KO}" '_domain_maintenance' "Korean design doc should describe the structured follow-up signal"

echo "prompt contract tests passed"
