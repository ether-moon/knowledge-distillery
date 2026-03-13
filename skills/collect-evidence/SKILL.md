---
description: "Collects the actual content of all evidence sources identified in a PR's Evidence Bundle Manifest and produces a structured Evidence Bundle. Stage B step 1 — transforms identifier references into full content for downstream candidate extraction. Called by batch-refine orchestrator per PR."
---

# collect-evidence — Stage B-1 Evidence Collection

## When This Skill Runs

- Called by `/knowledge-distillery:batch-refine` orchestrator as a subagent per PR
- Runs within the same subagent context (Evidence Bundle is returned in-memory)
- Invoked as `/knowledge-distillery:collect-evidence`

## Prerequisites

- `gh` CLI authenticated with repo scope
- `git` with access to `refs/notes/commits` and `refs/notes/memento-full-audit`
- Linear MCP server (graceful degradation — but triggers `insufficient` if Linear IDs exist)

## Allowed Tools

- `gh pr view`, `gh pr diff`, `gh api` — PR data and review comments
- Linear MCP — issue details and comments (read-only)
- `git log`, `git show`, `git notes show` — commit and memento data
- `Bash`, `Read`, `Glob`, `Grep`
- No file writes. No vault.db access. No `knowledge-gate` CLI.

## Input

| Field | Source | Format |
|-------|--------|--------|
| PR number | Passed by orchestrator | Integer |
| Repository | Derived via `gh repo view --json nameWithOwner -q .nameWithOwner` if not provided | `owner/repo` |
| Manifest JSON | Parsed from PR comment (between `EVIDENCE_BUNDLE_MANIFEST_START`/`END` delimiters) | JSON per `evidence-manifest.spec.md` |

## Output

An **Evidence Bundle** — a structured JSON object held in memory. NOT written to disk. Returned to the calling context for consumption by `/knowledge-distillery:extract-candidates`.

## Execution Steps

Follow these steps in exact order.

### Step 1: Parse the Evidence Bundle Manifest

Fetch all PR comments and locate the Manifest:

```bash
gh api repos/{owner}/{repo}/issues/{pr_number}/comments --paginate
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
   ```bash
   gh pr view {pr_number} --json title,body
   ```

2. **Full PR diff:**
   ```bash
   gh pr diff {pr_number}
   ```
   If the diff exceeds 100KB, truncate it and add a note: `"[TRUNCATED — diff exceeded 100KB]"`. A truncated diff is still sufficient.

3. **Commits:**
   ```bash
   gh api repos/{owner}/{repo}/pulls/{pr_number}/commits --paginate
   ```
   Extract each commit's SHA (short, 7 chars) and full message.

4. **Review comments (inline on diff):**
   ```bash
   gh api repos/{owner}/{repo}/pulls/{pr_number}/comments --paginate
   ```
   Extract: `author` (login), `body`, `path`, `line` (or `original_line`).

5. **Issue-level comments:**
   ```bash
   gh api repos/{owner}/{repo}/issues/{pr_number}/comments --paginate
   ```
   Include all comments EXCEPT the Manifest comment itself (filter out any comment containing `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`).

If the PR diff is unavailable (API error, not a failure in truncation), record `"diff": null` and mark this in the sufficiency assessment.

### Step 3: Collect Linear Evidence (Required when IDs exist)

For each entry in `identifiers.linear`:

1. Query Linear MCP for the issue by ID. Collect:
   - `title`
   - `description` (full body)
   - `comments` — array of `{ author, body, created_at }`
   - `labels` — array of label names
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
git fetch origin refs/notes/memento-full-audit:refs/notes/memento-full-audit 2>/dev/null || true
```

For each entry in `identifiers.memento` where `has_notes` is `true`:

1. **Summary notes:**
   ```bash
   git notes --ref=refs/notes/commits show {sha}
   ```
   If successful, store the output as `summary`.

2. **Full audit notes (optional):**
   ```bash
   git notes --ref=refs/notes/memento-full-audit show {sha}
   ```
   If successful, store the output as `full_audit`. If not available, set `full_audit` to `null`.

3. If `git notes show` fails for a commit, skip that entry silently.

Missing memento notes do NOT trigger `insufficient`.

### Step 6: Collect Greptile Evidence (Optional)

For each entry in `identifiers.greptile`:

1. Fetch PR comments from the Greptile bot:
   ```bash
   gh api repos/{owner}/{repo}/pulls/{pr_number}/comments --paginate
   ```
   Filter for comments by users whose login contains "greptile" (case-insensitive).

2. Also check issue-level comments for Greptile bot comments.

3. Collect: `{ "path": "...", "line": N, "body": "..." }` for each comment.

Missing Greptile data does NOT trigger `insufficient`.

### Step 7: Sufficiency Judgment

Evaluate evidence completeness using these rules:

| Condition | Verdict |
|-----------|---------|
| PR diff retrieved (even truncated) AND commit messages present | Required baseline met |
| `identifiers.linear` is non-empty AND all Linear issues retrieved | Required condition met |
| `identifiers.linear` is non-empty AND any Linear issue NOT retrieved | `insufficient` |
| `identifiers.linear` is empty (no Linear IDs in Manifest) | No Linear requirement |
| All optional sources (Slack, memento, Greptile) missing but required baseline met | `sufficient` |
| PR diff unavailable (null) | `insufficient` |
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

Even when `insufficient`, return the Evidence Bundle with whatever evidence was collected. The orchestrator decides how to handle insufficient bundles (e.g., labeling `knowledge:insufficient`).

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
      "diff": "full PR diff text (or truncated with note)",
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
        "labels": ["decision", "bug"]
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
        "summary": "git notes content from refs/notes/commits",
        "full_audit": "git notes content from refs/notes/memento-full-audit or null"
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
| PR diff too large (>100KB) | Truncate diff with note. Still `sufficient`. |
| PR diff API error | Set `diff: null`. `insufficient`. |
| GitHub API rate limit | Report failure to orchestrator. Orchestrator retries in next batch. |

## Constraints

- MUST NOT write any files to disk
- MUST NOT access or modify vault.db
- MUST NOT extract knowledge candidates (that is `/knowledge-distillery:extract-candidates` — Stage B step 2)
- MUST NOT make sufficiency decisions beyond the defined rules — no subjective "I think this is enough"
- MUST return the Evidence Bundle in memory for the next step in the same subagent context
- MUST preserve all raw content without summarization or interpretation
- MUST NOT modify the PR (no comments, no label changes — the orchestrator handles that)
