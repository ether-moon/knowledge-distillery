# Collect Evidence — Skill Creation Prompt

## Purpose

Generate a skill file that gathers the actual content of all evidence sources identified in a PR's Evidence Bundle Manifest. This is Stage B step 1 — transforming identifier references into a structured Evidence Bundle with full content for downstream extraction.

## Pipeline Position

- **Trigger**: Called by `/batch-refine` orchestrator as a subagent per PR
- **Depends on**: Evidence Bundle Manifest (posted by `/mark-evidence`)
- **Produces**: Evidence Bundle (in-memory structured JSON)
- **Consumed by**: `/extract-candidates` (Stage B step 2, same subagent context)

## Prerequisites

### Runtime Environment
- Claude Code agent context (subagent spawned by `/batch-refine`)
- `gh` CLI authenticated with repo scope
- Linear MCP server (or Linear API access)
- `git` with access to `refs/notes/commits` and `refs/notes/memento-full-audit`

### Allowed Tools
- `gh pr view`, `gh pr diff`, `gh api` — PR data and review comments
- Linear MCP — issue details and comments
- `git log`, `git show`, `git notes show` — commit and memento data
- No file writes. No vault.db access.

## Input Contract

| Field | Source | Format |
|-------|--------|--------|
| PR number | Passed by orchestrator | Integer |
| Manifest JSON | Parsed from PR comment (between `EVIDENCE_BUNDLE_MANIFEST_START`/`END` delimiters) | JSON per `evidence-manifest.spec.md` |

## Output Contract

The skill produces an **Evidence Bundle** — a structured JSON object held in memory within the subagent context. It is NOT written to disk.

```json
{
  "pr_number": 1234,
  "merge_sha": "abc123def456",
  "base_branch": "main",
  "changed_files": ["app/services/payments/charge.rb", "..."],  // from Manifest pr.changed_files
  "evidence": {
    "pr": {
      "title": "...",
      "body": "...",
      "diff": "... (full PR diff) ...",
      "commits": [
        { "sha": "a1b2c3d", "message": "..." }
      ],
      "review_comments": [
        { "author": "...", "body": "...", "path": "...", "line": 42 }
      ]
    },
    "linear": [
      {
        "id": "LIN-456",
        "title": "...",
        "description": "...",
        "comments": [
          { "author": "...", "body": "...", "created_at": "..." }
        ],
        "labels": ["decision", "..."]
      }
    ],
    "slack": [
      {
        "url": "https://...",
        "content": "... (thread content if retrievable) ...",
        "retrieved": true
      }
    ],
    "memento": [
      {
        "sha": "a1b2c3d",
        "summary": "... (git notes show output) ...",
        "full_audit": "... (memento-full-audit notes, if available) ..."
      }
    ],
    "greptile": [
      {
        "review_id": "...",
        "comments": [
          { "path": "...", "line": 10, "body": "..." }
        ]
      }
    ]
  },
  "sufficiency": {
    "verdict": "sufficient | insufficient",
    "missing": ["... list of expected but unavailable sources ..."],
    "reason": "..."
  }
}
```

## Behavioral Requirements

### Step 1: Parse Manifest

1. Fetch PR comments via `gh api repos/{owner}/{repo}/issues/{pr_number}/comments`
2. Find the comment containing `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`
3. Extract and parse JSON per `evidence-manifest.spec.md` parsing instructions
4. If no Manifest found, return `insufficient` with reason "No Manifest comment found"

### Step 2: Collect PR Evidence (Required)

Carry forward `pr.changed_files`, `pr.merge_sha`, and `pr.base_branch` from the parsed Manifest into the Evidence Bundle's root-level fields.

1. `gh pr view {pr_number} --json title,body` → PR title and body
2. `gh pr diff {pr_number}` → full diff
3. `gh api repos/{owner}/{repo}/pulls/{pr_number}/commits` → commit list with messages
4. `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments` → review comments (inline)
5. `gh api repos/{owner}/{repo}/issues/{pr_number}/comments` → issue-level comments (excluding Manifest)

### Step 3: Collect Linear Evidence (Required if IDs exist in Manifest)

For each `identifiers.linear` entry:

1. Query Linear MCP for issue details: title, description, comments, labels
2. If Linear MCP unavailable or issue not found, record in `sufficiency.missing`
3. Linear content is **required** when Linear IDs are present — absence triggers `insufficient`

### Step 4: Collect Slack Evidence (Optional)

