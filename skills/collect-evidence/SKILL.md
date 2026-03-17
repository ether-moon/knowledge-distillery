---
description: "Collects the actual content of all evidence sources identified in a PR's Evidence Bundle Manifest and produces a structured Evidence Bundle. Stage B step 1 — transforms identifier references into full content for downstream candidate extraction. Called by batch-refine orchestrator per PR."
---

# collect-evidence — Stage B-1 Evidence Collection

## When This Skill Runs

- Called by `/knowledge-distillery:batch-refine` orchestrator as a subagent per PR
- Runs within the same subagent context (Evidence Bundle is returned in-memory)
- Invoked as `/knowledge-distillery:collect-evidence`

## Prerequisites

- GitHub MCP server configured with `pull_requests,issues,labels` toolsets
- `git` with access to `refs/notes/commits`
- Linear MCP server (graceful degradation — but triggers `insufficient` if Linear IDs exist)

## Allowed Tools

- GitHub MCP (read-only by behavioral contract) — PR data and review comments
- Linear MCP — issue details and comments (read-only)
- `git log`, `git show`, `git notes show` — commit and memento data
- `Bash`, `Read`, `Glob`, `Grep`
- No file writes. No vault.db access. No `knowledge-gate` CLI.
- MUST NOT create, modify, or delete any GitHub resources (comments, labels, PRs). Read operations only.

## Input

| Field | Source | Format |
|-------|--------|--------|
| PR number | Passed by orchestrator | Integer |
| Repository | Derived via GitHub MCP if not provided | `owner/repo` |
| Manifest JSON | Parsed from PR comment (between `EVIDENCE_BUNDLE_MANIFEST_START`/`END` delimiters) | JSON per [evidence-manifest.spec.md](../mark-evidence/reference/evidence-manifest.spec.md) |

## Output

An **Evidence Bundle** — a structured JSON object held in memory. NOT written to disk. Returned to the calling context for consumption by `/knowledge-distillery:extract-candidates`.

## Execution Steps

Follow these steps in exact order.

### Step 1: Parse the Evidence Bundle Manifest

Fetch all PR comments and locate the Manifest:

```
Use GitHub MCP to list all issue-level comments on PR #{pr_number}.
```

1. Find the comment whose body contains `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`
2. Extract the text between `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->` and `<!-- EVIDENCE_BUNDLE_MANIFEST_END -->`
3. Strip the markdown code fence (opening ` ```json ` and closing ` ``` `)
4. Parse the remaining text as JSON
5. Validate the parsed JSON:
   - `version` must be `"1"`
   - `pr.number` must be a positive integer
   - `pr.merge_sha` must match `/^[0-9a-f]{7,40}$/`
   - All `identifiers` sub-keys (`linear`, `slack`, `memento`, `greptile`) must be present (even if empty arrays)

**If no Manifest comment is found**, return an Evidence Bundle with:
```json
{
  "sufficiency": {
    "verdict": "insufficient",
    "missing": ["manifest"],
    "reason": "No Evidence Bundle Manifest comment found on PR #{pr_number}."
  }
}
```
Stop processing — do not proceed to subsequent steps.

**If the Manifest JSON is malformed or fails validation**, return an Evidence Bundle with:
```json
{
  "sufficiency": {
    "verdict": "insufficient",
    "missing": ["manifest"],
    "reason": "Evidence Bundle Manifest on PR #{pr_number} is malformed or invalid."
  }
}
```
Stop processing.

### Step 2: Collect PR Evidence (Required)

Carry forward from the parsed Manifest into the Evidence Bundle's root-level fields:
- `pr_number` from `pr.number`
- `merge_sha` from `pr.merge_sha`
- `base_branch` from `pr.base_branch`
- `changed_files` from `pr.changed_files`

Then collect PR content:

1. **Title and body:**
   ```
   Use GitHub MCP to fetch PR #{pr_number} title and body.
   ```

