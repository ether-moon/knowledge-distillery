#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="${ROOT}/tests/skill-orchestration-harness.sh"
FIXTURE="${ROOT}/tests/fixtures/orchestration/batch-refine.json"

bash "${HARNESS}" "${ROOT}" "${FIXTURE}"
