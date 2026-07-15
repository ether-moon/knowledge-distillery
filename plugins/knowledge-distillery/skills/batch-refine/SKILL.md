---
name: batch-refine
description: "Orchestrates the Stage B distillation pipeline: discovers merged PRs labeled knowledge:pending, runs per-PR evidence collection → candidate extraction → quality gate, writes a changeset file for accepted entries, and creates a report PR for human review. Triggered on a daily schedule or manual dispatch. Use when you need to process accumulated knowledge from merged PRs, run the refinement pipeline, or manually trigger a batch distillation cycle."
---

# batch-refine — Stage B Pipeline Orchestrator

## When This Skill Runs

- Daily cron schedule via GitHub Actions
- Manual dispatch via `workflow_dispatch`
- Self-retrigger via `gh workflow run batch-refine.yml -f retry_count=N` (graceful handoff path)
- Invoked as `/knowledge-distillery:batch-refine`

## Time Budget and Self-Retrigger

The GitHub token used by this workflow expires roughly one hour after the workflow starts. Once it expires, every subsequent operation (commit, push, label change, PR update, even `gh workflow run`) will fail with 401. To avoid leaving the batch in a half-finished state, this skill must hand work off to a fresh workflow run **before** the token expires.

**Environment contract** (set by `.github/workflows/batch-refine.yml`):

| Variable | Meaning |
|----------|---------|
| `BATCH_START_TS` | Unix timestamp when this run started (proxy for token issuance time). |
| `DEADLINE_SECONDS` | Maximum elapsed seconds before refusing to start a new wave (e.g. `2700` = 45 min). |
| `WAVE_SIZE` | Maximum fresh read-only subagents per wave. Defaults to `3` when absent. |
| `RETRY_COUNT` | How many self-retriggers preceded this run. Cron starts at `0`. |
| `MAX_RETRY_COUNT` | Hard ceiling on self-retriggers per batch (e.g. `5`). |

The deadline is 45 minutes, leaving 15 minutes before the token's approximate 60-minute lifetime. **The 15-minute margin is provisional until the first wall-clock measurements from bounded waves**: it assumes enough time for the final wave tail plus a 1–2 minute handoff. This is an operating assumption, not a guarantee, and must be revisited from the wave timing logs. The only "ungraceful" path is unexpected 401 from network/MCP issues — in that case the run dies, but checkpoints from prior waves preserve everything already pushed, and the next cron run resumes naturally.

### Workflow concurrency and trigger coalescing

The workflow-level `knowledge-batch-refine` concurrency group ensures the **active run is never cancelled and only the latest pending trigger is retained**. The single pending slot intentionally coalesces stale drain requests instead of building a FIFO queue of self-retriggers, cron runs, and manual dispatches. If a cron or manual dispatch replaces a pending self-retrigger, treat it as a fresh chain with `retry_count=0`; **labels and commits are the durable state, not the retry counter**, so the replacement run resumes the same remaining work safely.

### Time budget check (before each wave)

Run this check at the **top of every wave iteration**, before issuing any Agent call:

```bash
elapsed=$(( $(date +%s) - BATCH_START_TS ))
remaining=$(( DEADLINE_SECONDS - elapsed ))
if [ "$remaining" -le 0 ]; then
  # Skip this wave. Enter the post-budget gate with this and later waves left over.
  goto_graceful_handoff=1
fi
```

If `goto_graceful_handoff=1`, stop the loop and continue to the **Post-budget completion gate** below. Only that gate's **Pending remains** branch enters the Graceful Handoff Procedure. Do **not** start a new wave after the deadline. Once a wave starts, let every Agent settle and finish that wave's auth barrier and sequential checkpoints even if the deadline passes. The provisional margin must absorb that bounded tail.

### Post-budget completion gate (before Step 7 and Step 8)

After the deadline stops new dispatches and all in-flight work settles, re-query the current `knowledge:pending` count before running Step 7, Step 8, or any numbered Graceful Handoff step.

- **Zero pending:** clear `goto_graceful_handoff`, reclassify the run as full completion, run Step 7 exactly once, then Step 8 exactly once, and exit through the normal full-completion path. Do not append a handoff row or self-retrigger.
- **Pending remains:** keep `goto_graceful_handoff=1`, skip both Step 7a and Step 7b, run Step 8 exactly once, then enter the numbered Graceful Handoff steps.

### Sequential per-PR checkpoint pattern

