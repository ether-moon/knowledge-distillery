#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "${ROOT}/tests/batch-refine-structure.sh"
bash "${ROOT}/tests/curate-report-structure.sh"
