# PR Triage Follow-Up Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the review-identified PR triage reliability gaps before the pre-filter workflow is treated as operationally safe.

**Architecture:** Keep the current PoC architecture: Stage A triage remains in `mark-evidence`, Stage B extraction remains in `batch-refine`, and `triage-backtest.sh` stays a local validation tool. The improvements tighten state-machine idempotency, align the backtest with the documented production rules, clarify report-only batch behavior, and make generated regression reports harder to misread.

**Tech Stack:** Bash, Markdown skill contracts, JSON orchestration fixtures, `jq`, `gh`, `sqlite3`, existing shell test harnesses.

---

## File Structure

- Modify `plugins/knowledge-distillery/skills/mark-evidence/SKILL.md`
  - Add `knowledge:collected` to the state markers.
  - Add an initial no-op case for already collected PRs.
  - Clarify recovery for Manifest + triage decision states without current queue labels.
- Create `tests/fixtures/orchestration/mark-evidence.json`
  - Content-contract tests for the `mark-evidence` state machine.
- Create `tests/mark-evidence-orchestration.sh`
  - Generic fixture runner invocation for `mark-evidence` scenarios.
- Modify `tests/skill-orchestration.sh`
  - Register the new mark-evidence orchestration harness.
- Modify `plugins/knowledge-distillery/scripts/triage-backtest.sh`
  - Align Layer 1 rules with production spec.
  - Track Claude fallback and PR lookup failures in full-mode reports.
- Modify `tests/triage-backtest.sh`
  - Add regression coverage for substring `bump` matching and first-match rule order.
- Modify `plugins/knowledge-distillery/skills/batch-refine/SKILL.md`
  - Specify deferred-only commit/push before Report PR creation.
  - Change extract metric collection from ambiguous `pending and collected` to explicit union.
- Modify `tests/fixtures/orchestration/batch-refine.json`
  - Lock the deferred-only checkpoint and metric wording.
- Modify `plugins/knowledge-distillery/scripts/knowledge-gate`
  - Clarify that `recent-accepted-prs --limit` applies to recent accepted entries, not final unique PR count.
  - Optionally add `--entry-limit` as an alias while keeping `--limit` for compatibility.
- Modify `tests/knowledge-gate.sh`
  - Verify help text and alias behavior.
- Do not commit the current `.knowledge/reports/triage-backtest-2026-05-28.*` smoke files unless they are regenerated after a successful non-fallback Claude run.

---

### Task 1: Fix `mark-evidence` Idempotency For Completed PRs

**Files:**
- Modify: `plugins/knowledge-distillery/skills/mark-evidence/SKILL.md`
- Create: `tests/fixtures/orchestration/mark-evidence.json`
- Create: `tests/mark-evidence-orchestration.sh`
- Modify: `tests/skill-orchestration.sh`

- [ ] **Step 1: Add the failing orchestration fixture**

Create `tests/fixtures/orchestration/mark-evidence.json`:

```json
{
  "name": "mark-evidence orchestration regression harness",
  "documents": {
    "mark_evidence_skill": "plugins/knowledge-distillery/skills/mark-evidence/SKILL.md"
  },
  "scenarios": [
    {
      "id": "collected-pr-is-terminal",
      "checks": [
        {
          "doc": "mark_evidence_skill",
          "contains": "Labels: `knowledge:pending`, `knowledge:skipped`, `knowledge:deferred`, `knowledge:collected`"
        },
        {
          "doc": "mark_evidence_skill",
          "contains": "| C0 | `knowledge:collected` label exists | Exit successfully. Do not post another Manifest. Do not modify labels. |"
        }
      ]
    },
    {
      "id": "manifest-with-triage-decision-does-not-rerun-triage",
      "checks": [
        {
          "doc": "mark_evidence_skill",
          "contains": "If a Manifest and `KD_TRIAGE_DECISION` block exist but no knowledge state label exists, recover the label from the latest decision block and exit successfully. Do not rebuild the Manifest or rerun triage."
        }
      ]
    }
  ]
}
```

- [ ] **Step 2: Add the failing harness script**

Create `tests/mark-evidence-orchestration.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "${ROOT}/tests/lib/orchestration-fixture.sh" "${ROOT}/tests/fixtures/orchestration/mark-evidence.json"
```

Run:

```bash
bash tests/mark-evidence-orchestration.sh
```

Expected: FAIL because the new fixture text is not yet in `mark-evidence/SKILL.md`.

- [ ] **Step 3: Register the harness**

