---
name: mark-evidence
description: "Extracts evidence identifiers from a merged PR and posts an Evidence Bundle Manifest comment. Stage A of the distillation pipeline — lightweight, identifier-only, no content fetching. Triggered on PR merge or manual invocation. Use after a PR merge to begin knowledge tracking, or manually with a specific PR number to retroactively mark evidence."
argument-hint: "[PR-number]"
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
| PR comment | Evidence Bundle Manifest (per [evidence-manifest.spec.md](reference/evidence-manifest.spec.md)) with optional `KD_TRIAGE_DECISION` block; or L1-only triage decision comment for deterministic skips | `/knowledge-distillery:collect-evidence`, `/knowledge-distillery:batch-refine` report metrics |
| PR label | One of `knowledge:pending`, `knowledge:skipped`, `knowledge:deferred` | `/knowledge-distillery:batch-refine` discovery/reporting |

## Execution Steps

Follow these steps in exact order. Do not skip steps. Do not reorder.

### Step 1: Idempotency Check

PR labels and comments jointly define the current state. Read both before deciding whether this run should do work.

```
Use GitHub MCP to fetch PR #{pr_number}: labels, issue comments (bodies only).
```

Check for these markers:
- Labels: `knowledge:pending`, `knowledge:skipped`, `knowledge:deferred`, `knowledge:collected`
- Comment blocks: `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`, `<!-- KD_TRIAGE_DECISION_START -->`

Evaluate the cases in order. Stop at the first match.

| Case | Condition | Behavior |
|---|---|---|
| C0 | `knowledge:collected` label exists | Exit successfully. Do not post another Manifest. Do not modify labels. |
| C1a | `knowledge:pending` label exists AND Manifest block exists | Exit successfully. Do not post another Manifest. Do not modify labels. |
| C1b | `knowledge:pending` label exists AND Manifest block is missing | Treat as manual promote or previous partial failure. Skip Layer 1 and Layer 2 triage. Continue at Step 2 to build the Manifest, then post the Manifest comment in Step 9. The pending label add in Step 9 is a no-op because the label is already present. |
| C2 | `knowledge:skipped` label exists AND `KD_TRIAGE_DECISION` block exists | Exit successfully. Do not add labels or comments. |
| C3 | `knowledge:deferred` label exists AND `KD_TRIAGE_DECISION` block exists | Exit successfully. Do not add labels or comments. |
| C4 | Manifest block exists, no triage decision block exists, and none of `knowledge:pending`, `knowledge:skipped`, `knowledge:deferred` is present | Preserve legacy idempotency. Re-add `knowledge:pending`, then exit successfully. |
| C5 | None of the above | Treat as a new PR. Continue to Step 1.5 (Layer 1 Deterministic Triage). |

Manual promote path: if a human changes `knowledge:skipped` or `knowledge:deferred` to `knowledge:pending`, the PR usually has a `KD_TRIAGE_DECISION` block but no Manifest. This is C1b. Preserve the triage decision block as history, do not rerun triage, and create the Manifest.

If a Manifest and `KD_TRIAGE_DECISION` block exist but no knowledge state label exists, recover the label from the latest decision block and exit successfully. Do not rebuild the Manifest or rerun triage. Map the decision to its label: `skip` → `knowledge:skipped`, `defer` → `knowledge:deferred`, `extract` → `knowledge:pending`. This recovers from a crash between posting the Manifest comment and adding the label (C4 only covers legacy Manifests that never had a decision block).

### Step 1.5: Layer 1 Deterministic Triage

Skip this step when Step 1 matched C1b. Manual promote and partial-failure recovery must create a Manifest without rerunning triage.

Before building the Manifest, evaluate four deterministic rules. If any rule matches, skip the PR immediately and do not run Step 2 or later steps.

**Fetch only the minimum input first:**

```
Use GitHub MCP to fetch PR #{pr_number}: title, body, author (login + is_bot), changed files (paths only).
```

**Rules (first match wins):**

