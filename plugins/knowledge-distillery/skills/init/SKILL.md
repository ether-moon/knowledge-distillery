---
name: init
description: "Initializes the Knowledge Distillery in an adopting project. Creates vault.db, GitHub Actions workflows, CLAUDE.md Knowledge Vault section, and .gitignore entries. Run once per project via /knowledge-distillery:init. Safe to re-run (idempotent). Use when setting up, bootstrapping, or onboarding a new project into the Knowledge Distillery system — any mention of 'initialize', 'set up', 'install', or 'bootstrap' knowledge distillery should trigger this."
---

# init — Knowledge Distillery Adoption Setup

## When to Use

Run `/knowledge-distillery:init` once in a new project to set up the Knowledge Distillery infrastructure. Safe to re-run — all operations are idempotent.

## What This Skill Creates

1. `.knowledge/vault.db` — SQLite vault initialized from the plugin's schema
2. `.knowledge/reports/` — Directory for batch report files
3. `.github/workflows/mark-evidence.yml` — Stage A workflow (merge-time marking)
4. `.github/workflows/batch-refine.yml` — Stage B workflow (batch collection + refinement)
5. `.github/workflows/curate-report.yml` — Report PR curation workflow (comment-triggered)
6. Knowledge Vault & Memento sections in the project's directive file (CLAUDE.md or AGENTS.md)
7. `.knowledge/` entries in `.gitignore`
8. CLI permissions in `.claude/settings.json`

## Execution Steps

### Step 1: Create Knowledge Vault

```bash
mkdir -p .knowledge
```

If `.knowledge/vault.db` already exists, skip this step (idempotent).

If it does not exist, initialize it through the bundled CLI:

```bash
GATE init-db .knowledge/vault.db
```

Verify: `sqlite3 .knowledge/vault.db "PRAGMA user_version;"` should return `1`.

### Step 2: Create Reports Directory

```bash
mkdir -p .knowledge/reports
```

### Step 3: Generate GitHub Actions Workflows

Create `.github/workflows/` directory if it doesn't exist.

#### `.github/workflows/mark-evidence.yml`

If this file already exists, skip (idempotent).

Write the following content:

```yaml
name: Knowledge Distillery — Mark Evidence

on:
  pull_request:
    types: [closed]
    branches: [main, master]

jobs:
  mark-evidence:
    if: github.event.pull_request.merged == true
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Checkout Knowledge Distillery plugin
        uses: actions/checkout@v4
        with:
          repository: ether-moon/knowledge-distillery
          ref: main
          path: .knowledge-distillery-plugin

      - name: Write dynamic MCP config
        run: |
          echo "::add-mask::${{ secrets.LINEAR_API_KEY }}"
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
          claude_args: "--plugin-dir .knowledge-distillery-plugin"

      - name: Cleanup sensitive files
        if: always()
        run: rm -f .mcp.json
```

#### `.github/workflows/batch-refine.yml`

If this file already exists, skip (idempotent).

Write the following content:

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
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Checkout Knowledge Distillery plugin
        uses: actions/checkout@v4
        with:
          repository: ether-moon/knowledge-distillery
          ref: main
          path: .knowledge-distillery-plugin

      - name: Write dynamic MCP config
        run: |
          echo "::add-mask::${{ secrets.LINEAR_API_KEY }}"
          echo "::add-mask::${{ secrets.SLACK_API_KEY }}"
          echo "::add-mask::${{ secrets.NOTION_API_KEY }}"
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
            insert into vault.db via knowledge-gate _pipeline-insert.
            On success: update label to 'knowledge:collected'.
            On insufficient evidence: leave label as 'knowledge:pending' and report the reason.
            Create a Report PR with change summary.
          claude_args: "--plugin-dir .knowledge-distillery-plugin"

      - name: Cleanup sensitive files
        if: always()
        run: rm -f .mcp.json
```

#### `.github/workflows/curate-report.yml`

If this file already exists, skip (idempotent).

Write the following content:

```yaml
name: Knowledge Distillery — Curate Report

on:
  issue_comment:
    types: [created]

jobs:
  curate-report:
    if: >-
      github.event.issue.pull_request &&
      contains(github.event.comment.body, '/curate')
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
              core.setFailed('Not a Report PR branch: ' + branch);
              return;
            }
            core.setOutput('branch', branch);
            core.setOutput('pr_number', context.issue.number);

      - uses: actions/checkout@v4
        with:
          ref: ${{ steps.pr.outputs.branch }}
          fetch-depth: 0

      - name: Checkout Knowledge Distillery plugin
        uses: actions/checkout@v4
        with:
          repository: ether-moon/knowledge-distillery
          ref: main
          path: .knowledge-distillery-plugin

      - name: Write dynamic MCP config
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
        run: |
          git config user.name "${{ github.actor }}"
          git config user.email "${{ github.actor }}@users.noreply.github.com"

      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: |
            Use skill /knowledge-distillery:curate-report.
            Process reviewer feedback on Report PR #${{ steps.pr.outputs.pr_number }}
            (branch: ${{ steps.pr.outputs.branch }}).
            Read all PR comments, classify feedback into archive/update/keep actions,
            execute changes on vault.db, regenerate the batch report, commit, and post summary.
          claude_args: "--plugin-dir .knowledge-distillery-plugin --allowedTools 'mcp__github__*,Bash(*),Read(*),Write(*),Glob(*),Grep(*),Skill(*),Agent(*)'"
          show_full_output: true

      - name: Cleanup sensitive files
        if: always()
        run: rm -f .mcp.json
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
- Before modifying code, query related rules with `knowledge-gate query-paths <file-path>`
- Domain-level rule query: `knowledge-gate query-domain <domain-name>`
- Domain lookup: `knowledge-gate domain-info <domain-name>`, `domain-resolve-path <path>`
- MUST/MUST-NOT rules from related entries must be strictly followed
- For structural changes in areas without related rules, confirm with a human first
- Do not directly read files in the .knowledge/ directory
```

**Memento section:**

```markdown
## Memento
- After every git commit, attach a memento session summary as a git note on `refs/notes/commits`
- The summary follows the 5-section format: Decisions Made, Problems Encountered, Constraints Identified, Open Questions, Context
- See `/knowledge-distillery:memento-commit` for the full workflow and format specification
- If the PostToolUse hook fires a reminder, follow it — generate the summary and attach the note
```

### Step 5: Update .gitignore

If `.gitignore` does not exist, create it. Check if `.knowledge/` related entries already exist. If not, append:

```
# Knowledge Distillery — vault is committed as binary, reports are committed
# Only ignore temporary/working files
.knowledge/tmp/
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

### Step 7: Run Self-Check

After all files are created or updated, verify the repository state through the bundled CLI:

```bash
GATE doctor
```

This command must succeed. If any check fails, stop and report the failing items instead of claiming initialization is complete.

### Step 8: Output Summary

Print a summary of all created/updated files:

```
Knowledge Distillery initialized:
  [created|exists] .knowledge/vault.db
  [created|exists] .knowledge/reports/
  [created|exists] .github/workflows/mark-evidence.yml
  [created|exists] .github/workflows/batch-refine.yml
  [created|exists] .github/workflows/curate-report.yml
  [updated|exists] <target file> (Knowledge Vault + Memento sections)
  [updated|exists] .gitignore
  [updated|exists] .claude/settings.json (CLI permissions)
  [passed] knowledge-gate doctor

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
- Does NOT overwrite existing workflow files
- Does NOT remove existing CLAUDE.md content
- Final repository validation must go through `GATE doctor`
