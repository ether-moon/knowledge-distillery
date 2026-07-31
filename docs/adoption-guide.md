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

## 1. Ask an Agent to Install the Skills

Give the coding agent the [Agent Installation Guide](agent-installation.md), either through the root README or as a direct URL. The guide is the source of truth for project-scoped skill selection, repository configuration, preservation rules, and verification.

The installer keeps four runtime skills in the adopting repository. The six pipeline-only skills are loaded by the managed workflows from their own plugin checkout.

## 2. Let the Installing Agent Configure the Repository

The same agent continues with the installation guide; there is no setup skill to invoke. It configures:

- `.knowledge/vault.db`
- `.knowledge/reports/`
- `.knowledge/changesets/`
- `.knowledge/decisions/`
- `.github/workflows/mark-evidence.yml`
- `.github/workflows/batch-refine.yml`
- `.github/workflows/curate-report.yml`
- `.github/workflows/apply-changeset.yml`
- Knowledge Vault, Memento, and Decision Recording sections in `AGENTS.md` or `CLAUDE.md`
- temporary-file rules in `.gitignore`
- repo-local hooks and hook configuration for the active agent

The agent fetches canonical assets from `plugins/knowledge-distillery/install/`, preserves unrelated configuration, validates the final state, and reports the result. Installation is complete only when all guide checks pass.

For Codex, trust the repository and review new or changed hook definitions with `/hooks`. Portable skill installers copy skills but do not register lifecycle hooks; the installation guide performs that host-specific step.

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

- The installing agent reports all installation-guide checks passed
- `knowledge-gate query-paths <file>` returns results for at least one representative path
- GitHub Actions can access the required secrets
- The generated workflows match the repository's branch and schedule policies