2. **Changed file list:**
   The full PR diff is on-demand evidence — `extract-candidates` fetches specific file diffs selectively. At this stage, collect only the list of changed files:
   ```
   Use GitHub MCP to fetch the list of changed files in PR #{pr_number}. Extract relative file paths.
   ```
   Store as `changed_files` in the Evidence Bundle. If the Manifest already contains `pr.changed_files`, verify and use that; otherwise populate from this query.

   > **Note for downstream:** `extract-candidates` can selectively fetch specific file diffs as needed using GitHub MCP or `git diff`.

3. **Commits:**
   ```
   Use GitHub MCP to list all commits in PR #{pr_number}. Extract each commit's SHA (short, 7 chars) and full message.
   ```

4. **Review comments (inline on diff):**
   ```
   Use GitHub MCP to list all review comments (inline on diff) for PR #{pr_number}. Extract: author (login), body, path, line (or original_line).
   ```

5. **Issue-level comments:**
   ```
   Use GitHub MCP to list all issue-level comments on PR #{pr_number}. Include all comments EXCEPT the Manifest comment itself.
   ```

Note: The full PR diff is not pre-collected. The changed file list is sufficient for this step.

### Step 3: Collect Linear Evidence (Required when IDs exist)

For each entry in `identifiers.linear`:

1. Query Linear MCP for the issue by ID. Collect:
   - `title`
   - `description` (full body)
   - `comments` — array of `{ author, body, created_at }`
   - `labels` — array of label names
   - `status_changes` — status transition history (e.g., `[{ "from": "In Progress", "to": "Done", "changed_at": "ISO 8601", "actor": "username" }]`). Use Linear MCP `getIssueHistory` or extract from issue activity/audit log. If the API does not expose a dedicated history endpoint, reconstruct transitions from issue comments or activity entries where status changes are logged.
2. If Linear MCP is unavailable or the specific issue is not found:
   - Record the ID in `sufficiency.missing` as `"linear:{id}"`
   - This triggers an `insufficient` verdict

**Why Linear is required:** When a developer explicitly linked a Linear issue to a PR, the issue context (discussion, decisions, rationale) is critical evidence for knowledge extraction. Its absence meaningfully degrades extraction quality.

If `identifiers.linear` is an empty array, skip this step entirely — no insufficiency triggered.

### Step 4: Collect Slack Evidence (Optional)

For each entry in `identifiers.slack`:

1. Attempt to retrieve the Slack thread content using available integration
2. If retrieved successfully: `{ "url": "...", "content": "...", "retrieved": true }`
3. If retrieval fails: `{ "url": "...", "content": null, "retrieved": false }`

Missing Slack content does NOT trigger `insufficient`. Slack threads are supplementary context.

### Step 5: Collect Memento Evidence (Optional)

Ensure notes refs are available before collecting:

```bash
git fetch origin refs/notes/commits:refs/notes/commits 2>/dev/null || true
```

For each entry in `identifiers.memento` where `has_notes` is `true`:

1. **Summary notes:**
   ```bash
   git notes --ref=refs/notes/commits show {sha}
   ```
   If successful, store the output as `summary`.

2. If `git notes show` fails for a commit, skip that entry silently.

Missing memento notes do NOT trigger `insufficient`.

### Step 6: Collect Greptile Evidence (Optional)

For each entry in `identifiers.greptile`:

1. Fetch PR comments from the Greptile bot:
   ```
   Use GitHub MCP to list all review comments for PR #{pr_number}. Filter for comments by users whose login contains "greptile" (case-insensitive).
   ```

2. Also check issue-level comments for Greptile bot comments.

3. Collect: `{ "path": "...", "line": N, "body": "..." }` for each comment.

Missing Greptile data does NOT trigger `insufficient`.

### Step 7: Sufficiency Judgment

Evaluate evidence completeness using these rules:

