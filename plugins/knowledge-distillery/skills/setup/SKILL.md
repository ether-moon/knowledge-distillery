---
name: setup
description: "Sets up or updates Knowledge Distillery in a project. Creates vault, workflows, directive sections, and permissions — always converging to the latest expected state. Safe to re-run after plugin upgrades. Use when setting up, updating, or troubleshooting a Knowledge Distillery installation — any mention of 'initialize', 'set up', 'install', 'bootstrap', or 'update' knowledge distillery should trigger this."
---

# setup — Knowledge Distillery Setup

## When to Use

Run `/knowledge-distillery:setup` to set up a new project, update an existing installation after a plugin upgrade, or verify configuration state. Safe to re-run — always converges to the latest expected state.

## What This Skill Manages

1. `.knowledge/vault.db` — SQLite vault initialized from the plugin's schema
2. `.knowledge/reports/` — Directory for batch report files
3. `.knowledge/changesets/` — Directory for batch changeset files
4. `.github/workflows/mark-evidence.yml` — Stage A workflow (merge-time marking)
5. `.github/workflows/batch-refine.yml` — Stage B workflow (batch collection + refinement)
6. `.github/workflows/curate-report.yml` — Report PR curation workflow (comment-triggered)
7. `.github/workflows/apply-changeset.yml` — Post-merge workflow (applies changeset to vault.db)
8. Knowledge Vault & Memento sections in the project's directive file (CLAUDE.md or AGENTS.md)
9. `.knowledge/` entries in `.gitignore`
10. CLI permissions in `.claude/settings.json`

## Execution Steps

### Step 1: Create or Verify Knowledge Vault

```bash
mkdir -p .knowledge
```

If `.knowledge/vault.db` does not exist, initialize it:

```bash
GATE init-db .knowledge/vault.db
```

If `.knowledge/vault.db` already exists, verify its health:

```bash
sqlite3 .knowledge/vault.db "PRAGMA user_version;"
```

Expected: `1` or higher. If `0` or empty, report the problem and stop.

```bash
sqlite3 .knowledge/vault.db "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('entries','entry_domains','domain_registry','domain_paths','evidence');"
```

Expected: `5`. If less, report the problem and stop.

### Step 2: Create Reports and Changesets Directories

```bash
mkdir -p .knowledge/reports
mkdir -p .knowledge/changesets
```

### Step 3: Write GitHub Actions Workflows

Create `.github/workflows/` directory if it doesn't exist. Write each workflow file below. If the file already exists, overwrite it with the latest template.

#### `.github/workflows/mark-evidence.yml`

```yaml
name: Knowledge Distillery — Mark Evidence

on:
  pull_request:
    types: [closed]
    branches: [main, master]

jobs:
  mark-evidence:
    if: >-
      github.event.pull_request.merged == true &&
      !startsWith(github.event.pull_request.head.ref, 'knowledge/batch-')
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Checkout Knowledge Distillery plugin
        uses: actions/checkout@v6
        with:
          repository: ether-moon/knowledge-distillery
          ref: main
          path: .knowledge-distillery-plugin

      - name: Write dynamic MCP config
        run: |
          if [ -n "${{ secrets.LINEAR_API_KEY }}" ]; then echo "::add-mask::${{ secrets.LINEAR_API_KEY }}"; fi
          cat > .mcp.json << 'MCPEOF'
          {
            "mcpServers": {
              "github": {
                "type": "http",
                "url": "https://api.githubcopilot.com/mcp/",
                "headers": {
                  "Authorization": "Bearer ${{ secrets.GITHUB_TOKEN }}",
                  "X-MCP-Toolsets": "pull_requests,issues,labels"
                }
              },
              "linear": {
                "type": "stdio",
                "command": "npx",
                "args": ["-y", "mcp-linear"],
                "env": {
                  "LINEAR_API_KEY": "${{ secrets.LINEAR_API_KEY }}"
                }
              }
            }
          }
          MCPEOF

      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: |
            Use skill /knowledge-distillery:mark-evidence for PR #${{ github.event.pull_request.number }}.
            Extract evidence identifiers, write Evidence Bundle Manifest as PR comment,
            and add 'knowledge:pending' label.
          claude_args: "--plugin-dir .knowledge-distillery-plugin --allowedTools 'mcp__github__*,mcp__linear__*,Bash(*),Read(*),Glob(*),Grep(*),Skill(*),Agent(*)'"
          show_full_output: true

      - name: Cleanup sensitive files
        if: always()
        run: rm -f .mcp.json
```

