# Adoption Guide

Use this guide in a repository that wants to adopt Knowledge Distillery.

## Prerequisites

- One supported installation path:
  - Claude Code plugin installation access
  - Node.js and `npx` for a portable Codex skill installation
- `sqlite3` available on the machine
- `jq` available if the project will run pipeline/admin commands
- Repository secrets for:
  - `ANTHROPIC_API_KEY`
  - `LINEAR_API_KEY` if Linear is used
  - `SLACK_API_KEY` if Slack is used as an evidence source
  - `NOTION_API_KEY` if Notion is used as an evidence source (requires a Notion integration with read access to referenced pages)
- Slack MCP server configured (optional — only if using Slack threads as evidence)
- Notion MCP server configured (optional — only if using Notion pages as evidence)

## 1. Install the Skills

Choose one installation path.

For Claude Code, install the plugin from this repository. Claude Code exposes the skills with the `/knowledge-distillery:*` namespace.

For Codex, install the portable skill directories:

```bash
npx skills add https://github.com/ether-moon/knowledge-distillery/tree/main/plugins/knowledge-distillery --skill '*' -a codex
```

Codex installs project skills under `.agents/skills/` by default or global skills under `$CODEX_HOME/skills/`. Each skill contains its own scripts and assets, so neither path requires `CLAUDE_PLUGIN_ROOT`.

## 2. Set Up the Repository

In the adopting repository, invoke the setup skill:

```text
Claude Code plugin: /knowledge-distillery:setup
Codex skill install: $setup
```

This sets up:

- `.knowledge/vault.db`
- `.knowledge/reports/`
- `.knowledge/changesets/`
- `.github/workflows/mark-evidence.yml`
- `.github/workflows/batch-refine.yml`
- `.github/workflows/curate-report.yml`
- `.github/workflows/apply-changeset.yml`
- Knowledge Vault and Memento sections in `AGENTS.md` or `CLAUDE.md`
- temporary-file rules in `.gitignore`
- repo-local hooks and hook configuration for the active agent

The skill validates the configuration at the end and reports the result.
Setup is complete when all verification checks pass.

For Codex, trust the repository and review new or changed hook definitions with `/hooks`. Portable skill installers copy skills but do not register lifecycle hooks; setup performs that host-specific step.

## 3. Configure the Repository

Review and adjust:

- Workflow target branches
- Workflow schedules
- Whether Linear integration is enabled
- Initial domains and seed entries for the vault

## 4. Seed Initial Knowledge

Create at least one global or cross-cutting rule so the runtime path is not empty on day one.

Example:

```bash
knowledge-gate domain-add global-conventions "Project-wide rules"
knowledge-gate domain-paths-add global-conventions "*"
knowledge-gate add \
  --type fact \
  --title "Keep Controllers Thin" \
  --claim "Keep controllers thin and push orchestration into dedicated services" \
  --body "## Background\nThis project keeps orchestration out of controllers.\n\n## Details\nMove multi-step flows into service objects." \
  --domain global-conventions \
  --considerations "Applies to request-handling entry points." \
  --evidence "pr:#1"
```

## 5. Operating Model

After adoption:

- Agents query the vault through `knowledge-gate`
- Raw evidence stays outside the vault
- Structural changes in uncovered areas still require human confirmation
- Batch refinement promotes only validated Fact / Anti-Pattern entries

## 6. First Production Check

Before relying on the system, confirm:

- The setup skill reports all verification checks passed
- `knowledge-gate query-paths <file>` returns results for at least one representative path
- GitHub Actions can access the required secrets
- The generated workflows match the repository's branch and schedule policies
