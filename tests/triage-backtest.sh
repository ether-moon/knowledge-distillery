#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/plugins/knowledge-distillery/scripts/triage-backtest.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${message}: missing '${needle}'"
  fi
}

OUT="$(echo '{"author":{"login":"dependabot[bot]","is_bot":true},"title":"Bump foo from 1 to 2","files":["package.json","package-lock.json"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R1 bot dependency PR should skip"
assert_contains "$OUT" '"rule":"bot-dependency-update"' "R1 reason should be bot-dependency-update"

OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"chore: update deps","files":["pnpm-lock.yaml"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R2 lockfile-only should skip"
assert_contains "$OUT" '"rule":"lockfile-only"' "R2 reason should be lockfile-only"

OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"chore: regen","files":["dist/bundle.js","dist/bundle.js.map"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R3 generated-only should skip"
assert_contains "$OUT" '"rule":"generated-only"' "R3 reason should be generated-only"

OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"Revert \"feat: x\"","files":["src/x.ts"],"body":"This reverts commit abc123."}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R4 auto-revert should skip"
assert_contains "$OUT" '"rule":"auto-revert"' "R4 reason should be auto-revert"

OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"feat: add API","files":["src/api.ts","src/api.test.ts"],"body":"Adds new endpoint."}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"pass"' "typical PR should pass"

OUT="$(echo '{"author":{"login":"codemod-bot[bot]","is_bot":true},"title":"chore: migrate to new API","files":["src/legacy.ts","src/legacy.test.ts"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"pass"' "codemod bot with code changes should pass"

OUT="$(echo '{"author":{"login":"renovate[bot]","is_bot":true},"title":"chore: bump foo from 1 to 2","files":["package.json","package-lock.json"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R1 bot dependency PR should match bump as substring"
assert_contains "$OUT" '"rule":"bot-dependency-update"' "R1 should win for substring bump bot dependency PR"

OUT="$(echo '{"author":{"login":"dependabot[bot]","is_bot":true},"title":"Revert \"bump foo\"","files":["package-lock.json"],"body":"This reverts commit abc123."}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"rule":"bot-dependency-update"' "R1 should run before R4 when multiple rules match"

echo "triage-backtest tests passed"