| Rule | Condition | Skip reason |
|---|---|---|
| R1 | `author.is_bot == true` AND PR title matches a dependency/update automation title pattern AND every changed file matches dependency metadata, lockfile, or generated patterns | `bot-dependency-update` |
| R2 | Every changed file matches a lockfile pattern | `lockfile-only` |
| R3 | Every changed file matches a generated pattern | `generated-only` |
| R4 | PR title starts with `Revert "` AND body is empty or only matches GitHub's auto-revert text (`This reverts commit <sha>.`) | `auto-revert` |

**Lockfile patterns:**

```
*-lock.json, *.lock, Gemfile.lock, Cargo.lock, package-lock.json,
yarn.lock, pnpm-lock.yaml, poetry.lock, uv.lock, composer.lock,
mix.lock, go.sum
```

**Generated patterns:**

```
**/generated/**, **/__generated__/**, dist/**, build/**,
**/*.snap, **/__snapshots__/**
```

**Dependency metadata patterns (R1 only):**

```
package.json, pyproject.toml, requirements*.txt, Gemfile, go.mod,
Cargo.toml, composer.json, mix.exs
```

**Dependency/update automation title patterns (R1 only, case-insensitive substring match):**

```
dependabot, renovate, bump, update dependency, update dependencies,
upgrade dependency, upgrade dependencies
```

**On skip:**

1. Ensure the label exists:
   ```
   Use GitHub MCP to ensure the label `knowledge:skipped` exists on the repository (description: "PR triaged as low-value, excluded from knowledge pipeline", color: "BBBBBB"). If it already exists, continue without error.
   ```
2. Post a short triage decision comment:
   ````markdown
   <!-- KD_TRIAGE_DECISION_START -->
   ```json
   {"layer":"L1","rule":"<skip reason>","decision":"skip"}
   ```
   Skipped by triage: <human-readable reason>
   <!-- KD_TRIAGE_DECISION_END -->
   ````
3. Add the `knowledge:skipped` label.
4. Exit successfully. Do not post a Manifest.

If no rule matches, continue to Step 2. Reuse Step 1.5 metadata in Step 2 when available to avoid duplicate fetching.

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

> **Note on regex breadth:** This pattern intentionally matches any `PREFIX-123` format (Linear, JIRA, etc.) rather than filtering by known project prefixes. False positives are handled gracefully downstream — `collect-evidence` looks up each ID in Linear and sets `retrieved: false` if not found. Overly narrow patterns risk missing valid references.

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

### Step 7: Discover Notion Page Links

Notion page URLs can appear in PR text and Linear issues. Collect from both.

**7a. Extract Notion links from PR body and comments:**

1. Scan the PR body (from Step 2) for Notion page URLs matching the pattern: `https://(www\.)?notion\.(so|site)/\S+`
2. Record each discovered URL with `source: "pr_body"`
3. Also scan PR issue-level comments for the same pattern; record those with `source: "pr_comment"`

**7b. Extract Notion links from Linear issues (requires Linear MCP):**

For each Linear issue ID found in Step 3:

1. Scan the issue body and all comments (already retrieved in Step 4b) for Notion page URLs matching the same pattern
2. Record each discovered URL with `source: "linear_issue"`

**Graceful degradation:** If Linear MCP was unavailable in Step 4b, skip Step 7b only. Notion links from Step 7a are still collected.

**7c. Deduplicate** all collected Notion URLs by URL, keeping the first `source` encountered.