#### `.github/workflows/batch-refine.yml`

```yaml
name: Knowledge Distillery — Batch Refine

on:
  schedule:
    - cron: '0 9 * * 1'  # Every Monday 09:00 UTC
  workflow_dispatch:

jobs:
  collect-and-refine:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      issues: write
      id-token: write
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Checkout Knowledge Distillery plugin
        uses: actions/checkout@v6
        with:
          repository: ether-moon/knowledge-distillery
          ref: main
          path: .knowledge-distillery-plugin

      - name: Write dynamic MCP config
        run: |
          if [ -n "${{ secrets.LINEAR_API_KEY }}" ]; then echo "::add-mask::${{ secrets.LINEAR_API_KEY }}"; fi
          if [ -n "${{ secrets.SLACK_API_KEY }}" ]; then echo "::add-mask::${{ secrets.SLACK_API_KEY }}"; fi
          if [ -n "${{ secrets.NOTION_API_KEY }}" ]; then echo "::add-mask::${{ secrets.NOTION_API_KEY }}"; fi
          cat > .mcp.json << 'MCPEOF'
          {
            "mcpServers": {
              "github": {
                "type": "http",
                "url": "https://api.githubcopilot.com/mcp/",
                "headers": {
                  "Authorization": "Bearer ${{ secrets.GITHUB_TOKEN }}",
                  "X-MCP-Toolsets": "pull_requests,issues,labels"
                }
              },
              "linear": {
                "type": "stdio",
                "command": "npx",
                "args": ["-y", "mcp-linear"],
                "env": {
                  "LINEAR_API_KEY": "${{ secrets.LINEAR_API_KEY }}"
                }
              },
              "slack": {
                "type": "stdio",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-slack"],
                "env": {
                  "SLACK_BOT_TOKEN": "${{ secrets.SLACK_API_KEY }}"
                }
              },
              "notion": {
                "type": "stdio",
                "command": "npx",
                "args": ["-y", "@notionhq/notion-mcp-server"],
                "env": {
                  "OPENAPI_MCP_HEADERS": "{\"Authorization\": \"Bearer ${{ secrets.NOTION_API_KEY }}\", \"Notion-Version\": \"2022-06-28\"}"
                }
              }
            }
          }
          MCPEOF

      - name: Configure git identity
        run: |
          git config user.name "${{ github.actor }}"
          git config user.email "${{ github.actor }}@users.noreply.github.com"

      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: |
            Use skill /knowledge-distillery:batch-refine.
            Find all PRs with 'knowledge:pending' label,
            collect evidence using each PR's Evidence Bundle Manifest, run refinement pipeline,
            write accepted entries to a changeset file.
            Naming conventions (MUST follow exactly):
            - Report branch: knowledge/batch-YYYY-MM-DD (e.g. knowledge/batch-2026-03-27)
            - Changeset file: .knowledge/changesets/batch-YYYY-MM-DD.json
            - Only entries with .entries[].status == "accepted" are included
            On success: update label to 'knowledge:collected'.
            On insufficient evidence: leave label as 'knowledge:pending' and report the reason.
            Create a Report PR with change summary.
            Do NOT modify vault.db directly — the changeset will be applied on merge.
          claude_args: "--plugin-dir .knowledge-distillery-plugin --allowedTools 'mcp__github__*,mcp__linear__*,mcp__slack__*,mcp__notion__*,Bash(*),Read(*),Write(*),Glob(*),Grep(*),Skill(*),Agent(*)'"
          show_full_output: true

      - name: Cleanup sensitive files
        if: always()
        run: rm -f .mcp.json
```

#### `.github/workflows/curate-report.yml`

