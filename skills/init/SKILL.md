---
description: "Initializes the Knowledge Distillery in an adopting project. Creates vault.db, GitHub Actions workflows, CLAUDE.md Knowledge Vault section, and .gitignore entries. Run once per project via /knowledge-distillery:init. Safe to re-run (idempotent)."
---

# init — Knowledge Distillery Adoption Setup

## When to Use

Run `/knowledge-distillery:init` once in a new project to set up the Knowledge Distillery infrastructure. Safe to re-run — all operations are idempotent.

## What This Skill Creates

1. `.knowledge/vault.db` — SQLite vault initialized from the plugin's schema
2. `.knowledge/reports/` — Directory for batch report files
3. `.github/workflows/mark-evidence.yml` — Stage A workflow (merge-time marking)
4. `.github/workflows/batch-refine.yml` — Stage B workflow (batch collection + refinement)
5. Knowledge Vault section in `CLAUDE.md`
6. `.knowledge/` entries in `.gitignore`

## Execution Steps

### Step 1: Create Knowledge Vault

```bash
mkdir -p .knowledge
```

If `.knowledge/vault.db` already exists, skip this step (idempotent).

If it does not exist, initialize from the plugin's schema:

```bash
sqlite3 .knowledge/vault.db < ${CLAUDE_PLUGIN_ROOT}/schema/vault.sql
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
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

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
                  "X-MCP-Toolsets": "pull_requests",
                  "X-MCP-Readonly": "true"
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

      - uses: anthropics/claude-code-action@beta
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: |
            Use skill /knowledge-distillery:mark-evidence for PR #${{ github.event.pull_request.number }}.
            Extract evidence identifiers, write Evidence Bundle Manifest as PR comment,
            and add 'knowledge:pending' label.
          claude_args: "--allowedTools mcp__github__*,mcp__linear__*,Bash(gh:*),Bash(git:*),Read,Glob,Grep"
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
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

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
                  "X-MCP-Toolsets": "pull_requests"
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

      - uses: anthropics/claude-code-action@beta
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: |
            Use skill /knowledge-distillery:batch-refine.
            Find all PRs with 'knowledge:pending' or 'knowledge:insufficient' label,
            collect evidence using each PR's Evidence Bundle Manifest, run refinement pipeline,
            insert into vault.db via knowledge-gate _pipeline-insert.
            On success: update label to 'knowledge:collected'.
            On insufficient evidence: update label to 'knowledge:insufficient' (will be retried next run).
            On abandoned (3+ failed attempts): update label to 'knowledge:abandoned'.
            Create a Report PR with change summary.
          claude_args: "--allowedTools mcp__github__*,mcp__linear__*,Bash(gh:*),Bash(sqlite3:*),Bash(git:*),Read,Write,Glob,Grep"
```

### Step 4: Update CLAUDE.md

If `CLAUDE.md` does not exist, create it. If it exists, check if a `## Knowledge Vault` section already exists. If it does, skip (idempotent). Otherwise, append the following block:

```markdown
## Knowledge Vault
- Before modifying code, query related rules with `knowledge-gate query-paths <file-path>`
- Domain-level rule query: `knowledge-gate query-domain <domain-name>`
- Domain lookup: `knowledge-gate domain-info <domain-name>`, `domain-resolve-path <path>`
- MUST/MUST-NOT rules from related entries must be strictly followed
- For structural changes in areas without related rules, confirm with a human first
- Do not directly read files in the .knowledge/ directory
```

### Step 5: Update .gitignore

If `.gitignore` does not exist, create it. Check if `.knowledge/` related entries already exist. If not, append:

```
# Knowledge Distillery — vault is committed as binary, reports are committed
# Only ignore temporary/working files
.knowledge/tmp/
```

Note: `.knowledge/vault.db` and `.knowledge/reports/` are intentionally NOT gitignored — they are committed to the repository. Only temporary working files are ignored.

### Step 6: Output Summary

Print a summary of all created/updated files:

```
Knowledge Distillery initialized:
  [created|exists] .knowledge/vault.db
  [created|exists] .knowledge/reports/
  [created|exists] .github/workflows/mark-evidence.yml
  [created|exists] .github/workflows/batch-refine.yml
  [updated|exists] CLAUDE.md (Knowledge Vault section)
  [updated|exists] .gitignore

Next steps:
  1. Add ANTHROPIC_API_KEY to your repository secrets
  2. Add LINEAR_API_KEY to your repository secrets (if using Linear)
  3. Seed initial entries: knowledge-gate add --type fact --title "..." ...
  4. Review and customize workflow schedules as needed
```

## Constraints

- All files are read from the plugin package (`${CLAUDE_PLUGIN_ROOT}/schema/vault.sql`), NOT from ad hoc text
- Idempotent: safe to run multiple times without duplication
- Does NOT modify existing vault.db data
- Does NOT overwrite existing workflow files
- Does NOT remove existing CLAUDE.md content