Modify `tests/skill-orchestration.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "${ROOT}/tests/batch-refine-orchestration.sh"
bash "${ROOT}/tests/curate-report-orchestration.sh"
bash "${ROOT}/tests/mark-evidence-orchestration.sh"
```

- [ ] **Step 4: Update the state machine contract**

Modify `plugins/knowledge-distillery/skills/mark-evidence/SKILL.md` Step 1:

```markdown
Check for these markers:
- Labels: `knowledge:pending`, `knowledge:skipped`, `knowledge:deferred`, `knowledge:collected`
- Comment blocks: `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`, `<!-- KD_TRIAGE_DECISION_START -->`
```

Add this as the first case in the table:

```markdown
| C0 | `knowledge:collected` label exists | Exit successfully. Do not post another Manifest. Do not modify labels. |
```

Add this recovery sentence after C4:

```markdown
If a Manifest and `KD_TRIAGE_DECISION` block exist but no knowledge state label exists, recover the label from the latest decision block and exit successfully. Do not rebuild the Manifest or rerun triage.
```

- [ ] **Step 5: Verify the targeted tests pass**

Run:

```bash
bash tests/mark-evidence-orchestration.sh
bash tests/skill-orchestration.sh
```

Expected:

```text
mark-evidence orchestration regression harness: 2 scenarios passed
```

- [ ] **Step 6: Commit Task 1**

```bash
git add plugins/knowledge-distillery/skills/mark-evidence/SKILL.md tests/fixtures/orchestration/mark-evidence.json tests/mark-evidence-orchestration.sh tests/skill-orchestration.sh
git commit -m "fix: make collected PR evidence marking idempotent"
```

---

### Task 2: Align `triage-backtest` Layer 1 With Production Rules

**Files:**
- Modify: `plugins/knowledge-distillery/scripts/triage-backtest.sh`
- Modify: `tests/triage-backtest.sh`

- [ ] **Step 1: Add failing Layer 1 tests**

Append to `tests/triage-backtest.sh` before the final echo:

```bash
OUT="$(echo '{"author":{"login":"renovate[bot]","is_bot":true},"title":"chore: bump foo from 1 to 2","files":["package.json","package-lock.json"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R1 bot dependency PR should match bump as substring"
assert_contains "$OUT" '"rule":"bot-dependency-update"' "R1 should win for substring bump bot dependency PR"

OUT="$(echo '{"author":{"login":"dependabot[bot]","is_bot":true},"title":"Revert \"bump foo\"","files":["package-lock.json"],"body":"This reverts commit abc123."}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"rule":"bot-dependency-update"' "R1 should run before R4 when multiple rules match"
```

Run:

```bash
bash tests/triage-backtest.sh
```

Expected: FAIL on the substring `bump` case or first-match rule order.

- [ ] **Step 2: Move R4 after R1/R2/R3 and fix the title regex**

In `plugins/knowledge-distillery/scripts/triage-backtest.sh`, replace the Layer 1 rule block with this order:

```bash
  if [ "$author_is_bot" = "true" ] && [[ "$title_lower" =~ dependabot|renovate|bump|update\ dependenc|upgrade\ dependenc ]]; then
    if all_files_dep_related "$pr_json"; then
      echo '{"decision":"skip","rule":"bot-dependency-update"}'
      return
    fi
  fi

  if all_files_match "$pr_json" is_lockfile; then
    echo '{"decision":"skip","rule":"lockfile-only"}'
    return
  fi

  if all_files_match "$pr_json" is_generated; then
    echo '{"decision":"skip","rule":"generated-only"}'
    return
  fi

  if [[ "$title" == Revert\ \"* ]] && { [ -z "$body" ] || [[ "$body" =~ ^This\ reverts\ commit\ [a-f0-9]+\.$ ]]; }; then
    echo '{"decision":"skip","rule":"auto-revert"}'
    return
  fi
```

- [ ] **Step 3: Verify targeted tests pass**

Run:

```bash
bash tests/triage-backtest.sh
```

Expected:

```text
triage-backtest tests passed
```

- [ ] **Step 4: Commit Task 2**

```bash
git add plugins/knowledge-distillery/scripts/triage-backtest.sh tests/triage-backtest.sh
git commit -m "fix: align triage backtest layer one rules"
```

---

### Task 3: Make Batch Report-Only Behavior Explicit

**Files:**
- Modify: `plugins/knowledge-distillery/skills/batch-refine/SKILL.md`
- Modify: `tests/fixtures/orchestration/batch-refine.json`

- [ ] **Step 1: Add failing fixture checks**

In `tests/fixtures/orchestration/batch-refine.json`, extend the deferred-only scenario with checks for:

```json
{
  "doc": "batch_refine_skill",
  "contains": "For a deferred-only report batch, write the empty changeset and report file, then commit and push them before Step 4 creates the Report PR."
}
```

Add another scenario:

```json
{
  "id": "extract-metric-queries-pending-and-collected-as-union",
  "checks": [
    {
      "doc": "batch_refine_skill",
      "contains": "Query merged PRs with `knowledge:pending` and merged PRs with `knowledge:collected` separately, union the results, then parse latest decision blocks where `layer == \"L2\" AND decision == \"extract\"`."
    }
  ]
}
```

Run:

```bash
bash tests/batch-refine-orchestration.sh
```

Expected: FAIL until the skill text is updated.

- [ ] **Step 2: Update deferred-only instructions**

In `plugins/knowledge-distillery/skills/batch-refine/SKILL.md`, update the deferred-only note under Step 3:

```markdown
Skip this step entirely for a deferred-only report batch (`pending == 0 AND deferred > 0` from Step 1). In that case, create `.knowledge/changesets/batch-YYYY-MM-DD.json` with `entries: []` and `.knowledge/reports/batch-YYYY-MM-DD.md` with the Deferred Queue section. For a deferred-only report batch, write the empty changeset and report file, then commit and push them before Step 4 creates the Report PR.
```

- [ ] **Step 3: Update extract metric wording**

Replace the existing metric bullet with:

```markdown
3. Query merged PRs with `knowledge:pending` and merged PRs with `knowledge:collected` separately, union the results, then parse latest decision blocks where `layer == "L2" AND decision == "extract"`.
```

- [ ] **Step 4: Verify targeted tests pass**

Run:

```bash
bash tests/batch-refine-orchestration.sh
```

Expected: all batch-refine orchestration scenarios pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add plugins/knowledge-distillery/skills/batch-refine/SKILL.md tests/fixtures/orchestration/batch-refine.json
git commit -m "fix: clarify deferred-only batch reporting"
```

---

### Task 4: Clarify `recent-accepted-prs` Limit Semantics

**Files:**
- Modify: `plugins/knowledge-distillery/scripts/knowledge-gate`
- Modify: `tests/knowledge-gate.sh`

- [ ] **Step 1: Add failing tests for help and alias**

In `tests/knowledge-gate.sh`, update the help assertion:

```bash
assert_contains "${help_output}" "recent-accepted-prs [--limit N|--entry-limit N]" "help should document recent accepted PR lookup"
assert_contains "${help_output}" "N is a recent active entry limit; output PRs are deduplicated" "help should explain recent accepted PR limit semantics"
```

Add an alias test near the existing `recent_limited` test:

```bash
recent_entry_limited="$(KNOWLEDGE_VAULT_PATH="$RECENT_VAULT" "$GATE" recent-accepted-prs --entry-limit 1)"
assert_eq "$recent_limited" "$recent_entry_limited" "recent-accepted-prs --entry-limit should alias --limit"
```

Run:

```bash
bash tests/knowledge-gate.sh
```

Expected: FAIL until the CLI help and parser are updated.

- [ ] **Step 2: Add `--entry-limit` as a compatible alias**

In `plugins/knowledge-distillery/scripts/knowledge-gate`, update the case arm:

```bash
        --limit|--entry-limit)
          limit="${2:-}"
          if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
            echo "Invalid $1: $limit" >&2
            exit 2
          fi
          shift 2
          ;;
```

Update usage text:

```bash
*) echo "Usage: knowledge-gate recent-accepted-prs [--limit N|--entry-limit N]" >&2; exit 1 ;;
```

Update help text:

```bash
echo "  recent-accepted-prs [--limit N|--entry-limit N]  Recent active entries' source PR numbers"
echo "      N is a recent active entry limit; output PRs are deduplicated"
```

- [ ] **Step 3: Verify targeted tests pass**

Run:

```bash
bash tests/knowledge-gate.sh
```

Expected:

```text
knowledge-gate tests passed
```

- [ ] **Step 4: Commit Task 4**

```bash
git add plugins/knowledge-distillery/scripts/knowledge-gate tests/knowledge-gate.sh
git commit -m "docs: clarify recent accepted PR limit semantics"
```

---

### Task 5: Make Backtest Reports Show Fallback And Lookup Failures

**Files:**
- Modify: `plugins/knowledge-distillery/scripts/triage-backtest.sh`

- [ ] **Step 1: Add counters to full mode**

In `triage-backtest.sh`, initialize counters after `SKIPPED=0`:

```bash
LOOKUP_FAILED=0
CLAUDE_FALLBACK=0
```

