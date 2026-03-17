# Evidence Bundle Manifest — Format Specification

## Purpose

The Evidence Bundle Manifest is the data contract connecting Stage A (merge-time marking) to Stage B (batch distillation). It records **identifiers only** — never evidence content — as a PR comment on merged PRs.

## Format

- **Location**: Comment on the merged PR (posted by the mark-evidence skill)
- **Visibility**: Human-readable summary table + machine-parseable JSON in HTML comment delimiters
- **Delimiters**: `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->` / `<!-- EVIDENCE_BUNDLE_MANIFEST_END -->` (invisible in GitHub UI)
- **Idempotency**: A PR MUST have at most one Manifest comment. If one already exists, skip.

## Schema

### Version

Current: `"1"`

The `version` field is a string. Consumers MUST check version compatibility before parsing.

### Full Structure

```markdown
## Evidence Bundle Manifest

| Category | Count | Details |
|----------|-------|---------|
| Linear Issues | {n} | {comma-separated IDs, or "—"} |
| Slack Threads | {n} | {comma-separated channels, or "—"} |
| Git Sessions | {n} | {count} commits with memento notes |
| Greptile Reviews | {n} | {count} review comments, or "—" |

<!-- EVIDENCE_BUNDLE_MANIFEST_START -->
```json
{
  "version": "1",
  "pr": {
    "number": <integer>,
    "merge_sha": "<hex string, 7+ chars>",
    "base_branch": "<branch name>",
    "changed_files": [
      "<relative file path>",
      ...
    ]
  },
  "identifiers": {
    "linear": [
      { "id": "<PROJECT-NNN>", "source": "<source_type>" }
    ],
    "slack": [
      { "url": "<slack permalink>", "source": "<source_type>" }
    ],
    "memento": [
      { "sha": "<short sha>", "has_notes": <boolean> }
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

### Field Definitions

#### `pr` (required)

| Field | Type | Description |
|-------|------|-------------|
| `number` | integer | PR number |
| `merge_sha` | string | Merge commit SHA (7+ hex characters) |
| `base_branch` | string | Target branch name (e.g., `main`) |
| `changed_files` | string[] | Relative paths of files changed in the PR. Used for auto domain derivation (design-implementation.md §4.6) |

#### `identifiers` (required — all sub-keys required, may be empty arrays)

| Category | Fields | Description |
|----------|--------|-------------|
| `linear` | `id`, `source` | Linear issue IDs extracted from PR title, body, or commit messages |
| `slack` | `url`, `source` | Slack thread permalinks found in Linear issues or PR body |
| `memento` | `sha`, `has_notes` | Commits with git-memento notes (`git notes show <sha>` succeeded) |
| `greptile` | `review_id`, `comment_count` | Greptile review metadata if available |

#### `source` enum

Where the identifier was discovered:

| Value | Meaning |
|-------|---------|
| `pr_title` | PR title text |
| `pr_body` | PR description body |
| `commit_message` | Commit message in the PR |
| `linear_issue` | Linked from a Linear issue body or comment |
| `pr_comment` | PR review comment |

#### `collected_at` (required)

ISO 8601 timestamp of when the Manifest was generated.

## Validation Rules

| Rule | Check |
|------|-------|
| V1 | `version` is a supported version string (currently `"1"`) |
| V2 | `pr.merge_sha` matches `/^[0-9a-f]{7,40}$/` |
| V3 | `pr.number` is a positive integer |
| V4 | `pr.changed_files` is a non-empty array of strings |
| V5 | Each `linear[].id` matches the project's Linear prefix pattern (e.g., `/^[A-Z]+-\d+$/`) |
| V6 | Each `slack[].url` matches Slack permalink format (`https://*.slack.com/archives/*/p*`) |
| V7 | Each `memento[].sha` matches `/^[0-9a-f]{7,40}$/` |
| V8 | `collected_at` is valid ISO 8601 |
| V9 | No duplicate Manifest comment exists on the PR (idempotency) |

## Parsing Instructions

Consumers extract the JSON by:

1. Find the comment containing `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`
2. Extract text between the start and end delimiters
3. Strip the markdown code fence (` ```json ` / ` ``` `)
4. Parse as JSON
5. Validate against the rules above

## Design Decisions

- **Identifiers only, not content**: Stage A is a lightweight GitHub Action. Fetching full Linear/Slack content would add latency and API cost at merge time. Content retrieval is deferred to Stage B.
- **PR comment, not label metadata**: Comments support structured data. Labels are used for state tracking (`knowledge:pending`, `knowledge:collected`).
- **HTML comment delimiters**: Keeps JSON invisible in GitHub UI while remaining trivially extractable programmatically.
- **`changed_files` in Manifest**: Enables domain derivation without re-fetching PR diff in Stage B.

## Reference Specifications

- Evidence Bundle structure: design-implementation.md §3.2
- Auto domain derivation from changed files: design-implementation.md §4.6
- Stage A trigger: design-implementation.md §3.1
- git-memento notes: design-implementation.md §2.5
