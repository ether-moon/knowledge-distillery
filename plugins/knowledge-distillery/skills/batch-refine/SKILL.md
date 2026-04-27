---
name: batch-refine
description: "Orchestrates the Stage B distillation pipeline: discovers merged PRs labeled knowledge:pending, runs per-PR evidence collection → candidate extraction → quality gate, writes a changeset file for accepted entries, and creates a report PR for human review. Triggered on schedule (weekly/biweekly) or manual dispatch. Use when you need to process accumulated knowledge from merged PRs, run the refinement pipeline, or manually trigger a batch distillation cycle."
---

# batch-refine — Stage B Pipeline Orchestrator

## When This Skill Runs

- Cron schedule (weekly/biweekly) via GitHub Actions
- Manual dispatch via `workflow_dispatch`
- Self-retrigger via `gh workflow run batch-refine.yml -f retry_count=N` (graceful handoff path)
- Invoked as `/knowledge-distillery:batch-refine`

## Time Budget and Self-Retrigger

The GitHub token used by this workflow expires roughly one hour after the workflow starts. Once it expires, every subsequent operation (commit, push, label change, PR update, even `gh workflow run`) will fail with 401. To avoid leaving the batch in a half-finished state, this skill must hand work off to a fresh workflow run **before** the token expires.

**Environment contract** (set by `.github/workflows/batch-refine.yml`):

| Variable | Meaning |
|----------|---------|
| `BATCH_START_TS` | Unix timestamp when this run started (proxy for token issuance time). |
| `DEADLINE_SECONDS` | Maximum elapsed seconds before refusing to start a new PR (e.g. `2100` = 35 min). |
| `RETRY_COUNT` | How many self-retriggers preceded this run. Cron starts at `0`. |
| `MAX_RETRY_COUNT` | Hard ceiling on self-retriggers per batch (e.g. `5`). |

The deadline (35 min) is well under the token lifetime (~60 min) so all handoff operations complete with a valid token. The only "ungraceful" path is unexpected 401 from network/MCP issues — in that case the run dies, but PR-atomic commits preserve everything completed so far, and the next cron run resumes naturally.

### Time budget check (before each PR)

Run this check at the **top of every PR iteration**, before invoking `collect-evidence`:

```bash
elapsed=$(( $(date +%s) - BATCH_START_TS ))
remaining=$(( DEADLINE_SECONDS - elapsed ))
if [ "$remaining" -le 0 ]; then
  # Skip this PR. Enter graceful handoff with the remaining PRs as the leftover set.
  goto_graceful_handoff=1
fi
```

If `goto_graceful_handoff=1`, stop the loop and run the **Graceful Handoff Procedure** below. Do **not** start a new PR after the deadline — even a "small" PR can blow through the remaining margin once an LLM call stalls.

### PR-atomic commit pattern

Every PR that completes (or is determined `insufficient`) must immediately commit its changeset delta and update its label, **before** moving on to the next PR. This guarantees that any kind of crash — graceful handoff, 401, OOM, runner timeout — leaves a consistent state for the next run to pick up.

For each PR:

1. Append entries to `.knowledge/changesets/batch-YYYY-MM-DD.json` (or set `insufficient` flag in the report file).
2. Append a row to `.knowledge/reports/batch-YYYY-MM-DD.md` progress table (see "Report PR Progress Table" below).
3. `git add .knowledge/ && git commit -m "kd: PR #<n> processed"`.
4. `git push`.
5. Update the PR's label: `knowledge:pending` → `knowledge:collected` (or leave pending if insufficient).
6. If a Report PR already exists for this batch, refresh its body from the report file. Skip if it does not yet exist (it gets created at first commit).

The order is intentional: **changeset/report committed and pushed before label flips**. If the label flips first and we crash, the next run sees `knowledge:collected` and skips the PR even though its entries are not in the changeset.

### Graceful Handoff Procedure

Triggered when the time-budget check fails. Performed once, after the last in-flight PR finishes (or never starts).

