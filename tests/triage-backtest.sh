#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/plugins/knowledge-distillery/skills/knowledge-gate/scripts/triage-backtest.sh"

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

# R5 docs-only (no decision signal) → skip
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"docs: update readme","files":["README.md","docs/guide.md"],"body":"Fix typos and clarify wording."}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R5 docs-only with no decision signal should skip"
assert_contains "$OUT" '"rule":"docs-only"' "R5 reason should be docs-only"

# R5 guard: decision keyword in body → pass (not skipped)
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"docs: architecture notes","files":["docs/notes.md"],"body":"We decided to adopt the new convention."}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"pass"' "R5 guard: docs with a decision keyword must not skip"

# R5 guard: decision path (docs/adr/) → pass
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"docs: add record","files":["docs/adr/0001-foo.md"],"body":"Background only."}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"pass"' "R5 guard: docs under docs/adr/ must not skip"

# R5 guard: decision keyword in title → pass
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"docs: deprecate old policy","files":["docs/x.md"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"pass"' "R5 guard: decision keyword in title must not skip"

# R5 not all-docs (one code file) → pass
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"docs and code","files":["README.md","src/x.ts"],"body":"mixed"}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"pass"' "R5 requires ALL files to be docs"

# R6 i18n-only → skip
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"i18n: korean","files":["frontend/locales/ko.po","frontend/locales/en.po"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R6 i18n-only should skip"
assert_contains "$OUT" '"rule":"i18n-only"' "R6 reason should be i18n-only"

echo "triage-backtest tests passed"
