---
name: collect-evidence
description: "Collects the actual content of all evidence sources identified in a PR's Evidence Bundle Manifest and produces a structured Evidence Bundle. Stage B step 1 — transforms identifier references into full content for downstream candidate extraction. Called by batch-refine orchestrator per PR."
user-invocable: false
effort: low
---

# collect-evidence — Stage B-1 Evidence Collection

## When This Skill Runs

- Called by `/knowledge-distillery:batch-refine` orchestrator as a subagent per PR
- Runs within the same subagent context (Evidence Bundle is returned in-memory)
- Invoked as `/knowledge-distillery:collect-evidence`

## Prerequisites

- `gh` CLI authenticated for read-only GitHub access (preferred fast path)
- GitHub MCP server configured with `pull_requests,issues,labels` toolsets (whole-collection fallback)
- `git` with access to `refs/notes/commits`
- Linear MCP server (optional — graceful degradation if unavailable)
- Notion MCP server (optional — graceful degradation if unavailable)

## Allowed Tools

- `gh pr view`, `gh api`, `gh repo view` — read-only PR, repository, and comment data
- GitHub MCP (read-only by behavioral contract) — whole-collection fallback for PR data and comments
- Linear MCP — issue details and comments (read-only)
- Notion MCP — page content retrieval (read-only)
- `git log`, `git show`, `git notes show` — commit and memento data
- `Bash`, `Read`, `Glob`, `Grep`
- No file writes. No vault.db access. No `knowledge-gate` CLI.
- MUST NOT create, modify, or delete any GitHub resources (comments, labels, PRs). Read operations only.

## Input

| Field | Source | Format |
|-------|--------|--------|
| PR number | Passed by orchestrator | Integer |
| Repository | Derived from the current repository by `gh` placeholders, or via GitHub MCP fallback | `owner/repo` |
| Manifest JSON | Parsed from PR comment — strict delimiter parsing preferred, LLM fallback for non-standard formats | JSON per [evidence-manifest.spec.md](../mark-evidence/reference/evidence-manifest.spec.md) |

## Output

An **Evidence Bundle** — a structured JSON object held in memory. NOT written to disk. Returned to the calling context for consumption by `/knowledge-distillery:extract-candidates`.

## Execution Steps

Follow these steps in exact order.

### Step 1: Collect a Normalized GitHub Snapshot and Parse the Manifest

The GitHub read phase is atomic: finish it through one transport, then parse and assemble evidence from that normalized snapshot. The normal path uses two gh calls instead of separate round-trips for PR metadata, files, commits, issue comments, and review comments.

#### 1a. gh CLI fast path (preferred)

Run these commands from the target repository, replacing `<n>` with `pr_number`. Capture every gh call's exit code and stderr separately.

```bash
gh pr view <n> --json number,title,body,author,baseRefName,mergeCommit,changedFiles,files,commits,comments --jq '{number,title,body,author:(.author.login // ""),merge_sha:(.mergeCommit.oid // ""),base_branch:.baseRefName,changed_file_count:.changedFiles,changed_files:[.files[].path],commits:[.commits[]|{sha:.oid[0:7],message:(.messageHeadline + (if .messageBody == "" then "" else "\n\n" + .messageBody end))}],issue_comments:[.comments[]|{author:(.author.login // ""),body}]}'
gh api "repos/{owner}/{repo}/pulls/<n>/comments?per_page=100" --paginate --slurp | jq -c '[.[][] | {author:(.user.login // ""),body,path,line:(.line // .original_line)}]'
```

The first projection deliberately keeps files as paths, commits as `{sha,message}`, and issue comments as `{author,body}`. The second projection produces normalized inline review comments. This avoids retaining large unused response fields in the subagent's Bash output. Raw bodies and commit messages MUST remain byte-for-byte unsummarized in the normalized snapshot.

`gh pr view` has bounded files and commits collections, so complete them before parsing the Manifest:

- When `(.changed_files | length) < .changed_file_count` in the projected snapshot, replace `changed_files` with the flattened result of:
  ```bash
  gh api "repos/{owner}/{repo}/pulls/<n>/files?per_page=100" --paginate --slurp | jq -c '[.[][] | .filename]'
  ```