```yaml
name: Knowledge Distillery — Curate Report

on:
  issue_comment:
    types: [created]

jobs:
  curate-report:
    if: >-
      github.event.issue.pull_request &&
      contains(github.event.comment.body, '/curate') &&
      contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association)
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      issues: write
      id-token: write
    steps:
      - name: Get PR details
        id: pr
        uses: actions/github-script@v7
        with:
          script: |
            const pr = await github.rest.pulls.get({
              owner: context.repo.owner,
              repo: context.repo.repo,
              pull_number: context.issue.number
            });
            const branch = pr.data.head.ref;
            if (!branch.startsWith('knowledge/batch-')) {
              core.notice('Skipping: not a Report PR branch (' + branch + ')');
              core.setOutput('skip', 'true');
              return;
            }
            core.setOutput('skip', 'false');
            core.setOutput('branch', branch);
            core.setOutput('pr_number', context.issue.number);

      - uses: actions/checkout@v6
        if: steps.pr.outputs.skip != 'true'
        with:
          ref: ${{ steps.pr.outputs.branch }}
          fetch-depth: 0

      - name: Checkout Knowledge Distillery plugin
        if: steps.pr.outputs.skip != 'true'
        uses: actions/checkout@v6
        with:
          repository: ether-moon/knowledge-distillery
          ref: main
          path: .knowledge-distillery-plugin

      - name: Write dynamic MCP config
        if: steps.pr.outputs.skip != 'true'
        run: |
          cat > .mcp.json << 'MCPEOF'
          {
            "mcpServers": {
              "github": {
                "type": "http",
                "url": "https://api.githubcopilot.com/mcp/",
                "headers": {
                  "Authorization": "Bearer ${{ secrets.GITHUB_TOKEN }}",
                  "X-MCP-Toolsets": "pull_requests,issues"
                }
              }
            }
          }
          MCPEOF

      - name: Configure git identity
        if: steps.pr.outputs.skip != 'true'
        run: |
          git config user.name "${{ github.actor }}"
          git config user.email "${{ github.actor }}@users.noreply.github.com"

      - uses: anthropics/claude-code-action@v1
        if: steps.pr.outputs.skip != 'true'
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: |
            Use skill /knowledge-distillery:curate-report.
            Process reviewer feedback on Report PR #${{ steps.pr.outputs.pr_number }}
            (branch: ${{ steps.pr.outputs.branch }}).
            Read all PR comments, classify feedback into reject/update/keep actions,
            update the changeset file (.knowledge/changesets/), regenerate the batch report, commit, and post summary.
            Do NOT modify vault.db directly — operate on the changeset file only.
          claude_args: "--plugin-dir .knowledge-distillery-plugin --allowedTools 'mcp__github__*,Bash(*),Read(*),Write(*),Glob(*),Grep(*),Skill(*),Agent(*)'"
          show_full_output: true

      - name: Cleanup sensitive files
        if: always() && steps.pr.outputs.skip != 'true'
        run: rm -f .mcp.json
```

#### `.github/workflows/apply-changeset.yml`