### Step 8: Compose the Manifest

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
| Notion Pages | {n} | {comma-separated page titles or shortened URLs, or "—"} |
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
    ],
    "notion": [
      { "url": "<notion page URL>", "source": "<source_type>" }
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
| V9 | Each `notion[].url` matches `https://(www.)?notion.(so\|site)/*` |

If any validation fails, fix the data before posting. Do not post an invalid Manifest.

### Step 8.5: Layer 2 LLM Triage

Skip this step when Step 1 matched C1b. Manual promote and partial-failure recovery must preserve the human's `knowledge:pending` override.

This step is not a separate model call. The Claude instance executing this skill applies the decision guide below and constructs a `decision payload` to append to the PR comment. If the decision is unclear, choose `extract`.

**Use only this limited input:**

- PR title
- PR body
- PR labels
- PR author login
- Changed file paths with additions/deletions when available
- Manifest summary counts: `linear`, `slack`, `memento`, `greptile_comments`, `notion`
- Main commit messages, maximum 5 messages, truncated to 200 characters each

**Do not use:** full diff, full memento note body, full Linear issue body.

**Decision guide:**

- Conservative default: choose `skip` only when the PR is clearly low-value for knowledge extraction. If ambiguous, choose `extract` or `defer`.
- Choose `skip` for:
  - docs-only changes (`.md`, `.txt`, `.rst`, or `docs/**`) with no decision/policy signal.
    - Decision keywords: `decide`, `decision`, `convention`, `policy`, `ADR`, `deprecate`, `adopt`, `must`, `must not`, `결정`, `정책`, `규칙`, `채택`, `금지`, `폐기`, `합의`
    - Decision paths: `docs/adr/`, `docs/decisions/`, `CONTEXT.md`, `RFC*`
    - If any signal is present, do not skip.
  - test-only changes (`*_test.*`, `*.test.*`, `**/__tests__/**`) with no manifest signals (`linear`, `slack`, `memento`, `notion`, and `greptile_comments` are all zero/false).
  - i18n or translation-only changes (`**/locales/**`, `*.po`, `*.pot`).
- Choose `defer` when classification is not trustworthy and human curation is needed, such as large mixed changes with weak manifest signals.
- Choose `extract` for everything else.

**Decision payload format:**

```json
{"layer":"L2","decision":"<skip|extract|defer>","reason":"<one sentence>","signals":["<signal>","..."]}
```

Append a `KD_TRIAGE_DECISION` block to the Manifest comment for every Layer 2 decision, including `extract`. This is the source of truth for triage metrics.

Example `extract` block:

````markdown
<!-- KD_TRIAGE_DECISION_START -->
```json
{"layer":"L2","decision":"extract","reason":"code changes present with manifest signals","signals":["src/ files changed","linear ID found"]}
```
<!-- KD_TRIAGE_DECISION_END -->
````

**Decision behavior:**

- `extract`: append the decision block to the Manifest comment, then continue to Step 9.
- `skip`:
  1. Ensure `knowledge:skipped` exists (description: "PR triaged as low-value, excluded from knowledge pipeline", color: "BBBBBB").
  2. Append the decision block to the Manifest comment.
  3. Post the Manifest comment.
  4. Add `knowledge:skipped`.
  5. Exit successfully. Do not add `knowledge:pending`.
- `defer`:
  1. Ensure `knowledge:deferred` exists (description: "PR triage requires human curation", color: "FF8800").
  2. Append the decision block to the Manifest comment.
  3. Post the Manifest comment.
  4. Add `knowledge:deferred`.
  5. Exit successfully. Do not add `knowledge:pending`.

### Step 9: Post Comment and Add Label

This step runs only when Layer 2 chose `extract`, or when Step 1 matched C1b and is creating a Manifest for a manually promoted pending PR.

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
| PR already has Manifest or triage decision state | Follow Step 1 idempotency cases. Do not duplicate comments. |
| Layer 2 classification is uncertain | Choose `extract` and continue to Step 9. |

## Constraints

- MUST NOT fetch actual evidence content (no reading Linear issue bodies for knowledge extraction — only for Slack link discovery)
- MUST NOT modify any files in the repository
- MUST NOT interact with vault.db or `knowledge-gate` CLI
- MUST NOT make judgments about evidence sufficiency (that is Stage B's job)
- MUST be idempotent — safe to re-run on the same PR
- MUST post exactly one Manifest comment per PR that reaches Manifest construction; L1 deterministic skips post only a triage decision comment
- MUST ensure the human-readable summary table is consistent with the JSON data