- When the normalized commits array has exactly 100 entries, do not use the REST commits endpoint: it caps the accessible list at 250 commits. Derive `owner/repo`, split the returned value at `/`, and replace the array with the complete GraphQL cursor result:
  ```bash
  gh repo view --json nameWithOwner --jq .nameWithOwner
  gh api graphql --paginate --slurp \
    -F owner="<owner>" -F repo="<repo>" -F number=<n> \
    -f query='query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          commits(first: 100, after: $endCursor) {
            nodes { commit { oid message } }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }' | jq -c '[.[] | .data.repository.pullRequest.commits.nodes[] | {sha:.commit.oid[0:7],message:.commit.message}]'
  ```
- `gh pr view --json comments` preloads all issue comments, so it needs no separate issue-comment overflow request.

Every paginated REST command uses `?per_page=100`, `--paginate`, and `--slurp`. A paginated REST command emits one array per page; pipe that slurped output to external `jq -c` with `[.[][] | ...]` to produce one flat JSON array. gh rejects combining `--slurp` with its own `--jq` flag. The GraphQL query declares `$endCursor`, requests `pageInfo { hasNextPage endCursor }`, and pipes every slurped page to the same external jq process. Run every gh-to-jq pipeline with `set -o pipefail` so a failed gh call cannot be hidden by a successful jq process. The repository-derivation call and every GraphQL page are subject to the same auth classification and atomic MCP fallback as the two primary gh calls.

#### 1b. Auth classification and whole-collection MCP fallback

After every primary or overflow gh call, classify the captured result in this order:

1. If the command is non-zero and stderr contains `HTTP 401`, `HTTP 403`, or `Bad credentials`, discard all partial evidence, do not fall back, and return the `github_auth` result defined in **GitHub MCP Auth Failure (401/403)** below. Under the current PoC contract a blanket HTTP 403 is auth-dead even when it could also indicate rate limiting.
2. If the command succeeds, continue with the same gh snapshot.
3. For any other non-zero result, use the MCP fallback. Discard every partial gh result and restart the whole GitHub collection through the read-only GitHub MCP path. This includes gh being unavailable, gh being unconfigured, and exit 4 with `populate the GH_TOKEN...`.

The MCP fallback restarts all required GitHub reads: issue-level comments, PR title/body/author/base branch/merge SHA, the complete changed-file list, all commits, and all inline review comments. Normalize those responses to the same fields and shapes as the gh projection. Never combine partial gh results with GitHub MCP results. If any required MCP fallback call returns 401/403, apply the existing auth-failure contract immediately.

A non-auth gh rate-limit failure discards all gh output and restarts the whole collection through MCP. An MCP rate-limit failure is reported to the orchestrator for retry in the next batch. Blanket HTTP 403 takes the auth-dead path first for either transport under D3.

The first live batch is also an authentication check for this fast path: verify that `GH_TOKEN` or `GITHUB_TOKEN` reaches the fresh subagent context. If not, explicitly propagate the token environment from the workflow before relying on gh.

#### 1c. Strict Manifest parsing (preferred)

Use the normalized `issue_comments` array to locate the Manifest:

1. Find the comment whose body contains `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`
2. Extract the text between `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->` and `<!-- EVIDENCE_BUNDLE_MANIFEST_END -->`
3. Strip the markdown code fence (opening ` ```json ` and closing ` ``` `)
4. Parse the remaining text as JSON
5. Validate the parsed JSON:
   - `version` must be `"1"`
   - `pr.number` must be a positive integer
   - `pr.merge_sha` must match `/^[0-9a-f]{7,40}$/`
   - `pr.base_branch` must be a non-empty string
   - `pr.changed_files` must be an array
   - All `identifiers` sub-keys (`linear`, `slack`, `memento`, `greptile`, `notion`) must be present (even if empty arrays)

If strict parsing succeeds, proceed to Step 2. If strict parsing or any validation check fails, continue to 1d and attempt reconstruction from the normalized snapshot.

