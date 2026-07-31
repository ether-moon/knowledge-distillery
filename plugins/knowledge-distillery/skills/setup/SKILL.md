---
name: setup
description: "Sets up or updates Knowledge Distillery in a repository. Use when initializing, installing, bootstrapping, updating, repairing, or verifying a Knowledge Distillery installation in Codex, Claude Code, or another agent that installs portable skills."
---

# Set Up Knowledge Distillery

Converge an adopting repository to the current Knowledge Distillery layout. Preserve existing vault data and unrelated configuration. Use the user's language for progress, warnings, and the final summary.

## Resolve Bundled Resources

Resolve the directory containing this `SKILL.md` as `<setup-skill-directory>`.

Resolve the `knowledge-gate` CLI in this order:

1. Use an exact CLI path supplied by the UserPromptSubmit hook.
2. Use the sibling skill at `<setup-skill-directory>/../knowledge-gate/scripts/knowledge-gate`.
3. Use a separately installed `knowledge-gate` skill path visible in the current skill catalog.

If no CLI exists, stop and ask the user to install the `knowledge-gate` skill. Do not fall back to a plugin-root environment variable.

Bundled setup resources:

- Hook installer: `<setup-skill-directory>/scripts/install-hooks`
- Workflow templates: `<setup-skill-directory>/assets/workflows/`

Substitute concrete absolute paths in commands. Do not create a shell variable for an executable path.

## 1. Create or Verify the Vault

Create `.knowledge/` when absent. If `.knowledge/vault.db` does not exist, initialize it:

```bash
<knowledge-gate> init-db .knowledge/vault.db
```

If it exists, verify without modifying data:

```bash
sqlite3 .knowledge/vault.db "PRAGMA user_version;"
sqlite3 .knowledge/vault.db "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('entries','entry_domains','domain_registry','domain_paths','evidence');"
```

Require schema version `1` or higher and exactly five required tables. Stop and report the failed check instead of replacing an unhealthy vault.

Create the working directories:

```bash
mkdir -p .knowledge/reports .knowledge/changesets
```

## 2. Install Workflow Templates

Create `.github/workflows/`, then copy these bundled assets into it:

```text
<setup-skill-directory>/assets/workflows/mark-evidence.yml
  → .github/workflows/mark-evidence.yml
<setup-skill-directory>/assets/workflows/batch-refine.yml
  → .github/workflows/batch-refine.yml
<setup-skill-directory>/assets/workflows/curate-report.yml
  → .github/workflows/curate-report.yml
<setup-skill-directory>/assets/workflows/apply-changeset.yml
  → .github/workflows/apply-changeset.yml
```

Always replace managed workflow files with the current templates. Leave user-visible differences in the git diff.

The managed `apply-changeset.yml` runs a read-only `validate-changeset` job on open Report PRs and applies the same changeset only after merge. Repository branch protection should require `validate-changeset` before Report PRs can merge.

## 3. Install Agent Hooks

Install hooks for the active host:

```bash
<setup-skill-directory>/scripts/install-hooks codex <project-root>
<setup-skill-directory>/scripts/install-hooks claude-code <project-root>
```

- Use `codex` for Codex. This writes scripts under `.codex/hooks/` and merges `.codex/hooks.json`.
- Use `claude-code` for Claude Code. This writes scripts under `.claude/hooks/` and merges `.claude/settings.json`.
- Install both only when the user explicitly wants both repository integrations.

The installer must preserve unrelated configuration, replace managed hook scripts, and avoid duplicate hook entries when re-run. Codex project hooks require a trusted project and user review through `/hooks` after a new or changed hook definition.

Hooks are installed by setup; do not depend on plugin auto-loading or `CLAUDE_PLUGIN_ROOT`.

## 4. Add Directive Sections

Choose the directive file:

| Repository state | Target |
|---|---|
| `CLAUDE.md` contains `@AGENTS.md` | `AGENTS.md` |
| `AGENTS.md` exists | `AGENTS.md` |
| Only `CLAUDE.md` exists | `CLAUDE.md` |
| Neither exists | Create `CLAUDE.md` |

Append each missing section by heading. Preserve all existing content.

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

## Memento
- After every git commit, attach a memento session summary as a git note on `refs/notes/commits`
- The summary follows the 7-section format: Decisions Made, Problems Encountered, Constraints Identified, Open Questions, Context, Recorded Decisions, Vault Entries Referenced
- See `/knowledge-distillery:memento-commit` for the full workflow and format specification
- If a hook fires a reminder, follow it and attach the note
```

## 5. Update Ignore and Claude Permissions

Append missing ignore entries without removing existing rules:

```gitignore
# Knowledge Distillery temporary files
.knowledge/tmp/
tmp/

# Dynamic MCP config can contain runtime secrets
.mcp.json
```

For Claude Code, merge these entries into `.claude/settings.json` under `permissions.allow`:

```json
[
  "Bash(*/knowledge-gate:*)",
  "Bash(sqlite3 .knowledge/vault.db:*)"
]
```

Preserve every unrelated key and permission. Codex permissions remain controlled by the active Codex configuration and sandbox.

## 6. Verify

Run deterministic checks:

```bash
sqlite3 .knowledge/vault.db "PRAGMA user_version;"
sqlite3 .knowledge/vault.db "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('entries','entry_domains','domain_registry','domain_paths','evidence');"
test -d .knowledge/reports
test -d .knowledge/changesets
test -f .github/workflows/mark-evidence.yml
test -f .github/workflows/batch-refine.yml
test -f .github/workflows/curate-report.yml
test -f .github/workflows/apply-changeset.yml
```

Also verify both directive headings, the ignore entries, the active host's hook scripts, and exactly one configured entry for each managed hook command.

## 7. Report

Report every managed path as `created`, `updated`, or `unchanged`, the vault schema version, active host, hook review requirement, and verification result. Include repository-secret next steps only when GitHub Actions were installed.

## Constraints

- Initialize a new vault only through the bundled skill-local CLI and schema asset.
- Never replace or directly mutate existing vault data during setup.
- Keep setup idempotent.
- Overwrite only the four managed workflow templates and three managed hook scripts.
- Preserve unrelated directive, ignore, hook, and settings content.
