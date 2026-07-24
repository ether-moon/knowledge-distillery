#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="${ROOT}/tests/skill-orchestration-harness.sh"
FIXTURE="${ROOT}/tests/fixtures/orchestration/batch-refine.json"
SETUP_SKILL="${ROOT}/plugins/knowledge-distillery/skills/setup/SKILL.md"
LIVE_WORKFLOW="${ROOT}/.github/workflows/batch-refine.yml"
SETUP_WORKFLOW="${ROOT}/plugins/knowledge-distillery/skills/setup/assets/workflows/batch-refine.yml"

bash "${HARNESS}" "${ROOT}" "${FIXTURE}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

if ! grep -Fq '<setup-skill-directory>/assets/workflows/batch-refine.yml' "${SETUP_SKILL}"; then
  fail "setup must reference its bundled batch-refine workflow asset"
fi

if ! cmp -s "${LIVE_WORKFLOW}" "${SETUP_WORKFLOW}"; then
  diff -u "${LIVE_WORKFLOW}" "${SETUP_WORKFLOW}" >&2 || true
  fail "setup batch-refine workflow asset differs from live workflow"
fi

echo "batch-refine setup workflow asset parity passed"