1. **Confirm progress is committed.** If any in-flight changeset/report changes are uncommitted, commit + push now while the token is still valid.
2. **Append a handoff row to the Report PR progress table** using the exact Markdown table row format below (matching the table schema in the "Report PR Progress Table" section — never use bullets here):
   ```markdown
   | run #$GITHUB_RUN_ID | ⏱ 시간 예산 도달 — 처리 N개, 남은 M개, 재트리거함 (재시도 $RETRY_COUNT/$MAX_RETRY_COUNT) |
   ```
   Commit + push this update (the report file is part of the same branch).
3. **Decide whether to retrigger.** Retrigger if **both** are true:
   - `RETRY_COUNT < MAX_RETRY_COUNT`
   - At least one PR with `knowledge:pending` label remains
4. **Retrigger:**
   ```bash
   gh workflow run batch-refine.yml -f retry_count=$((RETRY_COUNT + 1))
   ```
   If retrigger succeeds, append `재트리거함 → run #<new_run_id>` (best-effort link) to the same row. If retrigger fails (401 already, or `actions: write` denied), do not retry — the next cron will pick up the leftover PRs.
5. **If `MAX_RETRY_COUNT` reached:** append `❗ 재시도 한도 도달, 다음 cron까지 대기` to the row. Do **not** retrigger. Leave remaining PRs labeled `knowledge:pending`.
   **If no `knowledge:pending` PRs remain (`classify_handoff` → `no-pending`, `format_handoff_row` → `남은 0개`):** still append the handoff row and commit/push, but do **not** retrigger even if `RETRY_COUNT < MAX_RETRY_COUNT`. The batch is naturally complete.
6. **Exit 0.** A graceful handoff is a successful workflow run, not a failure. Failing the workflow would only generate noise.

### Unexpected 401 (ungraceful path)

If `collect-evidence` (or any GitHub MCP call) returns 401/403 mid-run, the token has died early. Do **not** attempt the handoff procedure — every step requires a valid token.

1. The PR currently being processed: do nothing. It stays `knowledge:pending`.
2. Stop the loop.
3. Exit (any non-zero is fine; the workflow run will be marked failed but PR-atomic commits up to this point are already in place).

The next cron (or manual dispatch) sees the leftover `knowledge:pending` PRs and resumes from there. No retrigger from inside this run.

### Report PR Progress Table

The Report PR body opens with a per-run progress table. Each row records one PR's outcome **or** one handoff event. The table grows append-only across retriggers so reviewers see the full story.

Format:

```markdown
### 진행 상황

| 항목 | 상태 |
|------|------|
| #1234 | ✅ 처리 완료 (3 accepted, run #100) |
| #1235 | ⏸ 대기 중 (insufficient: manifest, run #100) |
| run #100 | ⏱ 시간 예산 도달 — 처리 1개, 남은 1개, 재트리거함 → run #101 |
| #1236 | ✅ 처리 완료 (2 accepted, run #101) |
```

When a retrigger run starts, it picks up the existing branch + Report PR, reads the table to count work already done, and continues processing remaining `knowledge:pending` PRs.

## Prerequisites

- GitHub MCP server configured with `pull_requests,issues,labels` toolsets
- `knowledge-gate` CLI available (resolve path as described in the `knowledge-gate` skill — local dev path if available, else `${CLAUDE_PLUGIN_ROOT}`)
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

### Step 2: Create or Resume Working Branch

```bash
git checkout -b knowledge/batch-YYYY-MM-DD main
```

If the branch already exists (re-run or self-retrigger scenario), checkout the existing branch — do not reset it. The accumulated commits from previous runs are the source of truth for which PRs have already been processed in this batch.

When resuming an existing branch, also locate the existing Report PR (if any) and re-read the progress table to confirm which PRs are already marked complete. The PR's `knowledge:collected` label is the authoritative signal; treat the progress table as a human-readable mirror.

### Step 3: Per-PR Atomic Loop

Process pending PRs **one at a time** in `mergedAt` ascending order. For each PR run the full per-PR pipeline and immediately persist progress before moving on. This guarantees that any kind of mid-run termination (graceful handoff, 401, runner timeout) leaves a consistent state.

