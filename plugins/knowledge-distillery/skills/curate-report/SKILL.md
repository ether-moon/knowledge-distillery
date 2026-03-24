---
description: "Processes reviewer feedback on Report PRs to selectively accept, reject, or modify changeset entries. Triggered by /curate comment on knowledge/batch-* PRs. Reads PR comments, interprets natural language feedback, updates the changeset file, regenerates report, and commits."
---

# curate-report — Report PR Curation

## When This Skill Runs

- Triggered by `/curate` comment on a Report PR (branch: `knowledge/batch-*`)
- GitHub Actions `issue_comment` trigger
- Can also be invoked manually: `/knowledge-distillery:curate-report`

## Prerequisites

- GitHub MCP server configured with `pull_requests,issues` toolsets
- `jq` CLI available
- `git` CLI available
- Must be checked out on the Report PR branch

## Execution Steps

### Step 1: Identify the Report PR

Use GitHub MCP to read the PR that triggered the workflow:
- Extract the PR number (from workflow context or invocation argument)
- Read the PR details: branch name, state, body
- **Validate**: branch starts with `knowledge/batch-` — if not, post a comment "This is not a Report PR. Curation is only available on knowledge/batch-* branches." and exit
- **Validate**: PR state is `open` — if merged or closed, post "This PR is already merged/closed. Curation is only available on open PRs." and exit
- Extract the batch date from the branch name (e.g., `knowledge/batch-2026-03-24` → `2026-03-24`)
- Parse the "Accepted Entries" table from the PR body to build the **entry ID whitelist** — only these entries may be modified

### Step 2: Ensure Correct Branch and Locate Changeset

```bash
git checkout <pr-branch>
git pull origin <pr-branch>
```

Locate the changeset file:
```bash
ls .knowledge/changesets/batch-YYYY-MM-DD.json
```

**Validate**: Changeset file exists and is valid JSON. If not found, post an error comment and exit.

### Step 3: Read PR Comments

Use GitHub MCP to list all comments on the PR:
- Collect all comments (both issue comments and review comments)
- **Filter out**:
  - The `/curate` trigger comment itself
  - Bot-generated comments (author is a bot or github-actions)
  - Previous curation summary comments (contain "## Curation Complete")
- The remaining comments are **reviewer feedback**

### Step 4: Classify Feedback into Actions

For each reviewer comment, interpret the natural language intent and classify into actions:

| Action | Examples | Result |
|--------|----------|--------|
| **REJECT** | "reject `entry-x`", "remove `entry-x`", "`entry-x` is wrong" | Mark entry as rejected in changeset |
| **UPDATE** | "change claim of `entry-x` to: ...", "update title of `entry-x`" | Modify entry data in changeset |
| **KEEP** | "looks good", "approve", general discussion | No action |
| **UNRESOLVED** | Ambiguous, unclear reference, contradictory | Flag for human clarification |

Rules:
- Entry IDs must match the whitelist from Step 1. If a comment references an entry not in this batch, classify as UNRESOLVED with note "Entry not in this batch"
- If the same entry has conflicting feedback (one comment says reject, another says update), classify as UNRESOLVED
- If no entry ID can be identified in the comment, classify as KEEP (general discussion)

Build an **action plan** — a structured list of (action, entry_id, details/reason).

### Step 5: Execute Reject Actions

For each REJECT action, modify the changeset JSON:

```bash
# Read changeset, update entry status to "rejected"
jq '(.entries[] | select(.data.id == "<entry-id>")) |= . + {"status": "rejected", "reject_reason": "<reviewer reason>"}' \
  .knowledge/changesets/batch-YYYY-MM-DD.json > tmp && mv tmp .knowledge/changesets/batch-YYYY-MM-DD.json
```

- If the entry is already rejected: record as "Already rejected (skipped)"
- If entry ID not found in changeset: record as "Failed — entry not in changeset"

### Step 6: Execute Update Actions

For each UPDATE action, modify the entry's `data` fields in the changeset JSON:

```bash
# Read changeset, update specific fields in the entry's data object
jq '(.entries[] | select(.data.id == "<entry-id>") | .data.claim) = "<new claim>"' \
  .knowledge/changesets/batch-YYYY-MM-DD.json > tmp && mv tmp .knowledge/changesets/batch-YYYY-MM-DD.json
```

- Only modify fields that the reviewer requested to change
- If the entry is already rejected: record as "Failed — cannot update rejected entry"
- If update fails: record as "Failed" with error message

### Step 7: Regenerate Batch Report

After all actions are executed, regenerate `.knowledge/reports/batch-YYYY-MM-DD.md` to reflect the current changeset state.

Read entry data from the changeset file:
```bash
jq '.entries[]' .knowledge/changesets/batch-YYYY-MM-DD.json
```

Write the updated report with the same structure as the original, but:
- **Accepted entries** (status == "accepted") remain in "Accepted Entries" table
- **Rejected entries** (status == "rejected") are moved to a new "Rejected Entries (via Curation)" section with their reject reasons
- Add a "Curation Log" section at the end listing all actions taken:
  ```markdown
  ### Curation Log
  | Action | Entry ID | Details | Timestamp |
  |--------|----------|---------|-----------|
  | Rejected | entry-x | Reason: reviewer said ... | 2026-03-24T12:00:00Z |
  | Updated | entry-y | Changed: claim | 2026-03-24T12:00:00Z |
  ```

Also update the PR body's "Summary" table metrics (accepted count, etc.) to reflect the new state. Use GitHub MCP to update the PR body.

### Step 8: Commit and Push

```bash
git add .knowledge/changesets/ .knowledge/reports/
git commit -m "knowledge: curate batch YYYY-MM-DD — N rejected, M updated"
git push origin <branch>
```

If push fails (e.g., concurrent curate), try:
```bash
git pull --rebase origin <branch>
git push origin <branch>
```

### Step 9: Post Summary Comment

Use GitHub MCP to post a comment on the PR:

```markdown
## Curation Complete

| Action | Entry ID | Details |
|--------|----------|---------|
| Rejected | `entry-x` | Reason: ... |
| Updated | `entry-y` | Changed: claim |
| Kept | `entry-z` | No changes requested |

{If any UNRESOLVED:}
### Unresolved Feedback
The following comments could not be processed automatically:
- "{original comment text}" — Reason: ambiguous / entry not in batch / conflicting feedback

---
Changeset updated. Please review the updated diff.
Run `/curate` again after leaving additional feedback, or merge when satisfied.
```

If no actionable feedback was found:
```markdown
## Curation Complete — No Changes

No actionable feedback found. All entries remain as-is.
To provide feedback, leave comments referencing specific entry IDs and run `/curate` again.
```

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| Not a Report PR branch | Post comment explaining this, exit |
| PR is merged/closed | Post comment explaining this, exit |
| Changeset file not found | Post error comment, exit |
| No actionable feedback | Post "no changes" comment, exit |
| Single reject/update fails | Log error, continue with remaining actions, report failure in summary |
| All actions fail | Post summary with all failures, suggest manual intervention |
| git push fails after rebase | Post error comment, output manual instructions |
| GitHub MCP unavailable | Abort — cannot read comments or post summary without it |

## Constraints

- MUST operate on the PR branch, not main
- MUST NOT auto-merge the PR
- MUST NOT modify entries that are not in this batch's whitelist
- MUST NOT modify vault.db — all changes go to the changeset file
- MUST post a summary comment after each curation run
- MUST regenerate the report to reflect current changeset state
- MUST handle partial failures (one failed action does not block others)
- MUST treat ambiguous feedback as UNRESOLVED rather than guessing
