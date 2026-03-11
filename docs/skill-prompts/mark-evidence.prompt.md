# Mark Evidence — Skill Creation Prompt

## Purpose

Generate a skill file that, when run as a GitHub Action on PR merge, extracts evidence identifiers from the PR and posts an Evidence Bundle Manifest comment. This is Stage A of the distillation pipeline — lightweight, identifier-only, no content fetching.

## Pipeline Position

- **Trigger**: PR merge to `main`/`master` (GitHub Actions `pull_request.closed` + `merged == true`)
- **Depends on**: Nothing (first pipeline step)
- **Produces**: Evidence Bundle Manifest comment on the merged PR + `knowledge:pending` label
- **Consumed by**: `/collect-evidence` (Stage B step 1)

## Prerequisites

### Runtime Environment
- GitHub Actions runner
- `gh` CLI authenticated with repo scope
- Linear MCP server (or Linear API access) — optional, gracefully degrade if unavailable
- `git` with access to `refs/notes/commits` (memento notes)

### Permissions
- `gh pr comment` — write PR comments
- `gh pr edit --add-label` — manage PR labels
- `gh api` — read PR data (title, body, commits, changed files)
- Linear API — read issue details (for Slack link discovery)

## Input Contract

| Field | Source | Format |
|-------|--------|--------|
| PR number | GitHub Actions event context (`${{ github.event.pull_request.number }}`) | Integer |
| Repository | GitHub Actions event context | `owner/repo` |
| Merge SHA | GitHub Actions event context (`${{ github.event.pull_request.merge_commit_sha }}`) | Hex string |

## Output Contract

| Artifact | Format | Consumer |
|----------|--------|----------|
| PR comment | Evidence Bundle Manifest (see `evidence-manifest.spec.md`) | `/collect-evidence` |
| PR label | `knowledge:pending` added | `/batch-refine` (discovery) |

The Manifest comment MUST conform to the schema and validation rules in `evidence-manifest.spec.md`.

## Behavioral Requirements

### Step 1: Idempotency Check

1. Fetch existing PR comments via `gh api repos/{owner}/{repo}/issues/{pr_number}/comments`
2. If any comment body contains `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`, exit with success (already processed)

### Step 2: Gather PR Metadata

1. `gh pr view {pr_number} --json title,body,commits,files,baseRefName`
2. Extract `changed_files` from the files list (relative paths)
3. Extract `base_branch` from `baseRefName`

### Step 3: Extract Linear Issue IDs

1. Define regex pattern for the project's Linear prefix: `/\b([A-Z]+-\d+)\b/g`
2. Scan these sources in order, recording `source` for each match:
   - PR title → `source: "pr_title"`
   - PR body → `source: "pr_body"`
   - Each commit message → `source: "commit_message"`
3. Deduplicate by ID (keep first `source` encountered)

### Step 4: Discover Slack Links from Linear Issues

For each Linear issue ID found in Step 3:

1. Query Linear MCP/API for issue details (body, comments)
2. Extract Slack permalink URLs matching `https://*.slack.com/archives/*/p*`
3. Record each with `source: "linear_issue"`
4. If Linear MCP is unavailable, skip this step — `slack` array stays empty

### Step 5: Check git-memento Notes

For each commit SHA in the PR:

1. Run `git notes show {sha}` (using `refs/notes/commits`)
2. If successful, record `{ "sha": "{short_sha}", "has_notes": true }`
3. If no notes exist, skip that commit

### Step 6: Check Greptile Reviews

1. Look for Greptile bot comments on the PR via `gh api`
2. If found, count review comments and record metadata
3. If not found, `greptile` array stays empty

### Step 7: Compose Manifest

1. Build the JSON structure per `evidence-manifest.spec.md`
2. Generate the human-readable summary table
3. Set `collected_at` to current ISO 8601 timestamp
4. Validate against the spec's validation rules (V1-V9)

### Step 8: Post and Label

1. Post the Manifest as a PR comment via `gh pr comment {pr_number} --body "{manifest}"`
2. Add label: `gh pr edit {pr_number} --add-label "knowledge:pending"`

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| Linear MCP unavailable | Continue without Slack links. `linear` array retains IDs from PR text. `slack` array empty. |
| Linear issue ID not found in Linear | Keep the ID in `linear` array (it was in the PR text). Log warning. |
| `git notes show` fails | Skip that commit's memento entry. Not an error. |
| No identifiers found at all | Still post Manifest with all empty arrays. Label as `knowledge:pending`. The batch step will assess sufficiency. |
| PR comment API fails | Fail the Action. This is the critical output. |
| Already has Manifest comment | Exit 0 (idempotent success). |

## Example Scenarios

### Scenario 1: PR with Linear Issues and Memento Notes

**Input**: PR #1234 "LIN-456: Add payment retry logic"
- Body mentions LIN-789
- 3 commits, 2 have memento notes
- Linear issue LIN-456 has a Slack link

**Output**: Manifest with:
- `linear`: `[{id: "LIN-456", source: "pr_title"}, {id: "LIN-789", source: "pr_body"}]`
- `slack`: `[{url: "https://team.slack.com/archives/C0123/p170990...", source: "linear_issue"}]`
- `memento`: `[{sha: "a1b2c3d", has_notes: true}, {sha: "d4e5f6g", has_notes: true}]`
- Label: `knowledge:pending`

### Scenario 2: Simple PR with No External References

**Input**: PR #456 "Fix typo in README"
- No Linear IDs in title/body/commits
- No memento notes
- No Greptile review

**Output**: Manifest with all empty arrays. Label: `knowledge:pending`.
Stage B will likely produce 0 candidates — that's expected and fine.

### Scenario 3: Re-run on Already-Processed PR

**Input**: PR #789 already has a Manifest comment

**Output**: Exit 0 immediately. No duplicate comment. No label change.

## Reference Specifications

- Evidence Bundle Manifest format: `evidence-manifest.spec.md`
- Stage A trigger design: design-implementation.md §3.1
- git-memento notes structure: design-implementation.md §2.5
- Linear as anchor: design-implementation.md §2.2

## Constraints

- MUST NOT fetch actual evidence content (no Linear issue body reading for knowledge extraction — only for Slack link discovery)
- MUST NOT modify any files in the repository
- MUST NOT interact with vault.db
- MUST NOT make judgments about evidence sufficiency (that's Stage B's job)
- MUST be idempotent — safe to re-run on the same PR

## Validation Checklist

1. Does the skill post exactly one Manifest comment per PR? (idempotency)
2. Does the Manifest JSON conform to `evidence-manifest.spec.md` schema?
3. Are all identifier `source` fields accurately reflecting where the ID was found?
4. Does the skill add `knowledge:pending` label?
5. Does the skill gracefully handle Linear MCP unavailability?
6. Does the skill produce a valid Manifest even when zero identifiers are found?
7. Is the human-readable summary table consistent with the JSON data?
8. Does the skill avoid fetching evidence content (lightweight constraint)?