```text
for pr in pending_prs (sorted by mergedAt asc):
  # 3a. Time budget gate
  elapsed=$(( $(date +%s) - BATCH_START_TS ))
  if [ "$elapsed" -ge "$DEADLINE_SECONDS" ]; then
    break   # → Graceful Handoff Procedure
  fi

  # 3b. Run pipeline for this single PR — MUST run in a fresh subagent
  # spawned via the Agent tool. Each PR gets its own context window so that
  # accumulating PRs do not pollute the orchestrator's main context. Inside
  # that subagent, the three skills are invoked sequentially:
  spawn-agent (single Agent tool call, fresh context):
    invoke /knowledge-distillery:collect-evidence with pr.number
      → Evidence Bundle
      - If sufficiency.verdict == "insufficient" AND
        sufficiency.missing contains "github_auth":
          → enter "Unexpected 401" path (do NOT retrigger; token is dead)
      - If sufficiency.verdict == "insufficient" for any other reason:
          → record insufficient, skip 3c/3d, continue with next PR
    invoke /knowledge-distillery:extract-candidates with the Evidence Bundle
      → Candidate array (may be empty)
    invoke /knowledge-distillery:quality-gate with the Candidate array
      → Verdict array
  return Verdict array (and any insufficient/auth signal) to the orchestrator

  # 3c. Persist this PR's outcome (atomic checkpoint)
  - Append accepted entries to .knowledge/changesets/batch-YYYY-MM-DD.json
  - Append a progress table row + per-PR detail to .knowledge/reports/batch-YYYY-MM-DD.md
  - git add .knowledge/ && git commit -m "kd: PR #<n> processed"
  - git push (creates the branch on first commit; updates Report PR body via Step 4 if it exists)

  # 3d. Flip the label (only after the commit landed)
  - Use GitHub MCP to remove `knowledge:pending` and add `knowledge:collected` on PR #<n>
    (if insufficient: leave label as `knowledge:pending`)
```

**Why serial, not parallel?** Earlier versions of this skill spawned all PRs in parallel for throughput. Parallelism is incompatible with the "graceful handoff before token expiry" contract: if multiple subagents are mid-flight when the deadline is reached, the orchestrator cannot cleanly truncate them. Serial processing keeps the cancellation point well-defined (between PRs) and makes the progress table monotonically meaningful. Throughput is recovered across multiple workflow runs (cron + self-retriggers) rather than within one.

**Partial failure handling:** If a single PR's pipeline raises (extract-candidates crash, quality-gate failure, etc.) and the cause is **not** GitHub auth (401/403), record the failure in the progress table for that PR (`❌ failed: <error>`), do not flip its label, and continue with the next PR. PR-level failures MUST NOT block the rest of the batch.

### Step 4: Maintain Report PR

After the **first** PR commits successfully and pushes the branch, ensure a Report PR exists. After every subsequent PR commit, refresh the PR body from `.knowledge/reports/batch-YYYY-MM-DD.md` and reconcile the reviewer set.

**Why reviewers are auto-assigned:** Source PR authors of every accumulated changeset entry get review-requested on the Report PR so they receive a fast feedback loop on how their PR was distilled. The changeset grows incrementally across the per-PR loop (and across self-retrigger runs), so the reviewer set is reconciled on every Report PR refresh — new authors get added; previously-requested ones stay.

**Reviewer collection procedure (run on every create / refresh):**

1. Iterate every entry in `.knowledge/changesets/batch-YYYY-MM-DD.json` (`entries[]` — every `status` is included; entries of every status share the same `data.evidence[]` shape). Collect every PR number from `entries[].data.evidence[].ref` (e.g., `"#27"` → `27`).
2. Deduplicate the PR-number set.
3. For each unique PR number, resolve the author and bot flag using the `gh` CLI (not GitHub MCP — the `jq` pipe format below is what the next step parses):
   ```bash
   gh pr view <num> --json author --jq '.author.login + "|" + (.author.is_bot | tostring)'
   ```
   On error for a single PR, log a warning and skip — continue collecting other authors.
