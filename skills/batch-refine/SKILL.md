---
description: "Orchestrates the Stage B distillation pipeline: discovers merged PRs labeled knowledge:pending, runs per-PR evidence collection → candidate extraction → quality gate, inserts accepted entries into vault.db, and creates a report PR for human review. Triggered on schedule (weekly/biweekly) or manual dispatch."
---

# batch-refine — Stage B Pipeline Orchestrator

## When This Skill Runs

- Cron schedule (weekly/biweekly) via GitHub Actions
- Manual dispatch via `workflow_dispatch`
- Invoked as `/knowledge-distillery:batch-refine`

## Prerequisites

- `gh` CLI authenticated with repo scope + PR write permissions
- `${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate` CLI available
- `.knowledge/vault.db` accessible
- `sqlite3` CLI available
- `jq` CLI available
- `git` with push access
- Linear MCP server (graceful degradation if unavailable)

## Execution Steps

### Step 1: Discover Pending PRs

```bash
gh pr list --label "knowledge:pending" --state merged --json number,title,mergedAt
gh pr list --label "knowledge:insufficient" --state merged --json number,title,mergedAt
```

Merge both lists, deduplicate by PR number, sort by `mergedAt` ascending (oldest first).

**If no results:** Log "No pending PRs" and exit 0. Do NOT create a branch, commit, or PR.

### Step 2: Create Working Branch

```bash
git checkout -b knowledge/batch-YYYY-MM-DD main
```

If branch already exists (re-run scenario), checkout existing branch.

### Step 3: Execute Per-PR Subagents

For each pending PR (in `mergedAt` order), spawn a subagent that runs sequentially:

1. **`/knowledge-distillery:collect-evidence`** with the PR number → Evidence Bundle
   - If `sufficiency.verdict == "insufficient"` → record PR as insufficient, skip to next PR
2. **`/knowledge-distillery:extract-candidates`** with the Evidence Bundle → Candidate array
   - Runs in the same subagent context, so the Evidence Bundle and any selectively fetched PR diff context from collect-evidence remain available in-memory
   - If empty array → record PR as "0 candidates", continue to next PR
3. **`/knowledge-distillery:quality-gate`** with the Candidate array → Verdict array

Collect from each subagent:
- Passed candidates (`verdict == "pass"`)
- Rejected candidates with rejection codes
- Curation queue entries (conflicts)
- Insufficient evidence flag (if applicable)

**Partial failure handling:** One PR's failure MUST NOT block remaining PRs. Log the error and continue.

### Step 4: Handle Insufficient Evidence PRs

For PRs where collect-evidence returned `insufficient`:

1. Check current labels:
   - If PR already has `knowledge:insufficient` (2nd failure → SLA exceeded):
     ```bash
     gh pr edit {number} --remove-label "knowledge:insufficient" --add-label "knowledge:abandoned"
     ```
   - If PR has `knowledge:pending` (1st failure):
     ```bash
     gh pr edit {number} --remove-label "knowledge:pending" --add-label "knowledge:insufficient"
     ```
2. Record in report under "Insufficient Evidence" section

### Step 5: Vault INSERT — Accepted Candidates

For all passed candidates, construct a JSON array and insert via the pipeline CLI:

```bash
echo '<json_array>' | ${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate _pipeline-insert
```

The JSON format for `_pipeline-insert`:

```json
[
  {
    "id": "kebab-case-slug",
    "type": "fact|anti-pattern",
    "title": "...",
    "claim": "...",
    "body": "...",
    "alternative": "...|null",
    "considerations": "...",
    "domains": ["domain-a", "domain-b"],
    "evidence": [{"type": "pr", "ref": "#1234"}],
    "curation": [{"related_id": "existing-id", "reason": "conflict description"}]
  }
]
```

Notes:
- `_pipeline-insert` handles entries, entry_domains, evidence, curation_queue in a single transaction
- FTS5 triggers auto-update the search index
- Unknown domains are auto-created by `_pipeline-insert`
- Map quality-gate `curation_queue_entry` to the `curation` field when present