After a wave passes the all-settled auth barrier, every `processed`, `insufficient`, or non-auth `failed` result must checkpoint sequentially before the orchestrator advances to the next result. Subagents never perform these mutations. A crash can lose the current in-flight wave's analysis, but checkpoints pushed by earlier waves remain durable.

For each PR:

1. Append entries to `.knowledge/changesets/batch-YYYY-MM-DD.json` (or set `insufficient` flag in the report file).
2. Append a row to `.knowledge/reports/batch-YYYY-MM-DD.md` progress table (see "Report PR Progress Table" below).
3. `git add .knowledge/ && git commit -m "kd: PR #<n> processed"`.
4. `git push`.
5. Update the PR's label: `knowledge:pending` → `knowledge:collected` with the Atomic label-set transition below (or leave pending if insufficient or failed).
6. If a Report PR already exists for this batch, refresh its body from the report file. Skip if it does not yet exist (it gets created at first commit).

The order is intentional: **changeset/report committed and pushed before label flips**. If the label flips first and we crash, the next run sees `knowledge:collected` and skips the PR even though its entries are not in the changeset.

If write, commit, or push cannot complete, stop the run; never carry dirty or unpushed state into the next PR's checkpoint. If commit and push succeeded but the processed PR's atomic label update failed, the durable success row drives Step 2's label-only reconciliation on the next run.

#### Atomic label-set transition

Use this procedure for every processed PR label transition, including recovery of a pushed success checkpoint:

1. Call `issue_read(method:get_labels)` immediately before every label transition to fetch the fresh full label set.
2. Normalize the response to label names. From that fresh set, remove only `knowledge:pending`, preserve every unrelated label, append `knowledge:collected` when absent, and deduplicate `knowledge:collected`.
3. Call exactly one `issue_write(method:update, labels: transformed full set)` to replace the labels atomically.

Step 2 label-only reconciliation and Step 3d MUST use this same atomic label-set transition. MUST NOT call separate label remove/add operations. An auth failure from either `issue_read(method:get_labels)` or `issue_write(method:update)` follows Unexpected 401. A non-auth read or update failure aborts the current run immediately. Because the full-set update is atomic, a failed update leaves the original labels—including `knowledge:pending`—unchanged so the next run can reconcile it.

### Graceful Handoff Procedure

Reached only from the Post-budget completion gate's **Pending remains** branch, after Step 8 has run exactly once. The numbered steps are performed once, after the last started wave has fully settled and checkpointed (or no wave starts).

1. **Confirm progress is committed.** No Agent may still be in flight and no checkpoint may be dirty or unpushed. A persist failure takes the non-zero error path instead of being folded into handoff.
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
6. **Exit 0.** A graceful handoff is a successful workflow run, not a failure. Failing the workflow would only generate noise.

### Unexpected 401 (ungraceful path)

If `collect-evidence`, label-only reconciliation, or any required GitHub operation returns 401/403 mid-run, the token has died early. Do **not** attempt the handoff procedure — every step requires a valid token.

1. **Auth returned during read-only analysis:** first wait for every Agent in the current wave to settle. If any result is `github_auth`, discard all current-wave results before Step 3c. Every PR in that wave stays `knowledge:pending`. Do not persist an auth-dead PR's timing or outcome row; write its returned duration to the Actions log only. The same log-only rule applies to non-auth peers discarded with that wave, and `persist_duration_seconds=0`.
2. **Auth during label-only reconciliation before any wave starts:** there is no in-flight wave to settle or discard. Leave the already-pushed success checkpoint and pending label as-is, then exit non-zero directly without analysis, handoff, or retrigger.
3. **Auth after Step 3c has begun:** do not pretend the whole wave can be discarded. Abort immediately without handoff. A local commit whose push failed is not durable and its label stays pending. A pushed processed checkpoint whose atomic label transition failed is durable and is repaired by Step 2's label-only reconciliation on the next run. Earlier pushed/labeled checkpoints remain complete; later results stay pending.
4. In every auth case, skip Step 7, Step 8, and the Graceful Handoff Procedure, then exit non-zero. Never roll back a prior durable checkpoint and never self-retrigger with a dead token.

The next cron (or manual dispatch) sees the leftover `knowledge:pending` PRs and resumes from there. No retrigger from inside this run.

### Report PR Progress Table

The Report PR body opens with a per-run progress table. Each row records one PR's outcome **or** one handoff event. The table grows append-only across retriggers so reviewers see the full story.

Format:

```markdown
### 진행 상황

| 항목 | 상태 |
|------|------|
| #1234 | ✅ 처리 완료 (3 accepted, 4m12s, run #100) |
| #1235 | ⏸ 대기 중 (insufficient: manifest, 1m08s, run #100) |
| run #100 | ⏱ 시간 예산 도달 — 처리 1개, 남은 1개, 재트리거함 → run #101 |
| #1236 | ✅ 처리 완료 (2 accepted, 2m03s, run #101) |
| #1237 | ❌ failed: quality-gate error (0m41s, run #101) |
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

### Step 1: Discover Pending and Deferred PRs

```
Use GitHub MCP to list all merged PRs with the `knowledge:pending` label (fields: number, title, mergedAt).
Use GitHub MCP to list all merged PRs with the `knowledge:deferred` label (fields: number, title, author.login, mergedAt).
```

Sort pending PRs by `mergedAt` ascending (oldest first). Deferred PRs are not extraction targets; they are report-only human curation items.

Branch by queue state:

| State | Behavior |
|---|---|
| `pending > 0` | Run the normal extraction loop for pending PRs. Also include deferred PRs in the report's Deferred Queue section. |
| `pending == 0 AND deferred > 0` | Create a report-only batch. Do not run the extraction loop. Create an empty changeset (`entries: []`) and a report PR whose dynamic content is the Deferred Queue section. |
| `pending == 0 AND deferred == 0` | Log "No pending or deferred PRs" and exit 0. Do NOT create a branch, commit, or PR. |

PoC policy: even for deferred-only batches, create a new `knowledge/batch-YYYY-MM-DD` branch and Report PR using the normal batch naming rules. Updating older open report PRs is out of scope.

### Step 2: Create or Resume Working Branch

```bash
git checkout -b knowledge/batch-YYYY-MM-DD main
```

If the branch already exists (re-run or self-retrigger scenario), checkout the existing branch — do not reset it. The accumulated commits from previous runs are the source of truth for which PRs have already been processed in this batch.

When resuming an existing branch, also locate the existing Report PR (if any) and re-read its accumulated progress table before building waves. Labels remain the normal discovery signal, while a pushed success row is the recovery signal for the narrow commit/push-success + label-failure gap.

When a pending PR already has a durable `✅ 처리 완료` progress row, perform label-only reconciliation with the Atomic label-set transition, and exclude that PR from analysis waves only after its single full-set update succeeds. Do not rerun its analysis or append another changeset/report checkpoint. Insufficient and failed rows are not reconciliation successes; those PRs stay pending and remain eligible for analysis. If its fresh-label read or update returns auth failure, enter Unexpected 401; for another read/update error, leave the original labels unchanged and exit non-zero rather than duplicating its checkpoint.

### Step 3: Bounded Analysis Waves + Per-PR Atomic Checkpoints

Skip this step entirely for a deferred-only report batch (`pending == 0 AND deferred > 0` from Step 1). In that case, create `.knowledge/changesets/batch-YYYY-MM-DD.json` with `entries: []` and `.knowledge/reports/batch-YYYY-MM-DD.md` with the Deferred Queue section. For a deferred-only report batch, write the empty changeset and report file, then commit and push them before Step 4 creates the Report PR. The push creates the remote branch that Step 4's PR creation depends on.

Set `K=${WAVE_SIZE:-3}` and require a positive integer before dispatching anything. An invalid value aborts non-zero before mutation. Sort pending PRs by `mergedAt` ascending and split them into contiguous waves of at most K PRs. The tail wave may contain fewer than K. Analysis inside a wave is concurrent and read-only; the orchestrator remains the sole writer, committer, pusher, Report PR updater, and label flipper.

Waves MUST be formed from pending PRs in `mergedAt` ascending order; only the orchestrator may persist results sequentially in that same order. No subagent may modify `.knowledge/`, git state, the Report PR, or source-PR labels.

The orchestrator initializes `RUN_WALL_CLOCK_START_TS` immediately before this workflow run's first subagent dispatch. Do not initialize it during discovery or include time spent waiting between self-retriggered workflow runs.

```text
for wave_prs in pending_prs (sorted by mergedAt asc, contiguous chunks of K):
  # 3a. Time budget gate
  elapsed=$(( $(date +%s) - BATCH_START_TS ))
  if [ "$elapsed" -ge "$DEADLINE_SECONDS" ]; then
    break   # → Post-budget completion gate
  fi

  # 3b. Run read-only analysis for this wave. Every PR MUST run in a fresh subagent
  # spawned via its own Agent tool call. Each PR gets its own context window so that
  # accumulating PRs do not pollute the orchestrator's main context. Inside
  # that subagent, the three skills are invoked sequentially:
  spawn wave (K separate Agent tool calls in one message, each fresh context):
    Issue every Agent call in the same orchestrator message before waiting for any result.
    for each (slot, pr) in wave_prs:
      set PR_START_TS immediately before the first skill invocation
      invoke /knowledge-distillery:collect-evidence with pr.number
        → Evidence Bundle
        - If sufficiency.verdict == "insufficient" AND
          sufficiency.missing contains "github_auth":
            → return the github_auth outcome immediately
            after the wave settles, orchestrator: → enter "Unexpected 401" path (do NOT retrigger; token is dead)
        - If sufficiency.verdict == "insufficient" for any other reason:
            → return insufficient outcome; skip extract-candidates/quality-gate,
              persist the row in 3c, and leave the label pending in 3d
      invoke /knowledge-distillery:extract-candidates with the Evidence Bundle
        → Candidate array (may be empty)
      invoke /knowledge-distillery:quality-gate with the Candidate array
        → Verdict array
      set duration_seconds immediately after the terminal outcome is known
      return the additive per-PR result payload; do not write shared state

  # Barrier: every call settles before any durable mutation.
  Wait until every Agent call in the wave has settled.
  Before any Step 3c write, scan the complete settled result set for `outcome == "github_auth"`.
  If any auth result exists, discard every unpersisted result in the wave, including
  processed, insufficient, or failed peers; log durations and persist_duration_seconds=0,
  leave the whole wave pending, skip Step 3c/3d, Step 7/8, and handoff, then exit non-zero.

  The original invocation slot and PR number are authoritative; reject duplicate slots, foreign PR numbers, or mismatched results before persistence. On validation failure, discard the whole unpersisted wave and exit non-zero.
  A missing non-auth payload becomes that slot's `failed` result with `duration unknown` and `changed_files=[]`.

  # 3c/3d. Sole-writer checkpoint drain
  Only after the auth scan passes, process the original `wave_prs` in `mergedAt` ascending order.
  for each (pr, result) in original wave_prs order:
    # 3c. Persist this PR's outcome (atomic checkpoint)
    - Append accepted entries to .knowledge/changesets/batch-YYYY-MM-DD.json
    - Append a progress table row with duration + per-PR detail to .knowledge/reports/batch-YYYY-MM-DD.md
    - Append the result's compact KD_BATCH_PR_META line immediately after its per-PR detail
    - git add .knowledge/ && git commit -m "kd: PR #<n> processed"
    - git push (creates the branch on first commit; updates Report PR body via Step 4 if it exists)

    If a Step 3c write or commit fails, or if `git push` still fails after one retry, abort the batch immediately with a non-zero exit. Never continue to the next PR with dirty files or an unpushed local commit. Do not flip this or any later PR's label.

    # 3d. Replace the label set atomically (only after the commit landed)
    - For `processed`, run the Atomic label-set transition: one fresh
      `issue_read(method:get_labels)`, transform the full set, then exactly one
      `issue_write(method:update, labels: transformed full set)`
    - For `insufficient` or `failed`, leave label as `knowledge:pending`