4. Filter the resolved authors:
   - Drop entries where `is_bot == true`.
   - Drop empty / null logins (deleted accounts).
   - Deduplicate by login.

**Create or refresh the Report PR:**

```text
If no PR with head=knowledge/batch-YYYY-MM-DD exists:
  Use GitHub MCP to create a PR (title/body/base/head per "Report PR Format" below).
  Pass `reviewers` = the filtered author list (omit the argument entirely when the list is empty).
Else:
  Use GitHub MCP to update the existing PR's body from the latest report file.
  Then add any new reviewers idempotently:
    gh pr edit <pr_number> --add-reviewer <login1>,<login2>,...
  `--add-reviewer` re-requesting an already-requested reviewer is a no-op, so the call is safe to make on every refresh with the full current set. Skip the call when the list is empty.
```

If GitHub MCP rejects the entire `reviewers` argument on PR creation, retry the create call once without it so the PR is still created, then log a warning. The reviewer set will be reconciled by `gh pr edit --add-reviewer` on the next refresh.

**MUST NOT auto-merge the report PR.** Human review is the intervention point.

### Step 5: Handle Insufficient Evidence PRs

For PRs where collect-evidence returned `insufficient`:

1. Keep the PR labeled `knowledge:pending` (no label flip in Step 3d).
2. The progress table row is `⏸ 대기 중 (insufficient: <missing>, run #<id>)`.
3. The next batch run picks them up automatically — no special handling required.

### Step 6: Changeset — Accepted Candidates

The changeset is written **incrementally** by Step 3c, one PR's entries at a time. This section documents the file format. Entries are NOT inserted into vault.db at this stage — they are applied after the Report PR is merged.

**Changeset format:**

```json
{
  "version": 1,
  "batch_date": "YYYY-MM-DD",
  "entries": [
    {
      "status": "accepted",
      "data": {
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
        "_proposed_domain": [{"name": "new-domain", "description": "...", "suggested_patterns": ["src/module/"]}],
        "_domain_maintenance": [{"domain": "pipeline", "issue": "too-broad", "suggestion": "split", "reason": "..."}],
        "_vault_feedback": [{"entry_id": "existing-id", "signal": "outdated", "note": "description", "memento_sha": "a1b2c3d"}]
      }
    }
  ]
}
```

**Entry ID generation rules:**
- Format: kebab-case slug, 3-5 words describing the knowledge entry
- `curation_queue.id` format: `cq-{entry_id}-{timestamp}`

Notes:
- The `data` object for each entry uses the same format as `_pipeline-insert` JSON
- Every accepted candidate MUST include at least one evidence item
- Unknown domains will be auto-created when the changeset is applied after merge
- Map quality-gate `curation_queue_entry` to the `curation` field when present
- Preserve `_proposed_domain` annotations from extract-candidates. Suggested patterns must already satisfy the CLI path-pattern contract (`*` or directory prefix ending with `/`).
- Preserve `_domain_maintenance` annotations from extract-candidates so the report can surface follow-up domain cleanup suggestions.
- Preserve `_vault_feedback` annotations from extract-candidates so the report can surface feedback on existing vault entries.

### Step 7: Domain Change Summary (after the PR loop)

Run this after the per-PR loop ends — either because all PRs are processed, or because a graceful handoff is about to fire. Since entries are not yet inserted into vault.db, `domain-report` cannot reflect this batch's changes. Instead, generate domain change information from the changeset data accumulated so far.

```bash
<knowledge-gate> domain-list --ids-only
```

- Use the current registry as the comparison baseline, not just the batch-local proposals
- List new domains referenced in `_proposed_domain` annotations
- List suggested path patterns for new domains
- Read `_domain_maintenance` annotations from accepted candidates and summarize them by domain / issue / suggestion
- Highlight suspicious near-duplicates among newly proposed domain names and existing registry names, especially when `_domain_maintenance` marks `near-duplicate`
- Review the processed batch PRs' `changed_files` lists and highlight repeated path prefixes that still have no domain mapping
- Do NOT auto-run domain merge/split/deprecate actions in this stage. Domain reorganization is a manual follow-up.