For each `identifiers.slack` entry:

1. Attempt to retrieve thread content (method depends on available Slack integration)
2. If unavailable, set `retrieved: false` — this does NOT trigger `insufficient`

### Step 5: Collect Memento Evidence (Optional)

For each `identifiers.memento` entry where `has_notes: true`:

1. `git notes show {sha}` (from `refs/notes/commits`) → summary
2. `git notes show {sha}` (from `refs/notes/memento-full-audit`) → full audit (optional)
3. Missing memento notes do NOT trigger `insufficient`

### Step 6: Collect Greptile Evidence (Optional)

For each `identifiers.greptile` entry:

1. Fetch Greptile review comments from PR
2. Missing Greptile data does NOT trigger `insufficient`

### Step 7: Sufficiency Judgment

Evaluate evidence completeness:

| Condition | Verdict |
|-----------|---------|
| PR diff + commit messages present | Required baseline met |
| Linear IDs exist AND Linear content retrieved | Required condition met |
| Linear IDs exist BUT Linear content NOT retrieved | `insufficient` |
| All optional sources missing but required met | `sufficient` |
| PR diff unavailable | `insufficient` |

If `insufficient`:
- Set `sufficiency.verdict` to `"insufficient"`
- List missing sources in `sufficiency.missing`
- Provide human-readable `sufficiency.reason`
- Return the bundle as-is (orchestrator will handle labeling)

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| No Manifest comment on PR | Return `insufficient` with reason. Orchestrator labels `knowledge:insufficient`. |
| Linear MCP unavailable | `insufficient` if Linear IDs exist. Record which IDs failed. |
| Linear issue deleted/moved | Record in `missing`. `insufficient` for that PR. |
| Slack content unretrievable | Set `retrieved: false`. Continue (optional source). |
| `git notes show` fails | Skip memento entry. Continue (optional source). |
| PR diff too large (>100KB) | Truncate diff. Add note in evidence. Still `sufficient`. |
| GitHub API rate limit | Fail the subagent. Orchestrator retries in next batch. |

## Example Scenarios

### Scenario 1: Complete Evidence Collection

**Input**: PR #1234, Manifest has Linear IDs [LIN-456, LIN-789], 2 memento commits, 1 Slack link

**Output**: Evidence Bundle with:
- `pr`: full diff, title, body, commits, review comments
- `linear`: both issues with descriptions and comments
- `slack`: thread content (retrieved: true)
- `memento`: 2 summaries
- `sufficiency`: `{ verdict: "sufficient" }`

### Scenario 2: Insufficient — Linear Unavailable

**Input**: PR #456, Manifest has Linear ID [PAY-123], Linear MCP is down

**Output**: Evidence Bundle with:
- `pr`: full diff, title, body, commits
- `linear`: `[]`
- `sufficiency`: `{ verdict: "insufficient", missing: ["linear:PAY-123"], reason: "Linear MCP unavailable. Linear evidence required when Linear IDs are present." }`

### Scenario 3: Minimal PR — No External References

**Input**: PR #789, Manifest has empty `linear`, `slack`, `memento`, `greptile` arrays

**Output**: Evidence Bundle with:
- `pr`: full diff, title, body, commits
- All other sections: empty
- `sufficiency`: `{ verdict: "sufficient" }` (baseline PR evidence meets minimum)

## Reference Specifications

- Evidence Bundle structure: design-implementation.md §3.2
- Required vs optional evidence: design-implementation.md §3.2
- Manifest format: `evidence-manifest.spec.md`
- git-memento notes refs: design-implementation.md §2.5

## Constraints

- MUST NOT write any files to disk
- MUST NOT access or modify vault.db
- MUST NOT extract knowledge candidates (that's step 2's job)
- MUST NOT make sufficiency decisions beyond the defined rules (no "I think this is enough")
- MUST return the Evidence Bundle in memory for the next step in the same subagent context
- MUST preserve all raw content without summarization or interpretation

## Validation Checklist

1. Does the skill correctly parse the Manifest from PR comments?
2. Does the skill collect PR diff and commit messages (required baseline)?
3. Does the skill enforce Linear content as required when Linear IDs exist?
4. Does the skill correctly classify optional vs required sources?
5. Does the skill return `insufficient` with specific `missing` items when required sources fail?
6. Does the Evidence Bundle contain all fields needed by `/extract-candidates`?
7. Does the skill avoid writing to disk (in-memory only)?
8. Does the skill preserve raw evidence without summarization?
