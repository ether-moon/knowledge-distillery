---
description: "Extracts evidence identifiers from a merged PR and posts an Evidence Bundle Manifest comment. Stage A of the distillation pipeline — lightweight, identifier-only, no content fetching. Triggered on PR merge or manual invocation."
---

# mark-evidence — Stage A Evidence Marking

## When This Skill Runs

- A PR has been merged to `main` or `master` (GitHub Actions `pull_request.closed` + `merged == true`)
- Manual invocation via `/knowledge-distillery:mark-evidence <pr_number>`
- Invoked as `/knowledge-distillery:mark-evidence`

## Prerequisites

- GitHub MCP server configured with `pull_requests,issues,labels` toolsets
- `git` with access to `refs/notes/commits` (memento notes)
- Linear MCP server (optional — graceful degradation if unavailable)

## Allowed Tools

Use ONLY: GitHub MCP (read + write), `git`, Linear MCP (read-only), `Bash`, `Read`, `Glob`, `Grep`.
Do NOT use any other tools. Do NOT write files. Do NOT access vault.db or `knowledge-gate` CLI.

## Input

| Field | Source | Format |
|-------|--------|--------|
| PR number | GitHub Actions event context or manual argument | Integer |
| Repository | GitHub Actions context or derived via GitHub MCP | `owner/repo` |
| Merge SHA | GitHub Actions context or derived via GitHub MCP | Hex string |

## Output

| Artifact | Format | Consumer |
|----------|--------|----------|
| PR comment | Evidence Bundle Manifest (per [evidence-manifest.spec.md](reference/evidence-manifest.spec.md)) | `/knowledge-distillery:collect-evidence` |
| PR label | `knowledge:pending` added | `/knowledge-distillery:batch-refine` (discovery) |

## Execution Steps

Follow these steps in exact order. Do not skip steps. Do not reorder.

### Step 1: Idempotency Check

```
Use GitHub MCP to list all issue-level comments on PR #{pr_number}. Extract each comment's body text.
```

Scan all comment bodies for the delimiter `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`.

**If Manifest comment exists:**

1. Check if the `knowledge:pending` label is present on the PR:
   ```
   Use GitHub MCP to get PR #{pr_number} labels. Check if `knowledge:pending` is present.
   ```
2. If the label is missing (partial failure on a previous run) — re-add it:
   ```
   Use GitHub MCP to add the `knowledge:pending` label to PR #{pr_number}.
   ```
   Then exit with success.
3. If the label is already present — exit with success. Do not post a duplicate comment. Do not modify labels.

**If no Manifest comment exists** — proceed to Step 2.

### Step 2: Gather PR Metadata

```
Use GitHub MCP to fetch PR #{pr_number} metadata: title, body, commits (with SHAs and messages), changed files, base branch, and merge commit SHA.
```

Extract from the response:
- `title` — PR title string
- `body` — PR body string
- `commits` — array of commit objects (each has `oid` and `messageHeadline`, `messageBody`)
- `files` — array of changed file objects; extract relative file paths into `changed_files`
- `baseRefName` — target branch name (e.g., `main`)
- `mergeCommit.oid` — merge commit SHA

### Step 3: Extract Linear Issue IDs

Apply the regex pattern `/\b([A-Z]+-\d+)\b/g` to these sources, in order:

1. PR title — record matches with `source: "pr_title"`
2. PR body — record matches with `source: "pr_body"`
3. Each commit message (headline + body) — record matches with `source: "commit_message"`

Deduplicate by ID, keeping the first `source` encountered for each unique ID.

### Step 4: Discover Slack Links

Slack links can appear in two independent sources: PR text and Linear issues. Collect from both.

**4a. Extract Slack links from PR body and comments (independent of Linear):**

1. Scan the PR body (from Step 2) for Slack permalink URLs matching the pattern: `https://*.slack.com/archives/*/p*`
2. Record each discovered URL with `source: "pr_body"`
3. Also scan PR issue-level comments for the same pattern; record those with `source: "pr_comment"`

**4b. Extract Slack links from Linear issues (requires Linear MCP):**

For each Linear issue ID found in Step 3:

1. Query the Linear MCP for issue details (description/body and comments)
2. Scan the issue body and all comments for Slack permalink URLs matching the pattern: `https://*.slack.com/archives/*/p*`
3. Record each discovered URL with `source: "linear_issue"`

**Graceful degradation:** If Linear MCP is unavailable (connection error, timeout, not configured), skip Step 4b only. Slack links from Step 4a are still collected. This is NOT a failure — log a warning and continue.

**4c. Deduplicate** all collected Slack URLs by URL, keeping the first `source` encountered.

### Step 5: Check git-memento Notes

Ensure notes refs are available first:

```bash
git fetch origin refs/notes/commits:refs/notes/commits 2>/dev/null || true
```

