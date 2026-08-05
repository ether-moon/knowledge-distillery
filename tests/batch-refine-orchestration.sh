#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="${ROOT}/tests/skill-orchestration-harness.sh"
FIXTURE="${ROOT}/tests/fixtures/orchestration/batch-refine.json"
LIVE_WORKFLOW="${ROOT}/.github/workflows/batch-refine.yml"
INSTALL_WORKFLOW="${ROOT}/plugins/knowledge-distillery/install/workflows/batch-refine.yml"

bash "${HARNESS}" "${ROOT}" "${FIXTURE}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

if ! cmp -s "${LIVE_WORKFLOW}" "${INSTALL_WORKFLOW}"; then
  diff -u "${LIVE_WORKFLOW}" "${INSTALL_WORKFLOW}" >&2 || true
  fail "installation batch-refine workflow asset differs from live workflow"
fi

echo "batch-refine installation workflow asset parity passed"