#### 1d. LLM repair and fallback parsing

If no comment contains the `EVIDENCE_BUNDLE_MANIFEST_START` delimiter, the delimited JSON is malformed, or any strict validation check fails:

1. Treat the failed strict comment as the candidate when one exists. Otherwise, search all issue comments for one that resembles an Evidence Bundle Manifest. Look for comments containing keywords like "Evidence Bundle Manifest", "evidence", identifier references (Linear IDs, Slack URLs, commit SHAs), or structured lists of evidence sources.
2. If a candidate comment is found, extract structured data from it by reading its content and mapping it to the Manifest schema:
   ```json
   {
     "version": "1",
     "pr": {
       "number": "<from orchestrator input>",
       "merge_sha": "<from normalized merge_sha when absent from comment>",
       "base_branch": "<from normalized base_branch when absent from comment>",
       "changed_files": ["<from complete normalized changed_files when absent from comment>"]
     },
     "identifiers": {
       "linear": [],
       "slack": [],
       "memento": [],
       "greptile": [],
       "notion": []
     },
     "collected_at": "<current ISO 8601 timestamp>"
   }
   ```
   - Extract any Linear issue IDs (pattern: `[A-Z]+-\d+`) mentioned in the comment → populate `identifiers.linear`
   - Extract any Slack URLs (pattern: `https://*.slack.com/archives/*/p*`) → populate `identifiers.slack`
   - Extract any commit SHAs referenced as memento sources → populate `identifiers.memento`
   - Extract any Greptile review references → populate `identifiers.greptile`
   - Extract any Notion URLs (pattern: `https://(www.)?notion.(so|site)/*`) → populate `identifiers.notion`
   - Repair missing or invalid PR fields only from the already completed normalized snapshot; do not make another GitHub call.
   - Preserve valid identifier values recovered from the candidate and materialize every missing identifier key as an empty array.
3. Validate the reconstructed Manifest using the same rules as 1c step 5. Empty identifier arrays are valid.

If fallback parsing produces a valid Manifest, proceed to Step 2. If the reconstructed Manifest still fails validation, return `insufficient` with `missing: ["manifest"]` and the validation reason. Do not proceed to later evidence stages.

#### 1e. No Manifest found

If **no comment resembling a Manifest exists at all** (not even in non-standard format), return an Evidence Bundle with:
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

### Step 2: Assemble PR Evidence from the Normalized Snapshot (Required)

Build the required PR evidence without another GitHub request:

- `pr_number`: validated Manifest `pr.number`
- `merge_sha`: normalized `merge_sha`, falling back to the validated Manifest value only when the transport omitted it
- `base_branch`: normalized `base_branch`, falling back to the validated Manifest value only when the transport omitted it
- `changed_files`: complete normalized `changed_files`
- `evidence.pr.title` and `evidence.pr.body`: normalized title and body
- `evidence.pr.commits`: normalized `{sha,message}` array
- `evidence.pr.review_comments`: normalized inline `{author,body,path,line}` array
- `evidence.pr.issue_comments`: normalized `{author,body}` array, excluding the Manifest comment itself

The Evidence Bundle MUST use the complete normalized `changed_files` list. Verify its length against `changed_file_count` when that count is available; a shorter list is an incomplete required baseline and must take the overflow path or whole-collection fallback rather than silently using partial data. The Manifest list is validation/fallback context, not permission to truncate an available authoritative list.

The full PR diff remains on-demand evidence. `extract-candidates` can selectively fetch specific file diffs using GitHub MCP or `git diff`; this step collects only complete paths.

### Step 3: Collect Linear Evidence (Optional)

For each entry in `identifiers.linear`:

1. Query Linear MCP for the issue by ID. Collect:
   - `title`
   - `description` (full body)
   - `comments` — array of `{ author, body, created_at }`
   - `labels` — array of label names
   - `status_changes` — status transition history (e.g., `[{ "from": "In Progress", "to": "Done", "changed_at": "ISO 8601", "actor": "username" }]`). Best-effort collection: try Linear MCP `getIssueHistory` or issue activity/audit log. Most Linear MCP implementations do not expose a dedicated history endpoint — if unavailable, set `status_changes: []` and move on. The evidence bundle remains valuable without transition history.
