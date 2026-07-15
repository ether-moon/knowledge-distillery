#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="${ROOT}/tests/skill-orchestration-harness.sh"
FIXTURE="${ROOT}/tests/fixtures/orchestration/batch-refine.json"
SETUP_SKILL="${ROOT}/plugins/knowledge-distillery/skills/setup/SKILL.md"
LIVE_WORKFLOW="${ROOT}/.github/workflows/batch-refine.yml"

bash "${HARNESS}" "${ROOT}" "${FIXTURE}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

heading='#### `.github/workflows/batch-refine.yml`'
heading_count="$(grep -Fxc "${heading}" "${SETUP_SKILL}")"
[ "${heading_count}" -eq 1 ] || fail "setup must contain exactly one batch-refine workflow section"

embedded_workflow="$(mktemp "${TMPDIR:-/tmp}/kd-batch-refine-workflow.XXXXXX")"
trap 'rm -f "${embedded_workflow}"' EXIT

awk '
  $0 == "#### `.github/workflows/batch-refine.yml`" { seek=1; next }
  seek && !started && $0 == "```yaml" { started=1; next }
  started && $0 == "```" { closed=1; exit }
  started { print }
  END { if (!seek || !started || !closed) exit 2 }
' "${SETUP_SKILL}" > "${embedded_workflow}" || fail "could not extract setup batch-refine workflow"

if ! cmp -s "${LIVE_WORKFLOW}" "${embedded_workflow}"; then
  diff -u "${LIVE_WORKFLOW}" "${embedded_workflow}" >&2 || true
  fail "setup batch-refine workflow differs from live workflow"
fi

echo "batch-refine setup workflow parity passed"
