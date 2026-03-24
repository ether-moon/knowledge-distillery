---
description: "Orchestrates the Stage B distillation pipeline: discovers merged PRs labeled knowledge:pending, runs per-PR evidence collection → candidate extraction → quality gate, inserts accepted entries into vault.db, and creates a report PR for human review. Triggered on schedule (weekly/biweekly) or manual dispatch."
---

# batch-refine — Stage B Pipeline Orchestrator

## When This Skill Runs

- Cron schedule (weekly/biweekly) via GitHub Actions
- Manual dispatch via `workflow_dispatch`
- Invoked as `/knowledge-distillery:batch-refine`

## Prerequisites

- GitHub MCP server configured with `pull_requests,issues,labels` toolsets
- `knowledge-gate` CLI available (resolve path as described in the `knowledge-gate` skill — local dev path if available, else `${CLAUDE_PLUGIN_ROOT}`)
- `.knowledge/vault.db` accessible
- `sqlite3` CLI available
- `jq` CLI available
- `git` with push access
- Linear MCP server (graceful degradation if unavailable)
- Slack MCP server (optional — graceful degradation if unavailable)
- Notion MCP server (optional — graceful degradation if unavailable)
- git-memento (optional — gracefully degrade if unavailable)

## Execution Steps

### Step 1: Discover Pending PRs

```
Use GitHub MCP to list all merged PRs with the `knowledge:pending` label (fields: number, title, mergedAt).
```

Sort by `mergedAt` ascending (oldest first).

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

1. Keep the PR labeled `knowledge:pending`
2. Record in report under "Insufficient Evidence" section
3. Retry on a later batch run after more evidence accumulates

### Step 5: Vault INSERT — Accepted Candidates

For all passed candidates, construct a JSON array and insert via the pipeline CLI:

```bash
echo '<json_array>' | GATE _pipeline-insert
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
    "applies_to": {
      "domains": ["domain-a", "domain-b"]
    },
    "evidence": [{"type": "pr", "ref": "#1234"}],
    "curation": [{"related_id": "existing-id", "reason": "conflict description"}],
    "_proposed_domain": [{"name": "new-domain", "description": "...", "suggested_patterns": ["src/module/"]}]
  }
]
```

**Entry ID generation rules:**
- Format: kebab-case slug, 3-5 words describing the knowledge entry
- On UNIQUE constraint collision, append numeric suffix (e.g., `payment-service-object-2`)
- `curation_queue.id` format: `cq-{entry_id}-{timestamp}`

Notes:
- `_pipeline-insert` handles entries, entry_domains, evidence, curation_queue in a single transaction
- Every accepted candidate passed to `_pipeline-insert` MUST include at least one evidence item
- FTS5 triggers auto-update the search index
- Unknown domains are auto-created by `_pipeline-insert`
- Map quality-gate `curation_queue_entry` to the `curation` field when present
- Preserve `_proposed_domain` annotations from extract-candidates in the JSON passed to `_pipeline-insert`. Suggested patterns must already satisfy the CLI path-pattern contract (`*` or directory prefix ending with `/`).

### Step 6: Domain Health Report

```bash
GATE domain-report
```

Capture output for inclusion in the report PR.
Also review the processed batch PRs' `changed_files` lists and highlight repeated path prefixes that still have no domain mapping. This "uncovered pattern" check is performed at the skill/report level, not by the CLI.
Do NOT auto-run domain merge/split/deprecate actions in this stage. Domain reorganization is a manual follow-up based on the report.

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

```
Use GitHub MCP to create a PR:
  - title: "knowledge: batch YYYY-MM-DD — N entries added"
  - body: <report body content per the Report PR Format section below>
  - base: main (or master)
  - head: knowledge/batch-YYYY-MM-DD
```

**MUST NOT auto-merge the report PR.** Human review is the intervention point.

### Step 9: Label Transitions for Processed PRs

**After** Report PR creation (to prevent orphaned label state):

```
Use GitHub MCP to remove the `knowledge:pending` label and add the `knowledge:collected` label to PR #{number}.
```

### Step 10: Cleanup Verification

Verify:
- All successfully processed PRs have `knowledge:collected` label
- PRs with insufficient evidence remain `knowledge:pending`
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
{New domains auto-created during this batch, if any}
{domain-report highlights from Step 6}
{Repeated unmapped path prefixes observed across this batch, if any}
{Manual follow-up suggestions for domain merge/split/path cleanup, if any}

### Source PR Details
{For each processed PR:}
- #{pr_number} "{title}": {outcome summary}

### Insufficient Evidence (Remains Pending)
{For each insufficient PR:}
- #{pr_number} "{title}": {missing sources}

{If none: "All PRs had sufficient evidence."}

---

### How to Curate This Report

This PR contains new knowledge entries already inserted into `vault.db`. You can selectively accept, reject, or modify entries before merging.

**To provide feedback:**
1. Leave comments on this PR referencing entry IDs from the Accepted Entries table:
   - Reject: "Reject `entry-id` — reason"
   - Modify: "Change the claim of `entry-id` to: new text"
   - Update domains: "Move `entry-id` to domain `new-domain`"
2. Post a comment with **`/curate`** to trigger automated processing
3. Review the updated diff after curation completes
4. Merge when satisfied, or run `/curate` again for further changes

**What `/curate` does:**
- Rejected entries are archived in vault.db (preserves history, not deleted)
- Modified entries are updated in-place
- The batch report is regenerated to reflect current state
- A summary comment is posted with all actions taken
```

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| No pending PRs | Exit 0. No branch, no PR. |
| Subagent fails | Skip that PR. Record error in report. Continue with remaining. |
| vault.db INSERT fails | Log error, skip that candidate. Record as "INSERT failed" in report. |
| `git push` fails | Retry once. If still fails, output manual instructions and abort. |
| GitHub MCP PR creation fails | Output report body to stdout so it's not lost. Log error. |
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