Append the domain summary to `.knowledge/reports/batch-YYYY-MM-DD.md`, commit, push, and refresh the Report PR body. This is the **final** commit of the run **only on full completion** — on the handoff path, the Graceful Handoff Procedure performs an additional handoff-row commit after Step 8.

**Linear ordering on budget hit:** Step 7 (Domain Change Summary) → Step 8 (Cleanup Verification) → Graceful Handoff Procedure (handoff row commit + retrigger decision) → exit 0.

### Step 8: Cleanup Verification

Run before exit (whether the exit is full completion or graceful handoff):

- Every PR with `knowledge:collected` label has at least one accepted entry **or** an explicit row in the progress table.
- Every PR still labeled `knowledge:pending` either: (a) was deferred as `insufficient`, (b) has not been reached yet (graceful handoff case), or (c) failed mid-pipeline with a non-auth error and has a `❌ failed` row.
- `.knowledge/changesets/batch-YYYY-MM-DD.json` is valid JSON.
- `.knowledge/reports/batch-YYYY-MM-DD.md` is present.
- Report PR exists and is open.

If any check fails, log it but **do not fail the workflow** — the next run will reconcile.

## Report PR Format

**Language**: Write all human-readable text in the report (headers, descriptions, labels, summaries) in the primary language of the project's agent directives (e.g., CLAUDE.md, AGENTS.md). Machine identifiers (entry IDs, domain slugs, branch names) remain as-is.

**Title**: `knowledge: batch YYYY-MM-DD — N entries added`

**Body**:

The body MUST start with the **Progress Table** (so reviewers can see partial-batch status at a glance) and is followed by the standard report sections. The progress table is append-only across self-retriggers; on every body refresh, copy it verbatim from `.knowledge/reports/batch-YYYY-MM-DD.md` — do **not** regenerate it from current label state, as that would erase handoff history.

