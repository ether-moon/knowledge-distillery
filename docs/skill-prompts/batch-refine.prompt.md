# Batch Refine — Skill Creation Prompt

## Purpose

Generate a skill file that orchestrates the full Stage B distillation pipeline: discovers pending PRs, runs per-PR subagents (collect → extract → quality-gate), inserts accepted candidates into vault.db, and creates a report PR for human review.

## Pipeline Position

- **Trigger**: Cron schedule (weekly/biweekly) or manual dispatch (GitHub Actions `workflow_dispatch`)
- **Depends on**: PRs labeled `knowledge:pending` (posted by `/mark-evidence`)
- **Produces**: vault.db updates + report PR + label transitions
- **Consumed by**: Human reviewer (merges the report PR)

## Prerequisites

### Runtime Environment
- Claude Code agent with full tool access
- `gh` CLI authenticated with repo scope + PR write permissions
- `knowledge-gate` CLI available and vault.db accessible
- `git` with push access to create branches
- `sqlite3` CLI for vault INSERT operations
- Linear MCP server (for evidence collection — gracefully degrade if unavailable)

### Allowed Tools
- All tools available to the three pipeline sub-skills
- `gh pr list/create/edit` — PR discovery and report creation
- `git checkout/add/commit/push` — branch and commit management
- `sqlite3` — direct vault.db INSERT (orchestrator privilege only)
- `knowledge-gate domain-report` — domain health assessment

## Input Contract

No explicit input. The orchestrator self-discovers work:

1. `gh pr list --label "knowledge:pending" --state merged` + `gh pr list --label "knowledge:insufficient" --state merged` → list of PR numbers
2. If both lists empty → exit with success (nothing to process)

## Output Contract

| Artifact | Format | Consumer |
|----------|--------|----------|
| vault.db updates | SQLite INSERTs into `entries`, `entry_domains`, `evidence`, `curation_queue` | knowledge-gate CLI (runtime) |
| Report PR | Markdown PR description with structured tables | Human reviewer |
| Label transitions | `knowledge:pending` → `knowledge:collected` or `knowledge:insufficient` | Pipeline state tracking |
| Git branch + commit | `knowledge/batch-YYYY-MM-DD` branch with vault.db changes | Git history |

## Behavioral Requirements

### Step 1: Discover Pending PRs

```
gh pr list --label "knowledge:pending" --state merged --json number,title,mergedAt
gh pr list --label "knowledge:insufficient" --state merged --json number,title,mergedAt
```

Merge both lists, deduplicate by PR number, sort by `mergedAt` ascending (oldest first). If no results, log "No pending PRs" and exit 0.

### Step 2: Create Working Branch

```
git checkout -b knowledge/batch-YYYY-MM-DD main
```

If branch already exists (re-run scenario), checkout existing branch.

### Step 3: Execute Per-PR Subagents

For each pending PR, spawn a subagent that executes the three pipeline steps sequentially:

1. **`/collect-evidence`** → Evidence Bundle
   - If `sufficiency.verdict == "insufficient"` → record PR as insufficient, skip to next PR
2. **`/extract-candidates`** → Candidate array
   - If empty array → record PR as "0 candidates", continue
3. **`/quality-gate`** → Verdict array

Subagent returns to orchestrator:
- Passed candidates (verdict == "pass")
- Rejected candidates with rejection codes
- Curation queue entries (conflicts)
- Insufficient evidence flag (if applicable)

### Step 4: Handle Insufficient Evidence PRs

For PRs where `/collect-evidence` returned `insufficient`:

1. Check if the PR already has `knowledge:insufficient` label (indicates a retry):
   - If yes (2nd failure): transition to `knowledge:abandoned`
     ```
     gh pr edit {pr_number} --remove-label "knowledge:insufficient" --add-label "knowledge:abandoned"
     ```
   - If no (1st failure): transition to `knowledge:insufficient` for retry next cycle
     ```
     gh pr edit {pr_number} --remove-label "knowledge:pending" --add-label "knowledge:insufficient"
     ```
2. Record in report under "Insufficient Evidence" section with retry status

Note: PRs labeled `knowledge:insufficient` are re-included in discovery (Step 1 searches both `knowledge:pending` and `knowledge:insufficient` labels). After 2 failed cycles they transition to `knowledge:abandoned` and are no longer retried.

### Step 5: Vault INSERT — Accepted Candidates

For each candidate with `verdict == "pass"`, construct a JSON array and pipe to `knowledge-gate _pipeline-insert`:

```bash
echo '[
  {
    "id": "<generated-uuid>",
    "type": "fact|anti-pattern",
    "title": "...",
    "claim": "...",
    "body": "...",
    "alternative": "...|null",
    "considerations": "...",
    "domains": ["domain-a", "domain-b"],
    "evidence": [{"type": "pr", "ref": "#1234"}, {"type": "linear", "ref": "PROJ-567"}],
    "curation": [{"related_id": "existing-id", "reason": "conflict description"}]
  }
]' | knowledge-gate _pipeline-insert
```