Then, for each commit SHA in the PR (from Step 2):

```bash
git notes --ref=refs/notes/commits show {sha}
```

- If the command succeeds (exit code 0), record: `{ "sha": "{short_sha_7chars}", "has_notes": true }`
- If the command fails (no notes exist), skip that commit silently. This is expected, not an error.

### Step 6: Check Greptile Reviews

```
Use GitHub MCP to list all review comments (inline on diff) for PR #{pr_number}. Filter for comments by users whose login contains "greptile" (case-insensitive). Count the matching comments.
```

Also check issue comments:

```
Use GitHub MCP to list all issue-level comments on PR #{pr_number}.
```

Look for comments from users whose login contains "greptile" (case-insensitive).

- If found, count the review comments and record: `{ "review_id": "greptile-pr-{pr_number}", "comment_count": {count} }`
- If not found, the `greptile` array stays empty

### Step 7: Compose the Manifest

Build the Evidence Bundle Manifest with the following structure. All fields are required. Empty arrays are valid — never omit a field.

**Human-readable summary table:**

```markdown
## Evidence Bundle Manifest

| Category | Count | Details |
|----------|-------|---------|
| Linear Issues | {n} | {comma-separated IDs, or "—"} |
| Slack Threads | {n} | {comma-separated channel names extracted from URLs, or "—"} |
| Git Sessions | {n} | {n} commits with memento notes |
| Greptile Reviews | {n} | {total comment_count} review comments, or "—" |
```

**Machine-parseable JSON** (inside HTML comment delimiters, using actual code fences):

```
<!-- EVIDENCE_BUNDLE_MANIFEST_START -->
```json
{
  "version": "1",
  "pr": {
    "number": <integer>,
    "merge_sha": "<full or 7+ char hex SHA>",
    "base_branch": "<branch name>",
    "changed_files": ["<relative path>", ...]
  },
  "identifiers": {
    "linear": [
      { "id": "<PROJECT-NNN>", "source": "<source_type>" }
    ],
    "slack": [
      { "url": "<slack permalink>", "source": "<source_type>" }
    ],
    "memento": [
      { "sha": "<7+ char hex>", "has_notes": true }
    ],
    "greptile": [
      { "review_id": "<id>", "comment_count": <integer> }
    ]
  },
  "collected_at": "<ISO 8601 timestamp>"
}
```
<!-- EVIDENCE_BUNDLE_MANIFEST_END -->
```

**Validation before posting — verify ALL of these:**

| Rule | Check |
|------|-------|
| V1 | `version` is `"1"` |
| V2 | `pr.merge_sha` matches `/^[0-9a-f]{7,40}$/` |
| V3 | `pr.number` is a positive integer |
| V4 | `pr.changed_files` is a non-empty array of strings |
| V5 | Each `linear[].id` matches `/^[A-Z]+-\d+$/` |
| V6 | Each `slack[].url` matches `https://*.slack.com/archives/*/p*` |
| V7 | Each `memento[].sha` matches `/^[0-9a-f]{7,40}$/` |
| V8 | `collected_at` is valid ISO 8601 |

If any validation fails, fix the data before posting. Do not post an invalid Manifest.

### Step 8: Post Comment and Add Label

Ensure the label exists:

```
Use GitHub MCP to ensure the label `knowledge:pending` exists on the repository (description: "PR awaiting knowledge distillation", color: "FBCA04"). If it already exists, continue without error.
```

Post the Manifest as a PR comment:

```
Use GitHub MCP to post a comment on PR #{pr_number} with the full Manifest content as the comment body.
```

Add the `knowledge:pending` label:

```
Use GitHub MCP to add the `knowledge:pending` label to PR #{pr_number}.
```

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| Linear MCP unavailable | Continue without Slack links. `linear` array retains IDs found in PR text. `slack` array contains only URLs from PR body (if any). Log a warning. |
| Linear issue ID not found in Linear | Keep the ID in the `linear` array (it was in PR text). Log a warning. |
| `git notes show` fails | Skip that commit's memento entry. Not an error. |
| No identifiers found at all | Post Manifest with all empty arrays. Add `knowledge:pending` label. This is valid. |
| PR comment posting fails | This is the critical output — report failure. |
| PR already has Manifest comment | Exit with success (idempotent). No action taken. |

## Constraints

- MUST NOT fetch actual evidence content (no reading Linear issue bodies for knowledge extraction — only for Slack link discovery)
- MUST NOT modify any files in the repository
- MUST NOT interact with vault.db or `knowledge-gate` CLI
- MUST NOT make judgments about evidence sufficiency (that is Stage B's job)
- MUST be idempotent — safe to re-run on the same PR
- MUST post exactly one Manifest comment per PR
- MUST ensure the human-readable summary table is consistent with the JSON data