```markdown
## Knowledge Distillery Batch Report — YYYY-MM-DD

### 진행 상황

| 항목 | 상태 |
|------|------|
| #{pr_number} | ✅ 처리 완료 ({N} accepted, run #{run_id}) |
| #{pr_number} | ⏸ 대기 중 (insufficient: {missing}, run #{run_id}) |
| run #{run_id} | ⏱ 시간 예산 도달 — 처리 N개, 남은 M개, 재트리거함 (재시도 R/MAX) |

### Summary
| Metric | Value |
|--------|-------|
| Source PRs processed | N |
| Candidates extracted | M |
| Accepted (fact / anti-pattern) | K (F / A) |
| Rejected | J |
| Insufficient evidence (deferred) | D |

### Accepted Entries

{Group entries by source PR author, then by PR number (mergedAt order within each author). For each author, create an H4 section. Under each PR, render a table of entries:}

#### @{author}
- #{pr_number}
  - [{type}] `{id}` — {one-sentence human-readable description — do NOT use the raw DB title; write a brief explanation that helps reviewers understand the entry at a glance}

### Rejected Candidates

{Same structure as Accepted Entries — group by author, then by PR:}

#### @{author}
- #{pr_number}
  - [{rejection_code}] `{id}` — {brief human-readable description of what the candidate was about and why it was rejected}

### Curation Queue (Human Review Required)
{For each curation_queue_entry:}
- `{entry_id}` <-> `{related_id}`: {reason}

{If empty: "No conflicts detected."}

### Domain Changes

**New domains proposed in this batch:**
{For each new domain from _proposed_domain annotations:}
- `{domain_name}` — {brief human-readable description of what this domain covers and which entries reference it}

{If any domains were auto-created by subagents and already exist in vault.db, list them separately}

{Structured `_domain_maintenance` findings from this batch, grouped by domain and suggestion, if any}
{Near-duplicate domain names or merge/split candidates surfaced by this batch, if any}
{Repeated unmapped path prefixes observed across this batch, if any}
{Manual follow-up suggestions for domain merge/split/path cleanup, if any}

### Vault Feedback (Existing Entry Signals)
{For each unique entry_id across all _vault_feedback annotations in accepted candidates:}
- `{entry_id}`: {signal} — {note} (from #{source_pr}, commit {memento_sha})

{If empty: "No feedback on existing entries."}

### Insufficient Evidence (Remains Pending)
{For each insufficient PR:}
- #{pr_number} "{title}": {missing sources}

{If none: "All PRs had sufficient evidence."}

---

### How to Curate This Report

This PR contains a **changeset** with new knowledge entry candidates. Entries are **not yet in vault.db** — they will be applied automatically when this PR is merged.

**To provide feedback:**
1. Leave comments on this PR referencing entry IDs from the Accepted Entries list:
   - Reject: "Reject `entry-id` — reason"
   - Modify: "Change the claim of `entry-id` to: new text"
   - Update domains: "Move `entry-id` to domain `new-domain`"
2. Post a comment with **`/curate`** to trigger automated processing
3. Review the updated changeset after curation completes
4. Merge when satisfied, or run `/curate` again for further changes

**What `/curate` does:**
- Rejected entries are marked as `rejected` in the changeset (excluded from vault insertion)
- Modified entries are updated in the changeset
- The batch report is regenerated to reflect current state
- A summary comment is posted with all actions taken

**What happens on merge:**
- A post-merge workflow applies the changeset to vault.db on main
- Only entries with `status: "accepted"` are inserted
```

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| No pending PRs | Exit 0. No branch, no PR. |
| Time budget reached | Run **Graceful Handoff Procedure**. Exit 0. |
| GitHub MCP 401/403 mid-run | Stop loop. Do **not** retrigger (token already dead). Exit non-zero. Next cron resumes. |
| Per-PR pipeline fails (non-auth) | Record `❌ failed: <error>` row, leave PR labeled `knowledge:pending`, continue with next PR. |
| Insufficient evidence on a PR | Record row, leave label `knowledge:pending`. Picked up by next batch. |
| Changeset write fails | Log error. Skip the PR. The label stays `knowledge:pending`. |
| `git push` fails (non-auth) | Retry once. If still fails, log and continue — next run reconciles. |
| GitHub MCP PR creation fails | Output report body to stdout so it's not lost. Log error. Continue (PR will be created on next commit). |
| All candidates rejected | Still create report PR (transparency). Batch report file guarantees diff. |
| Branch already exists | Checkout existing branch (supports re-runs and self-retriggers). |
| `MAX_RETRY_COUNT` reached | Append `❗ 재시도 한도 도달` row, do not retrigger, exit 0. |
| `gh pr view` fails for a single PR while collecting reviewers | Skip that PR's author, log a warning, continue with the others. |
| Resolved reviewer list is empty after filtering | Skip the `reviewers` argument on create / skip the `gh pr edit --add-reviewer` call on refresh. |
| GitHub MCP rejects the `reviewers` argument on PR creation | Retry the create call once without `reviewers`; log a warning. PR creation must still succeed. Reviewers will be reconciled via `gh pr edit --add-reviewer` on the next refresh. |
| GitHub silently drops some reviewers (no repo access, etc.) | No action — treat the result as successful. GitHub handles it. |

## Constraints

- MUST NOT auto-merge the report PR
- MUST NOT modify existing vault entries (append-only principle)
- MUST NOT insert entries into vault.db directly — write changeset file only
- MUST NOT skip the report PR even when all candidates are rejected
- PRs MUST be processed serially in `mergedAt` ascending order so the time-budget cancellation point is well-defined
- Per-PR commits MUST be atomic: changeset/report committed and pushed **before** the label flips
- Graceful handoff MUST exit 0 — it is a successful workflow run, not a failure
- 401/403 from GitHub MCP MUST NOT trigger the handoff procedure (the token is already dead)
- MUST handle partial failures gracefully
- MUST create report file `.knowledge/reports/batch-YYYY-MM-DD.md` always (even 0 entries)
- MUST create changeset file `.knowledge/changesets/batch-YYYY-MM-DD.json` always (with empty entries array if 0 candidates)