Change the PR fetch block:

```bash
  pr_meta="$(gh pr view "$pr_num" --json author,title,body,files,labels,comments 2>/dev/null || true)"
  if [ -z "$pr_meta" ]; then
    LOOKUP_FAILED=$((LOOKUP_FAILED + 1))
    continue
  fi
```

After `l2="$(layer2_eval "$l2_input")"`, add:

```bash
    reason="$(echo "$l2" | jq -r '.reason // "unknown"')"
    case "$reason" in
      claude-call-fallback|parse-fallback|schema-fallback) CLAUDE_FALLBACK=$((CLAUDE_FALLBACK + 1)) ;;
    esac
```

Remove the later duplicate `reason=` assignment if present.

- [ ] **Step 2: Add report fields**

In the Markdown report summary block, add:

```bash
  echo "- PR 조회 실패: ${LOOKUP_FAILED}"
  echo "- Layer 2 fallback: ${CLAUDE_FALLBACK}"
  if [ "$CLAUDE_FALLBACK" -gt 0 ] || [ "$LOOKUP_FAILED" -gt 0 ]; then
    echo "- baseline validity: degraded"
  else
    echo "- baseline validity: usable"
  fi
```

- [ ] **Step 3: Smoke test non-full paths**

Run:

```bash
bash tests/triage-backtest.sh
```

Expected:

```text
triage-backtest tests passed
```

- [ ] **Step 4: Run full smoke when credentials are available**

Run:

```bash
bash plugins/knowledge-distillery/scripts/triage-backtest.sh --limit 5
```

Expected:

```text
Backtest complete. Report: .../.knowledge/reports/triage-backtest-YYYY-MM-DD.md
```

Inspect the generated Markdown and confirm it contains `PR 조회 실패`, `Layer 2 fallback`, and `baseline validity`.

- [ ] **Step 5: Commit Task 5**

Only commit the generated `.knowledge/reports/triage-backtest-YYYY-MM-DD.*` files if `baseline validity: usable`.

```bash
git add plugins/knowledge-distillery/scripts/triage-backtest.sh
git commit -m "improve: surface triage backtest fallback signals"
```

---

### Task 6: Full Verification

**Files:**
- All files touched in Tasks 1-5

- [ ] **Step 1: Run all tests**

```bash
bash tests/all.sh
```

Expected includes:

```text
knowledge-gate tests passed
prompt contract tests passed
batch-refine orchestration regression harness
curate-report orchestration regression harness
mark-evidence orchestration regression harness
triage-backtest tests passed
```

- [ ] **Step 2: Check worktree**

```bash
git status --short
```

Expected: only intentional changes remain. The old fallback-only reports from `2026-05-28` should not be staged unless regenerated into a usable baseline.

- [ ] **Step 3: Review diff against target branch**

```bash
git diff origin/main... --stat
git diff origin/main... -- plugins/knowledge-distillery/skills/mark-evidence/SKILL.md plugins/knowledge-distillery/skills/batch-refine/SKILL.md plugins/knowledge-distillery/scripts/triage-backtest.sh plugins/knowledge-distillery/scripts/knowledge-gate tests
```

Expected: changes are limited to triage follow-up fixes and tests.

- [ ] **Step 4: Final commit if tasks were not committed individually**

If previous task commits were skipped, make one scoped commit:

```bash
git add plugins/knowledge-distillery/skills/mark-evidence/SKILL.md plugins/knowledge-distillery/skills/batch-refine/SKILL.md plugins/knowledge-distillery/scripts/triage-backtest.sh plugins/knowledge-distillery/scripts/knowledge-gate tests
git commit -m "fix: harden PR triage follow-up behavior"
```

---

## Self-Review

- Spec coverage: The plan covers all reviewed findings: collected PR idempotency, L1 rule drift, deferred-only commit/push, extract metric query ambiguity, `recent-accepted-prs` limit semantics, fallback/lookup visibility, and invalid report handling.
- Placeholder scan: No task relies on unspecified implementation details. Each code-changing task includes exact file paths, concrete snippets, commands, and expected results.
- Type consistency: The plan consistently uses `knowledge:pending`, `knowledge:skipped`, `knowledge:deferred`, `knowledge:collected`, `KD_TRIAGE_DECISION`, `--limit`, and `--entry-limit`.

## Execution Notes

- The `knowledge:collected` C0 case should be implemented first because it prevents data duplication.
- Do not treat a fallback-only 0% regression report as a valid baseline.
- Keep this as a PoC hardening pass. Do not externalize repository-specific triage rules in this pass.