### Step 6: Domain Health Report

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate domain-report
```

Capture output for inclusion in the report PR.
Also review the processed batch PRs' `changed_files` lists and highlight repeated path prefixes that still have no domain mapping. This "uncovered pattern" check is performed at the skill/report level, not by the CLI.

### Step 7: Generate Batch Report File and Commit

**Always** generate `.knowledge/reports/batch-YYYY-MM-DD.md` — even with 0 accepted candidates. This guarantees a git diff for the Report PR.

```bash
mkdir -p .knowledge/reports
# Write report content to .knowledge/reports/batch-YYYY-MM-DD.md
git add .knowledge/vault.db .knowledge/reports/
git commit -m "knowledge: batch YYYY-MM-DD — N entries added"
git push -u origin knowledge/batch-YYYY-MM-DD
```

### Step 8: Create Report PR

```bash
gh pr create \
  --title "knowledge: batch YYYY-MM-DD — N entries added" \
  --label "knowledge:batch" \
  --body "<report body>"
```

**MUST NOT auto-merge the report PR.** Human review is the intervention point.

### Step 9: Label Transitions for Processed PRs

**After** Report PR creation (to prevent orphaned label state):

```bash
gh pr edit {number} --remove-label "knowledge:pending" --add-label "knowledge:collected"
```

For PRs that had `knowledge:insufficient` and were successfully processed:
```bash
gh pr edit {number} --remove-label "knowledge:insufficient" --add-label "knowledge:collected"
```

### Step 10: Cleanup Verification

Verify:
- All processed PRs have `knowledge:collected`, `knowledge:insufficient`, or `knowledge:abandoned` label
- No PR retains `knowledge:pending` after processing
- `sqlite3 .knowledge/vault.db "SELECT count(*) FROM entries"` succeeds
- Report PR exists and is open

## Report PR Format

**Title**: `knowledge: batch YYYY-MM-DD — N entries added`

**Body**:

```markdown
## Knowledge Distillery Batch Report — YYYY-MM-DD

### Summary
| Metric | Value |
|--------|-------|
| Source PRs processed | N |
| Candidates extracted | M |
| Accepted (fact / anti-pattern) | K (F / A) |
| Rejected | J |
| Insufficient evidence (deferred) | D |

### Accepted Entries

| ID | Type | Title | Domains | Source PR |
|----|------|-------|---------|-----------|
| {id} | {type} | {title} | {domains} | #{pr_number} |

### Rejected Candidates

| Source PR | Code | Reason |
|-----------|------|--------|
| #{pr_number} | {rejection_codes} | {notes} |

### Curation Queue (Human Review Required)
{For each curation_queue_entry:}
- `{entry_id}` <-> `{related_id}`: {reason}

{If empty: "No conflicts detected."}

### Domain Changes
{New domains added during this batch, if any}
{domain-report highlights from Step 6}
{Repeated unmapped path prefixes observed across this batch, if any}

### Source PR Details
{For each processed PR:}
- #{pr_number} "{title}": {outcome summary}

### Insufficient Evidence (Next Cycle Retry)
{For each insufficient PR:}
- #{pr_number} "{title}": {missing sources}

{If none: "All PRs had sufficient evidence."}
```

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| No pending PRs | Exit 0. No branch, no PR. |
| Subagent fails | Skip that PR. Record error in report. Continue with remaining. |
| vault.db INSERT fails | Log error, skip that candidate. Record as "INSERT failed" in report. |
| `git push` fails | Retry once. If still fails, output manual instructions and abort. |
| `gh pr create` fails | Output report body to stdout so it's not lost. Log error. |
| All candidates rejected | Still create report PR (transparency). Batch report file guarantees diff. |
| Branch already exists | Checkout existing branch (supports re-runs). |

## Constraints

- MUST NOT auto-merge the report PR
- MUST NOT modify existing vault entries (INSERT only, append-only principle)
- MUST NOT skip the report PR even when all candidates are rejected
- MUST process PRs in `mergedAt` order (oldest first)
- MUST handle partial failures gracefully
- MUST verify vault.db integrity after INSERTs
- MUST create report file `.knowledge/reports/batch-YYYY-MM-DD.md` always (even 0 entries)
