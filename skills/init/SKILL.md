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

If it does not exist, initialize it through the bundled CLI:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate init-db .knowledge/vault.db
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
          claude_args: "--plugin-dir .knowledge-distillery-plugin --allowedTools mcp__github__*,mcp__linear__*,Bash(git:*),Read,Glob,Grep"
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
            Use skill /knowledge-distillery:batch-refine.
            Find all PRs with 'knowledge:pending' label,
            collect evidence using each PR's Evidence Bundle Manifest, run refinement pipeline,
            insert into vault.db via knowledge-gate _pipeline-insert.
            On success: update label to 'knowledge:collected'.
            On insufficient evidence: leave label as 'knowledge:pending' and report the reason.
            Create a Report PR with change summary.
          claude_args: "--plugin-dir .knowledge-distillery-plugin --allowedTools mcp__github__*,mcp__linear__*,Bash(sqlite3:*,git:*),Read,Write,Glob,Grep"
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

### Step 6: Run Self-Check

After all files are created or updated, verify the repository state through the bundled CLI:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate doctor
```

This command must succeed. If any check fails, stop and report the failing items instead of claiming initialization is complete.

### Step 7: Output Summary

Print a summary of all created/updated files:

```
Knowledge Distillery initialized:
  [created|exists] .knowledge/vault.db
  [created|exists] .knowledge/reports/
  [created|exists] .github/workflows/mark-evidence.yml
  [created|exists] .github/workflows/batch-refine.yml
  [updated|exists] CLAUDE.md (Knowledge Vault section)
  [updated|exists] .gitignore
  [passed] knowledge-gate doctor

Next steps:
  1. Add ANTHROPIC_API_KEY to your repository secrets
  2. Add LINEAR_API_KEY to your repository secrets (if using Linear)
  3. Seed initial entries: knowledge-gate add --type fact --title "..." ...
  4. Review and customize workflow schedules as needed
```

## Constraints

- Vault initialization must go through the bundled CLI command so schema asset lookup stays inside the plugin package
- Idempotent: safe to run multiple times without duplication
- Does NOT modify existing vault.db data
- Does NOT overwrite existing workflow files
- Does NOT remove existing CLAUDE.md content
- Final repository validation must go through `${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate doctor`