2. If Linear MCP is unavailable or the specific issue is not found:
   - Record: `{ "id": "...", "title": null, "description": null, "comments": [], "labels": [], "status_changes": [], "retrieved": false }`

Missing Linear content does NOT trigger `insufficient`. Linear issues are supplementary context that enriches the evidence bundle.

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

3. **Parse structured sections** from the memento note (7-section format):
   - Look for `## Recorded Decisions` section → extract decision slugs and commit SHAs as `decision_refs`
     - Expected line format: `` - `{slug}` ({sha}): {description} ``
   - Look for `## Vault Entries Referenced` section → extract entry IDs, signals, and notes as `vault_refs`
     - Expected line format: `` - `{entry_id}` [{signal}]: {note} ``
   - If these sections are absent (5-section legacy format), set both to empty arrays: `vault_refs: []`, `decision_refs: []`
   - Valid signals: `followed`, `outdated`, `conflicted`, `insufficient`

Missing memento notes do NOT trigger `insufficient`.

### Step 6: Collect Greptile Evidence (Optional)

For each entry in `identifiers.greptile`:

1. Derive Greptile comments **in-memory** from the normalized comments already assembled in Step 2. Filter both sources for entries whose author login contains "greptile" (case-insensitive):
   - `evidence.pr.review_comments`, and
   - `evidence.pr.issue_comments`.

   This rule is transport-neutral: MUST NOT issue any additional gh CLI or GitHub MCP calls. Both transports have already normalized the same comment collections, so another read would be a redundant round-trip.

2. Collect `{ "path": "...", "line": N, "body": "..." }` for each matching comment. Issue-level comments carry no `path`/`line` — include them with those fields omitted or `null`.
3. Preserve the Manifest identifier's `review_id` unchanged in each `{ "review_id": review_id, "comments": [...] }` result.

Missing Greptile data does NOT trigger `insufficient`.

### Step 7: Collect Notion Evidence (Optional)

For each entry in `identifiers.notion`:

1. Use Notion MCP `notion-fetch` to retrieve the page:
   ```
   Use Notion MCP to fetch the page at the URL from the identifier. Extract page title and content (returned as Markdown).
   ```

2. If retrieved successfully: `{ "url": "...", "title": "Page Title", "content": "markdown content", "retrieved": true }`
3. If Notion MCP is unavailable or the page is not found: `{ "url": "...", "title": null, "content": null, "retrieved": false }`

Missing Notion content does NOT trigger `insufficient`. Notion pages are supplementary context — design documents, decision records, and meeting notes that enrich the evidence bundle.

### Step 8: Sufficiency Judgment

Evaluate evidence completeness using these rules:

| Condition | Verdict |
|-----------|---------|
| Changed file list present AND commit messages present | Required baseline met — `sufficient` |
| All optional sources (Linear, Slack, memento, Greptile, Notion) missing but required baseline met | `sufficient` |
| No Manifest found | `insufficient` |
| GitHub MCP authentication failed (401/403) on any required call | `insufficient` (see GitHub MCP Auth Failure below) |

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
  "missing": ["<specific required items, e.g., 'changed_files', 'commits', 'manifest'>"],
  "reason": "<Human-readable explanation of what is missing and why it matters>"
}
```

Return every optional source that was retrieved and mark unavailable optional entries as documented in Steps 3–7. Missing optional sources never changes a bundle with the required baseline from `sufficient` to `insufficient`.

**Auth failure is a special case** that does **not** follow this rule — see GitHub MCP Auth Failure (401/403) below. Partial data on auth failure must be discarded.

#### gh CLI Authentication Failure Detection

The gh fast path uses the command's exit status and captured stderr together. A non-zero call whose stderr contains `HTTP 401`, `HTTP 403`, or `Bad credentials` is auth-dead: stop immediately, discard every gh result collected for the PR, and return the same `missing: ["github_auth"]` sentinel below. Do not fall back to MCP for this case. A non-auth gh failure instead restarts the complete read through MCP as specified in Step 1b.

#### GitHub MCP Auth Failure (401/403)

A GitHub MCP call may return 401/403 mid-collection — typically because the workflow's installation token expired before the workflow finished. When this happens:

1. **Stop collecting immediately.** Do **not** continue with partially fetched data. PR title/body without comments, or comments without authors, would feed `extract-candidates` a misleading bundle.
2. **Discard any partial evidence** for this PR. Do not write incomplete fields into the bundle that would look "sufficient" to downstream stages.
3. **Return** the bundle with:
   ```json
   {
     "sufficiency": {
       "verdict": "insufficient",
       "missing": ["github_auth"],
       "reason": "GitHub MCP authentication failed (401/403). Token likely expired mid-run. PR will be retried on next batch."
     }
   }
   ```
4. The orchestrator (`batch-refine`) treats the `github_auth` missing tag as a special signal: it stops the per-PR loop and follows the **Unexpected 401** path (no graceful handoff, no retrigger). The PR remains `knowledge:pending` and is naturally picked up by the next cron run.

This rule supersedes the "graceful degradation" guidance for optional sources — auth failure on the required GitHub baseline is **never** acceptable. There is no partial-data path here.

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
        ],
        "retrieved": true
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
        "vault_refs": [
          { "entry_id": "entry-id", "signal": "followed", "note": "description of usage" }
        ],
        "decision_refs": [
          { "slug": "decision-slug", "commit_sha": "abc1234" }
        ]
      }
    ],
    "greptile": [
      {
        "review_id": "greptile-pr-1234",
        "comments": [
          { "path": "file.rb", "line": 10, "body": "review comment" }
        ]
      }
    ],
    "notion": [
      {
        "url": "https://notion.so/workspace/Design-Doc-abc123",
        "title": "Design Doc: Payment Flow",
        "content": "markdown content of the page",
        "retrieved": true
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
| No Manifest-like comment on PR | Return `insufficient` with reason after the normalized snapshot search. Do not proceed to later evidence stages. |
| Manifest JSON malformed or strict validation fails | Attempt 1d reconstruction from the normalized snapshot; only return `insufficient` if the reconstructed Manifest is still invalid. |
| Linear MCP unavailable | Set `retrieved: false` for all Linear entries. Continue — optional source. |
| Linear issue deleted/moved/not found | Set `retrieved: false` for that entry. Continue — optional source. |
| Slack content unretrievable | Set `retrieved: false` for that entry. Continue — optional source. |
| `git notes show` fails | Skip that memento entry. Continue — optional source. |
| Notion MCP unavailable | Set `retrieved: false` for all Notion entries. Continue — optional source. |
| Notion page not found / access denied | Set `retrieved: false` for that entry. Continue — optional source. |
| gh unavailable, unconfigured, or non-auth failure | Discard partial gh output and restart the entire GitHub collection through read-only GitHub MCP. |
| gh or MCP returns blanket HTTP 401/403 / bad credentials | Discard partial data and return `missing: ["github_auth"]`; auth classification takes priority over fallback and rate-limit handling. |
| Changed file list incomplete | Use the paginated files endpoint; if that non-auth read fails, restart the whole collection through MCP. Do not accept a truncated list. |
| gh rate limit without HTTP 403 | Discard all gh output and restart the complete GitHub collection through MCP. |
| GitHub MCP rate limit without HTTP 403 | Report failure to orchestrator. Orchestrator retries in next batch. |

## Constraints

- MUST NOT write any files to disk
- MUST NOT access or modify vault.db
- MUST NOT call any `knowledge-gate` commands (no CLI access in this step)
- MUST NOT extract knowledge candidates (that is `/knowledge-distillery:extract-candidates` — Stage B step 2)
- MUST NOT make sufficiency decisions beyond the defined rules — no subjective "I think this is enough"
- MUST return the Evidence Bundle in memory for the next step in the same subagent context
- MUST preserve all raw content without summarization or interpretation
- MUST NOT modify the PR (no comments, no label changes — the orchestrator handles that)