```yaml
name: Knowledge Distillery — Apply Changeset

on:
  pull_request:
    types: [closed]
    branches: [main, master]

jobs:
  apply-changeset:
    if: >-
      github.event.pull_request.merged &&
      startsWith(github.event.pull_request.head.ref, 'knowledge/batch-')
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v6
        with:
          ref: ${{ github.event.pull_request.base.ref }}
          fetch-depth: 0

      - name: Checkout Knowledge Distillery plugin
        uses: actions/checkout@v6
        with:
          repository: ether-moon/knowledge-distillery
          ref: main
          path: .knowledge-distillery-plugin

      - name: Configure git identity
        run: |
          git config user.name "knowledge-distillery[bot]"
          git config user.email "knowledge-distillery[bot]@users.noreply.github.com"

      - name: Extract batch date from branch name
        id: batch
        env:
          BRANCH: ${{ github.event.pull_request.head.ref }}
        run: |
          if [[ ! "$BRANCH" =~ ^knowledge/batch-([0-9]{4}-[0-9]{2}-[0-9]{2})(-[0-9]+)?$ ]]; then
            echo "::error::Unexpected branch format: ${BRANCH}"
            exit 1
          fi
          DATE="${BASH_REMATCH[1]}"
          echo "date=${DATE}" >> "$GITHUB_OUTPUT"
          echo "Batch date: ${DATE}"

      - name: Find and apply changeset
        run: |
          GATE=$(find .knowledge-distillery-plugin -name knowledge-gate -path '*/scripts/*' -type f | head -1)
          if [ -z "$GATE" ]; then
            echo "::error::knowledge-gate script not found in plugin checkout"
            exit 1
          fi
          chmod +x "$GATE"

          CHANGESET=".knowledge/changesets/batch-${{ steps.batch.outputs.date }}.json"

          if [ ! -f "$CHANGESET" ]; then
            echo "::warning::No changeset file found at ${CHANGESET} — skipping"
            exit 0
          fi

          ACCEPTED=$(jq '[.entries[] | select(.status == "accepted")] | length' "$CHANGESET")
          echo "Accepted entries to apply: ${ACCEPTED}"

          if [ "$ACCEPTED" -eq 0 ]; then
            echo "No accepted entries — skipping vault update"
            exit 0
          fi

          "$GATE" _changeset-apply "$CHANGESET"

      - name: Commit and push vault.db
        run: |
          if git diff --quiet .knowledge/vault.db 2>/dev/null; then
            echo "No vault.db changes — skipping commit"
            exit 0
          fi

          git add .knowledge/vault.db
          git commit -m "knowledge: apply batch ${{ steps.batch.outputs.date }} changeset"
          git push origin ${{ github.event.pull_request.base.ref }}

      - name: Clean up batch artifacts
        env:
          BATCH_DATE: ${{ steps.batch.outputs.date }}
        run: |
          CHANGESET=".knowledge/changesets/batch-${BATCH_DATE}.json"
          REPORT=".knowledge/reports/batch-${BATCH_DATE}.md"
          CHANGED=false

          if [ -f "$CHANGESET" ]; then
            git rm "$CHANGESET"
            CHANGED=true
          fi

          if [ -f "$REPORT" ]; then
            git rm "$REPORT"
            CHANGED=true
          fi

          if [ "$CHANGED" = true ]; then
            git pull --rebase origin ${{ github.event.pull_request.base.ref }}
            git commit -m "knowledge: clean up batch ${BATCH_DATE} artifacts"
            git push origin ${{ github.event.pull_request.base.ref }}
          fi
```

### Step 4: Add Directive Sections

Two sections need to be added: **Knowledge Vault** and **Memento**. The target file depends on the project's existing directive pattern.

#### 4a: Detect target file

Check the project root for directive files and determine where to append:

| Project state | Target file |
|---------------|-------------|
| `CLAUDE.md` contains `@AGENTS.md` | `AGENTS.md` (create if missing) |
| `AGENTS.md` exists (no `@AGENTS.md` in CLAUDE.md) | `AGENTS.md` |
| Only `CLAUDE.md` exists | `CLAUDE.md` |
| Neither exists | Create `CLAUDE.md` |

#### 4b: Append sections (idempotent)

For each section below, check if it already exists in the target file (search for the `##` heading). Skip any section that already exists.

**Knowledge Vault section:**

```markdown
## Knowledge Vault
- A UserPromptSubmit hook reminds you to query the vault when active entries exist
- When the hook fires and the task involves code modifications, query before planning:
  - Single file: `knowledge-gate query-paths <file-path>` (summary index by default)
  - Multiple files: `knowledge-gate domain-resolve-path <path>` → `knowledge-gate query-domain <domain>` (summary index by default)
  - Topic search: `knowledge-gate search <keyword>` (summary index by default)
  - Fetch full details only for the specific entries you need: `knowledge-gate get <id>` or `knowledge-gate get-many <id...>`
- MUST/MUST-NOT rules from returned entries must be strictly followed
- For structural changes in areas without related rules, confirm with a human first
- Do not directly read files in the .knowledge/ directory
```

**Memento section:**