Notes:
- `_pipeline-insert` handles entries, entry_domains, evidence, curation_queue INSERTs in a single transaction
- FTS5 table (`entries_fts`) is updated automatically by triggers defined in the schema
- Domains not in `domain_registry` are auto-created by `_pipeline-insert`
- Generate entry `id` as UUID, `curation_queue.id` as `cq-{entry_id}-{timestamp}`

### Step 6: Domain Health Report

Run `knowledge-gate domain-report` and capture output. Include highlights in the report PR.

### Step 7: Commit and Push

```
git add .knowledge/vault.db
git commit -m "knowledge: batch YYYY-MM-DD — N entries added"
git push -u origin knowledge/batch-YYYY-MM-DD
```

If no candidates were accepted (all rejected or 0 extracted), still commit if label changes were made.

### Step 8: Create Report PR

Create a PR using `gh pr create` with the report format below.

### Step 9: Label Transitions for Processed PRs

For each PR that was successfully processed (regardless of candidate count):

```
gh pr edit {pr_number} --remove-label "knowledge:pending" --add-label "knowledge:collected"
```

Note: Label transitions are performed **after** Report PR creation (Step 8) to prevent a state where labels indicate completion but no Report PR exists for human review.

### Step 10: Cleanup Verification

Verify:
- All processed PRs have `knowledge:collected` or `knowledge:insufficient` label
- No PR retains `knowledge:pending` after processing
- vault.db is valid (basic `sqlite3 .knowledge/vault.db "SELECT count(*) FROM entries"` check)
- Report PR exists and is open

## Report PR Format

**Title**: `knowledge: batch YYYY-MM-DD — N entries added`

**Labels**: `knowledge:batch`

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
- `{entry_id}` ↔ `{related_id}`: {reason}

{If empty: "No conflicts detected."}

### Domain Changes
{New domains added, if any}
{domain-report highlights}

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
| No pending PRs | Exit 0 with "No pending PRs" message. No branch, no PR. |
| Subagent fails mid-execution | Skip that PR. Record error in report. Continue with remaining PRs. |
| vault.db INSERT fails (constraint violation) | Log error, skip that candidate. Record in report as "INSERT failed". |
| `git push` fails | Retry once. If still fails, output manual instructions and abort. |
| `gh pr create` fails | Output the report body to stdout so it's not lost. Log error. |
| All candidates rejected | Still create report PR (shows what was evaluated). |
| Domain not in registry | Create via `knowledge-gate domain-add` with auto-generated description. |
| Branch already exists | Checkout existing branch (supports re-runs). |

## Example Scenarios

### Scenario 1: Normal Batch with Mixed Results

**Pending PRs**: #1234, #456, #789

**Execution**:
- PR #1234: 2 candidates extracted, both pass → 2 entries inserted
- PR #456: 1 candidate extracted, fails R1 → 0 entries inserted
- PR #789: 1 candidate extracted, fails R6 (duplicate) → 0 entries inserted

**Output**: Report PR with 2 accepted, 2 rejected, 0 insufficient.

### Scenario 2: No Pending PRs

**Pending PRs**: (none)

**Output**: Exit 0. No branch, no commit, no PR.

### Scenario 3: All Insufficient Evidence

**Pending PRs**: #999, #998

**Execution**:
- PR #999: collect-evidence returns insufficient (Linear MCP down)
- PR #998: collect-evidence returns insufficient (no Manifest found)

**Output**: Report PR with 0 accepted, 0 rejected, 2 insufficient. Both PRs relabeled `knowledge:insufficient`.

## Reference Specifications

- Stage B pipeline: design-implementation.md §3.1 (Stage B steps)
- Vault schema: design-implementation.md §4.2
- Curation queue: design-implementation.md §5.2
- Domain model: design-implementation.md §4.5
- Domain report: cli.md §4
- Label state machine: design-implementation.md §3.1 (`knowledge:pending` → `knowledge:collected`)
- Entry status: design-implementation.md §5.3

## Constraints

- MUST NOT auto-merge the report PR — human review is the intervention point
- MUST NOT modify existing vault entries — INSERT only (append-only principle, design-implementation.md §5.1)
- MUST NOT skip the report PR even when all candidates are rejected (transparency)
- MUST process PRs in `mergedAt` order (oldest first)
- MUST handle partial failures gracefully — one PR's failure should not block others
- MUST create new domains via CLI when `applies_to.domains` references unknown domains
- MUST verify vault.db integrity after INSERTs

## Validation Checklist

1. Does the skill discover pending PRs via `knowledge:pending` label?
2. Does each PR get its own subagent running collect → extract → quality-gate?
3. Are accepted candidates inserted into all required tables (entries, entry_domains, evidence)?
4. Are conflict entries added to `curation_queue`?
5. Are PR labels correctly transitioned (`pending` → `collected` or `insufficient`)?
6. Is a report PR always created (unless no pending PRs exist)?
7. Does the report PR include all sections (accepted, rejected, curation, domain, insufficient)?
8. Does the skill handle partial failures without blocking remaining PRs?