```

#### Per-PR result and timing contract

The per-PR subagent MUST measure its own `duration_seconds`. Start immediately before `collect-evidence`; stop immediately after the terminal `processed`, `insufficient`, `failed`, or `github_auth` outcome is known. Catch a non-auth pipeline error and return `failed` when the subagent is still able to return a payload. Every terminal payload uses this additive contract (`changed_files` and `verdicts` may be empty when they do not apply):

```json
{
  "pr_number": 1234,
  "outcome": "processed|insufficient|failed|github_auth",
  "duration_seconds": 252,
  "changed_files": ["path/to/file"],
  "verdicts": []
}
```

Format a known duration as `XmYs` in the progress status cell. Insufficient and non-auth failure rows MUST also include the duration. If the subagent crashes without returning a payload, the orchestrator MUST NOT estimate the duration; record `duration unknown`. A `github_auth` payload follows the Unexpected 401 path: log every returned duration in that wave, but persist no row, timing, metadata, candidate, or count from any current-wave result.

For every non-auth result persisted by Step 3c (`processed`, `insufficient`, or `failed`), serialize the result payload's PR identity and changed-file list as compact valid JSON on exactly one hidden report line immediately after that PR's detail:

```markdown
<!-- KD_BATCH_PR_META {"pr_number":1234,"changed_files":["path/to/file"]} -->
```

Normalize a missing `changed_files` field to `[]` before serializing the compact JSON. Generate the JSON with a JSON serializer so unusual path characters remain valid; do not construct it by string interpolation. Never write a `KD_BATCH_PR_META` marker for a `github_auth` result. The marker is part of the same atomic report commit as the human-readable row, and Report PR body refreshes MUST preserve it verbatim.

#### Orchestrator timing and Actions logs

Run wall-clock timing belongs to the orchestrator. It spans the current workflow run's first subagent dispatch through completion of the last PR's Step 3c commit and push. Because checkpoints drain as `3c → 3d → 3c`, it naturally includes intermediate label transitions; only the final PR's post-push label transition is outside the interval. It excludes discovery before dispatch, self-retrigger wait time, and work in other workflow runs. The orchestrator MUST NOT derive this value from `Σ(per-PR duration_seconds)`.

Record the value in the Summary as `| 총 소요시간(wall-clock) | XmYs (run #N) |`. If this workflow run spawned no per-PR subagent, record `| 총 소요시간(wall-clock) | N/A (run #N) |` instead.

Log every wave as `wave_duration_seconds=<dispatch-to-all-settled> persist_duration_seconds=<first-Step-3c-write-to-last-commit-push> run_elapsed_seconds=<BATCH_START_TS-to-now>`. The persist interval follows the actual checkpoint drain, so intermediate Step 3d label transitions are naturally included; only the final PR's post-push label transition falls after its terminal boundary. For an auth-dead wave, log `persist_duration_seconds=0` because no Step 3c write may begin. At handoff and completion, also log `run_elapsed_seconds` from `BATCH_START_TS` so the provisional token-expiry margin can be evaluated.

**Why bounded waves?** Unbounded or matrix fan-out still violates the single-writer checkpoint contract and makes token-expiry truncation unbounded. K=3 parallelizes only read-only analysis inside one orchestrator run. The all-settled auth barrier prevents partial-wave persistence, and mergedAt-ordered sole-writer checkpoints preserve deterministic durable state. The tradeoff is explicit: a runner timeout or hung Agent can lose up to one wave of analysis instead of one PR; labels remain pending so the next run re-analyzes at most K PRs.

**Partial failure handling:** If a single PR's pipeline raises (extract-candidates crash, quality-gate failure, etc.) and the cause is **not** GitHub auth (401/403), normalize or retain its `failed` result, then after the barrier record `❌ failed: <error> (<duration or duration unknown>, run #<id>)` in that PR's mergedAt-ordered checkpoint. Do not flip its label; continue draining the remaining settled results and later waves. PR-level failures MUST NOT block the rest of the batch.

### Step 4: Maintain Report PR (per-commit — cheap)

After the **first** PR commits successfully and pushes the branch, ensure a Report PR exists. After every subsequent PR commit, refresh the PR body from `.knowledge/reports/batch-YYYY-MM-DD.md`. Both operations are cheap: they read the already-committed report file and touch only this batch's PR.

**Create or refresh the Report PR:**

```text
If no PR with head=knowledge/batch-YYYY-MM-DD exists:
  Use GitHub MCP to create a PR (title/body/base/head per "Report PR Format" below).
  Do NOT compute or pass `reviewers` here — the reviewer set is reconciled once at batch completion (Step 7b).
Else:
  Use GitHub MCP to update the existing PR's body from the latest report file.
```

**Do NOT run reviewer reconciliation, Deferred Queue collection, or triage metric collection on every per-PR refresh.** Each is O(all labeled PRs); running them per PR multiplies that by the batch size and by every self-retrigger — the exact scan cost this pipeline is meant to reduce. They run **once, at batch completion** (Step 7b). Keep each sequential checkpoint cheap so throughput scales with queue size.

**MUST NOT auto-merge the report PR.** Human review is the intervention point.

### Step 5: Handle Insufficient Evidence PRs

For PRs where collect-evidence returned `insufficient`:

1. Keep the PR labeled `knowledge:pending` (no label flip in Step 3d).
2. The progress table row is `⏸ 대기 중 (insufficient: <missing>, <duration>, run #<id>)`.
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

### Step 7: Domain Change Summary + Batch-Completion Reconciliation (runs ONLY on full completion — skip entirely on graceful handoff)

Run this only after the wave loop exhausts the discovered work list, for a deferred-only report batch, or after the zero-pending reclassification in the Post-budget completion gate. On a graceful-handoff exit (`goto_graceful_handoff=1`), skip both Step 7a and Step 7b entirely and proceed directly to Step 8.

#### Step 7a: Domain Change Summary (runs ONLY on full completion — skip on graceful handoff)

Since entries are not yet inserted into vault.db, `domain-report` cannot reflect this batch's changes. Instead, generate domain change information from the changeset data accumulated so far.

```bash
<knowledge-gate> domain-list --ids-only
```

- Use the current registry as the comparison baseline, not just the batch-local proposals
- List new domains referenced in `_proposed_domain` annotations
- List suggested path patterns for new domains
- Read `_domain_maintenance` annotations from accepted candidates and summarize them by domain / issue / suggestion
- Highlight suspicious near-duplicates among newly proposed domain names and existing registry names, especially when `_domain_maintenance` marks `near-duplicate`
- Parse every accumulated `KD_BATCH_PR_META` line from `.knowledge/reports/batch-YYYY-MM-DD.md` and deduplicate changed paths by `(pr_number, path)`. Use that persisted set — never transient current-run subagent memory — to highlight repeated path prefixes that still have no domain mapping. Continue to read `_proposed_domain` and `_domain_maintenance` only from accepted changeset entries; the hidden metadata does not replace those annotations.
- Do NOT auto-run domain merge/split/deprecate actions in this stage. Domain reorganization is a manual follow-up.

#### Step 7b: Batch-completion reconciliation (runs ONLY on full completion — skip on graceful handoff)

Reviewer reconciliation, Deferred Queue collection, and triage metric collection are each O(all labeled PRs). Run them **once**, on the run that completes the batch (all pending PRs processed, or a deferred-only report batch). On a graceful-handoff exit (`goto_graceful_handoff=1`), **skip Step 7b entirely** — an intermediate retrigger must not pay the O(N) scan; the final run that completes the batch runs it. Triage metrics are trend-only (see the Report's "운영 Metric" note), so surfacing them only on the completing run is acceptable, and reviewer assignment only needs to be correct at the point a human reviews (batch complete).

**Reviewer reconciliation:** Source PR authors of accumulated changeset entries get review-requested on the Report PR so they get feedback on how their PR was distilled.

1. Iterate every entry in `.knowledge/changesets/batch-YYYY-MM-DD.json` (`entries[]` — every `status` is included; entries of every status share the same `data.evidence[]` shape). Collect every PR number from `entries[].data.evidence[].ref` (e.g., `"#27"` → `27`).
2. Deduplicate the PR-number set.
3. For each unique PR number, resolve the author and bot flag using the `gh` CLI (not GitHub MCP — the `jq` pipe format below is what the next step parses):
   ```bash
   gh pr view <num> --json author --jq '.author.login + "|" + (.author.is_bot | tostring)'
   ```
   On error for a single PR, log a warning and skip — continue collecting other authors.
4. Filter the resolved authors: drop entries where `is_bot == true`, drop empty / null logins (deleted accounts), deduplicate by login.
5. Add the filtered set to the Report PR idempotently: `gh pr edit <pr_number> --add-reviewer <login1>,<login2>,...`. Re-requesting an already-requested reviewer is a no-op. Skip the call when the list is empty.

**Deferred Queue collection:**

```
Use GitHub MCP to list merged PRs with the `knowledge:deferred` label (fields: number, title, author.login). For each PR, fetch issue comments and locate the latest `<!-- KD_TRIAGE_DECISION_START -->` block. Extract the JSON payload's `reason` field.
```

- Fill the Report PR Format's "Deferred Queue (Human Curation Required)" table.
- If none exist, render the section with the empty-state sentence.
- This collection is read-only and MUST NOT run `collect-evidence`, `extract-candidates`, or `quality-gate`.
- In a deferred-only report batch, this section is the report's only dynamic review content; Summary and candidate sections should explicitly show zero/empty values.

**Triage metric collection:**

All Layer 2 decisions (`skip`, `extract`, `defer`) are recorded in PR comments as `KD_TRIAGE_DECISION` blocks by `mark-evidence`.

1. Query merged PRs with `knowledge:skipped`; parse their latest `KD_TRIAGE_DECISION` blocks.
   - `layer == "L1"` contributes to Layer 1 skip count grouped by `rule`.
   - `layer == "L2" AND decision == "skip"` contributes to Layer 2 skip count grouped by `reason`.
2. Query merged PRs with `knowledge:deferred`; parse latest decision blocks where `layer == "L2" AND decision == "defer"`.
3. Query merged PRs with `knowledge:pending` and merged PRs with `knowledge:collected` separately, union the results, then parse latest decision blocks where `layer == "L2" AND decision == "extract"`. (These two labels are mutually exclusive, so a single both-labels query would always return zero — they must be queried as two separate sets.)
4. Use the pending PR count from Step 1 as `knowledge:pending queue length at batch start`.
5. Use the total `knowledge:skipped` result count as cumulative skipped PR count.
6. For recent positive-recall regression rate, read the newest `.knowledge/reports/triage-backtest-YYYY-MM-DD.md` if present. If absent, render `N/A`.

Append the domain summary, reconciled Deferred Queue, and triage metrics to `.knowledge/reports/batch-YYYY-MM-DD.md`, commit, push, and refresh the Report PR body. This Step 7 commit is the final commit of the run and happens only on full completion. On the handoff path, do not write any Step 7 content; the Graceful Handoff Procedure performs the run's final handoff-row commit after Step 8.

**Linear ordering on budget hit:** Post-budget completion gate → zero pending: Step 7 exactly once → Step 8 exactly once → normal full-completion exit; pending remains: skip Step 7a and Step 7b → Step 8 exactly once → numbered Graceful Handoff steps → exit 0.

### Step 8: Cleanup Verification

Run before exit (whether the exit is full completion or graceful handoff):

- Every PR with `knowledge:collected` label has at least one accepted entry **or** an explicit row in the progress table.
- Every PR still labeled `knowledge:pending` either: (a) was deferred as `insufficient`, (b) has not been reached yet (graceful handoff case), or (c) failed mid-pipeline with a non-auth error and has a `❌ failed` row.
- `.knowledge/changesets/batch-YYYY-MM-DD.json` is valid JSON.
- `.knowledge/reports/batch-YYYY-MM-DD.md` is present.
- Every persisted non-auth PR detail has one valid `KD_BATCH_PR_META` line; auth-dead PRs have none.
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
| #{pr_number} | ✅ 처리 완료 ({N} accepted, {duration}, run #{run_id}) |
| #{pr_number} | ⏸ 대기 중 (insufficient: {missing}, {duration}, run #{run_id}) |
| #{pr_number} | ❌ failed: {error} ({duration or duration unknown}, run #{run_id}) |
| run #{run_id} | ⏱ 시간 예산 도달 — 처리 N개, 남은 M개, 재트리거함 (재시도 R/MAX) |

### Summary
| Metric | Value |
|--------|-------|
| Source PRs processed | N |
| Candidates extracted | M |
| Accepted (fact / anti-pattern) | K (F / A) |
| Rejected | J |
| Insufficient evidence (deferred) | D |
| 총 소요시간(wall-clock) | XmYs (run #N) |

### 운영 Metric (Triage)

이번 batch 기준 누적값입니다. 추세 추적용입니다.

| Metric | 값 |
|--------|----|
| Layer 1 skip 수 | {N} ({bot-dependency-update=N, lockfile-only=N, generated-only=N, auto-revert=N, docs-only=N, i18n-only=N}) |
| Layer 2 skip 수 | {N} |
| Layer 2 defer 수 | {N} |
| Layer 2 extract 수 | {N} |
| `knowledge:pending` 큐 길이 (batch 시작 시) | {N} |
| `knowledge:skipped` 누적 PR 수 (전체) | {N} |
| 최근 positive-recall regression rate (수동 backtest) | {X.X% or N/A} |

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

{Retain one compact hidden metadata line for every persisted non-auth PR outcome, in append order. These lines are machine-readable cross-run state and MUST remain byte-for-byte unchanged during Report PR refresh or curation:}
<!-- KD_BATCH_PR_META {"pr_number":1234,"changed_files":["path/to/file"]} -->

### Deferred Queue (Human Curation Required)

triage가 `defer` 판정을 내린 PR입니다. 사람이 라벨을 변경해야 다음 batch에 반영됩니다.

| PR | 작성자 | 제목 | Defer 사유 |
|----|--------|------|------------|
| #{pr_number} | @{author} | {title} | {reason from KD_TRIAGE_DECISION block} |

{If empty: "No deferred PRs."}

**사람 검토 가이드:**
- 지식 가치가 있다고 판단 → 라벨을 `knowledge:deferred` → `knowledge:pending` 으로 변경.
- 영구 제외 → 라벨을 `knowledge:deferred` → `knowledge:skipped` 로 변경. 사유를 PR 코멘트에 남기는 것을 권장.

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
| No pending or deferred PRs | Exit 0. No branch, no PR. |
| No pending PRs but deferred PRs exist | Create a report-only batch with empty changeset and Deferred Queue section. |
| Time budget reached | MUST enter the **Post-budget completion gate** first. Zero pending → full completion (Step 7 then Step 8); pending remains → Step 8 then **Graceful Handoff Procedure**. Exit 0. |
| GitHub auth failure during read-only wave analysis | Wait for all Agents to settle, discard every current-wave result before Step 3c, log `persist_duration_seconds=0`, do **not** handoff/retrigger, and exit non-zero. Prior-wave checkpoints remain durable. |
| GitHub auth failure during label-only reconciliation | No wave exists to settle. Leave the pushed checkpoint and original labels unchanged, skip handoff/retrigger, and exit non-zero directly. |
| GitHub auth failure after Step 3c begins | Abort without handoff/retrigger. Preserve earlier durable checkpoints; leave unpushed/later work pending. A pushed success with an incomplete atomic label update uses label-only reconciliation next run. |
| Per-PR pipeline fails (non-auth) | After the wave passes the auth barrier, record `❌ failed: <error> (<duration or duration unknown>, run #<id>)` in mergedAt order, leave the PR pending, and continue the checkpoint drain. |
| Insufficient evidence on a PR | Record row, leave label `knowledge:pending`. Picked up by next batch. |
| Changeset/report write or `git commit` fails | Abort immediately with non-zero. Do not continue with dirty state and do not flip the label. |
| `git push` fails (non-auth) | Retry once. If it still fails, abort immediately with non-zero; never let an unpushed commit flow into the next checkpoint. |
| Fresh-label read fails (non-auth) | Abort immediately without a label write. The original full label set remains unchanged. |
| Atomic full-set label update fails (non-auth) | Abort immediately. The update cannot partially remove `knowledge:pending`; the original set remains available for next-run label-only reconciliation. |
| GitHub MCP PR creation fails | Output report body to stdout so it's not lost. Log error. Continue (PR will be created on next commit). |
| All candidates rejected | Still create report PR (transparency). Batch report file guarantees diff. |
| Branch already exists | Checkout existing branch (supports re-runs and self-retriggers). |
| `MAX_RETRY_COUNT` reached | Append `❗ 재시도 한도 도달` row, do not retrigger, exit 0. |
| `gh pr view` fails for a single PR while collecting reviewers | Skip that PR's author, log a warning, continue with the others. |
| Resolved reviewer list is empty after filtering | Skip the `gh pr edit --add-reviewer` call in Step 7b. |
| `gh pr edit --add-reviewer` fails or a login is rejected at completion (Step 7b) | Log a warning and continue — reviewer assignment is best-effort and not correctness-critical; the PR is already created. |
| GitHub silently drops some reviewers (no repo access, etc.) | No action — treat the result as successful. GitHub handles it. |

## Constraints

- MUST NOT auto-merge the report PR
- MUST NOT modify existing vault entries (append-only principle)
- MUST NOT insert entries into vault.db directly — write changeset file only
- MUST NOT skip the report PR even when all candidates are rejected
- Analysis waves MUST contain at most `${WAVE_SIZE:-3}` PRs and MUST be dispatched only at wave-boundary time-budget cancellation points
- Every PR analysis MUST run in its own fresh, read-only subagent; all Agent calls for one wave MUST be issued in one orchestrator message
- The orchestrator MUST wait for the whole wave to settle and pass the whole-wave auth barrier before any Step 3c write
- Waves MUST preserve `mergedAt` input order, and the orchestrator MUST be the sole writer that checkpoints results sequentially in that order
- Per-PR commits MUST be atomic: changeset/report committed and pushed **before** the label flips
- A write/commit/push failure MUST abort before another PR checkpoint; a pushed success row with a failed atomic label transition MUST use label-only reconciliation on resume
- Every processed label transition MUST use one fresh `issue_read(method:get_labels)` followed by exactly one full-set `issue_write(method:update)`
- Label transformation MUST remove only `knowledge:pending`, preserve unrelated labels, and add/deduplicate `knowledge:collected`; separate remove/add calls are forbidden
- Graceful handoff MUST exit 0 — it is a successful workflow run, not a failure
- 401/403 from GitHub MCP MUST NOT trigger the handoff procedure (the token is already dead)
- MUST handle partial failures gracefully
- MUST create report file `.knowledge/reports/batch-YYYY-MM-DD.md` always (even 0 entries)
- MUST create changeset file `.knowledge/changesets/batch-YYYY-MM-DD.json` always (with empty entries array if 0 candidates)