```markdown
## Memento
- After every git commit, attach a memento session summary as a git note on `refs/notes/commits`
- The summary follows the 7-section format: Decisions Made, Problems Encountered, Constraints Identified, Open Questions, Context, Recorded Decisions, Vault Entries Referenced
- See `/knowledge-distillery:memento-commit` for the full workflow and format specification
- If the PostToolUse hook fires a reminder, follow it — generate the summary and attach the note
```

### Step 5: Update .gitignore

If `.gitignore` does not exist, create it. Check if `.knowledge/` related entries already exist. If not, append:

```
# Knowledge Distillery — vault is committed as binary, reports are committed
# Only ignore temporary/working files
.knowledge/tmp/

# Vault usage tracking (consumed and cleared by memento-commit)
tmp/

# Dynamic MCP config — contains secrets at runtime, must never be committed
.mcp.json
```

Note: `.knowledge/vault.db` and `.knowledge/reports/` are intentionally NOT gitignored — they are committed to the repository. Only temporary working files are ignored.

### Step 6: Add CLI Permissions to .claude/settings.json

The `knowledge-gate` CLI requires Bash permissions to run without manual approval. Add them to the project-level `.claude/settings.json` so all team members get them automatically.

Read `.claude/settings.json` if it exists. Merge the following permissions into the `permissions.allow` array (skip any that already exist):

```json
{
  "permissions": {
    "allow": [
      "Bash(*/knowledge-gate:*)",
      "Bash(sqlite3 .knowledge/vault.db:*)"
    ]
  }
}
```

- `Bash(*/knowledge-gate:*)` — allows running the CLI from any install path (plugin cache path varies per machine)
- `Bash(sqlite3 .knowledge/vault.db:*)` — allows direct vault queries for verification

Preserve all existing keys in the file. Only add to the `permissions.allow` array.

### Step 7: Verify Setup

After all files are created or updated, verify the repository state:

```bash
sqlite3 .knowledge/vault.db "PRAGMA user_version;"
# Expected: >= 1

sqlite3 .knowledge/vault.db "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('entries','entry_domains','domain_registry','domain_paths','evidence');"
# Expected: 5

ls -d .knowledge/reports .knowledge/changesets .github/workflows/mark-evidence.yml .github/workflows/batch-refine.yml .github/workflows/curate-report.yml .github/workflows/apply-changeset.yml
# All should exist
```

Verify directive file contains both sections:

```bash
grep -Fq '## Knowledge Vault' <directive-file>
grep -Fq '## Memento' <directive-file>
```

Verify .gitignore entries:

```bash
grep -Fq '.knowledge/tmp/' .gitignore
grep -Fq '.mcp.json' .gitignore
```

If any check fails after the create/update steps, report the specific failure.

### Step 8: Output Summary

Print a summary of all managed files:

```
Knowledge Distillery setup complete:
  [created|updated|unchanged] .knowledge/vault.db (schema v<N>)
  [created|unchanged] .knowledge/reports/
  [created|unchanged] .knowledge/changesets/
  [created|updated] .github/workflows/mark-evidence.yml
  [created|updated] .github/workflows/batch-refine.yml
  [created|updated] .github/workflows/curate-report.yml
  [created|updated] .github/workflows/apply-changeset.yml
  [created|updated|unchanged] <target file> (Knowledge Vault + Memento sections)
  [created|updated|unchanged] .gitignore
  [created|updated|unchanged] .claude/settings.json (CLI permissions)
  Verification: all checks passed

Next steps:
  1. Add ANTHROPIC_API_KEY to your repository secrets
  2. Add LINEAR_API_KEY to your repository secrets (if using Linear)
  3. Add SLACK_API_KEY to your repository secrets (if using Slack as evidence source)
  4. Add NOTION_API_KEY to your repository secrets (if using Notion as evidence source)
  5. Seed initial entries: knowledge-gate add --type fact --title "..." ...
  6. Review and customize workflow schedules as needed
```

## Constraints

- Vault initialization must go through the bundled CLI command so schema asset lookup stays inside the plugin package
- Idempotent: safe to run multiple times without duplication
- Does NOT modify existing vault.db data
- Workflows are always overwritten with the latest templates — user customizations are visible in git diff
- Does NOT remove existing directive file content (only appends missing sections)
