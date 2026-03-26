#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "${ROOT}/tests/knowledge-gate.sh"
bash "${ROOT}/tests/skill-orchestration.sh"
bash "${ROOT}/tests/skill-structure.sh"