| Condition | Verdict |
|-----------|---------|
| Changed file list present AND commit messages present | Required baseline met |
| `identifiers.linear` is non-empty AND all Linear issues retrieved | Required condition met |
| `identifiers.linear` is non-empty AND any Linear issue NOT retrieved | `insufficient` |
| `identifiers.linear` is empty (no Linear IDs in Manifest) | No Linear requirement |
| All optional sources (Slack, memento, Greptile) missing but required baseline met | `sufficient` |
| No Manifest found | `insufficient` |

**Composing the sufficiency object:**

If `sufficient`:
```json
{
  "verdict": "sufficient",
  "missing": [],
  "reason": ""
}
```

If `insufficient`:
```json
{
  "verdict": "insufficient",
  "missing": ["<specific items, e.g., 'linear:PAY-123', 'pr_diff', 'manifest'>"],
  "reason": "<Human-readable explanation of what is missing and why it matters>"
}
```

Even when `insufficient`, return the Evidence Bundle with whatever evidence was collected. The orchestrator decides how to handle insufficient bundles (e.g., keeping the PR in `knowledge:pending` for a later retry).

## Evidence Bundle Structure

The final Evidence Bundle must follow this structure:

```json
{
  "pr_number": 1234,
  "merge_sha": "abc123def456",
  "base_branch": "main",
  "changed_files": ["path/to/file.rb", "..."],
  "evidence": {
    "pr": {
      "title": "PR title text",
      "body": "PR body markdown",
      "commits": [
        { "sha": "a1b2c3d", "message": "Full commit message" }
      ],
      "review_comments": [
        { "author": "username", "body": "comment text", "path": "file.rb", "line": 42 }
      ],
      "issue_comments": [
        { "author": "username", "body": "comment text" }
      ]
    },
    "linear": [
      {
        "id": "LIN-456",
        "title": "Issue title",
        "description": "Full issue body",
        "comments": [
          { "author": "person", "body": "comment text", "created_at": "ISO 8601" }
        ],
        "labels": ["decision", "bug"],
        "status_changes": [
          { "from": "In Progress", "to": "Done", "changed_at": "ISO 8601", "actor": "username" }
        ]
      }
    ],
    "slack": [
      {
        "url": "https://team.slack.com/archives/C0123/p1709901234",
        "content": "thread content or null",
        "retrieved": true
      }
    ],
    "memento": [
      {
        "sha": "a1b2c3d",
        "summary": "git notes content from refs/notes/commits"
      }
    ],
    "greptile": [
      {
        "review_id": "greptile-pr-1234",
        "comments": [
          { "path": "file.rb", "line": 10, "body": "review comment" }
        ]
      }
    ]
  },
  "sufficiency": {
    "verdict": "sufficient",
    "missing": [],
    "reason": ""
  }
}
```

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| No Manifest comment on PR | Return `insufficient` with reason. Do not proceed to collection steps. |
| Manifest JSON malformed | Return `insufficient` with reason. Do not proceed. |
| Linear MCP unavailable | `insufficient` if Linear IDs exist in Manifest. Record which IDs failed in `missing`. |
| Linear issue deleted/moved/not found | Record `"linear:{id}"` in `missing`. `insufficient` for this PR. |
| Slack content unretrievable | Set `retrieved: false` for that entry. Continue — optional source. |
| `git notes show` fails | Skip that memento entry. Continue — optional source. |
| Changed file list unavailable | Use `pr.changed_files` from Manifest as fallback. |
| GitHub API rate limit | Report failure to orchestrator. Orchestrator retries in next batch. |

## Constraints

- MUST NOT write any files to disk
- MUST NOT access or modify vault.db
- MUST NOT extract knowledge candidates (that is `/knowledge-distillery:extract-candidates` — Stage B step 2)
- MUST NOT make sufficiency decisions beyond the defined rules — no subjective "I think this is enough"
- MUST return the Evidence Bundle in memory for the next step in the same subagent context
- MUST preserve all raw content without summarization or interpretation
- MUST NOT modify the PR (no comments, no label changes — the orchestrator handles that)
