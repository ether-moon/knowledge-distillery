# Agent Installation Guide

Install or update Knowledge Distillery in the repository where the user sent this guide. Perform the procedure instead of only explaining it. Preserve existing vault data and unrelated configuration.

## 1. Confirm the Environment

Work from the adopting repository root. Confirm that `sqlite3`, `jq`, Node.js, and `npx` are available. Detect the active coding-agent host.

## 2. Install Runtime Skills at Project Scope

Install exactly four skills for the active host:

```bash
# Codex
npx skills add https://github.com/ether-moon/knowledge-distillery/tree/main/plugins/knowledge-distillery \
  --skill knowledge-gate --skill memento-commit \
  --skill memento-summary --skill record-decision \
  -a codex -y

# Claude Code with portable project skills
npx skills add https://github.com/ether-moon/knowledge-distillery/tree/main/plugins/knowledge-distillery \
  --skill knowledge-gate --skill memento-commit \
  --skill memento-summary --skill record-decision \
  -a claude-code -y
```

Do not add `-g` or use `--skill '*'`. Do not install `setup` or the pipeline-only skills (`mark-evidence`, `batch-refine`, `collect-evidence`, `extract-candidates`, `quality-gate`, and `curate-report`). Managed GitHub Actions load pipeline skills from their own plugin checkout.

Install the full Claude Code plugin only when the user explicitly requests the namespaced plugin distribution. Do not combine that path with duplicate portable project skills.

## 3. Create or Verify the Vault

Resolve the installed `knowledge-gate/scripts/knowledge-gate` under `.agents/skills/` for Codex or `.claude/skills/` for Claude Code.

If `.knowledge/vault.db` is absent, initialize it with that exact CLI path:

```bash
<knowledge-gate-path> init-db .knowledge/vault.db
```

If the vault exists, do not replace or mutate it. Require `PRAGMA user_version` ≥ 1 and confirm that all five required tables are present: `entries`, `entry_domains`, `domain_registry`, `domain_paths`, and `evidence`.

Create `.knowledge/reports`, `.knowledge/changesets`, and `.knowledge/decisions`.

## 4. Install Managed Workflows

Copy the canonical [workflow templates](../plugins/knowledge-distillery/install/workflows/) into `.github/workflows/`. Replace only these managed files:

- `mark-evidence.yml`
- `batch-refine.yml`
- `curate-report.yml`
- `apply-changeset.yml`

Keep the installed files byte-identical to their templates. Leave differences visible in the final git diff.

## 5. Install Hooks for the Active Host

Copy the three canonical [hook scripts](../plugins/knowledge-distillery/install/hooks/) into `.codex/hooks/` or `.claude/hooks/` and make them executable:

- `pre-prompt-knowledge-gate.sh`
- `pre-commit-memento.sh`
- `post-commit-memento.sh`

Merge [`codex-hooks.json`](../plugins/knowledge-distillery/install/hooks/codex-hooks.json) into `.codex/hooks.json` or [`claude-settings.json`](../plugins/knowledge-distillery/install/hooks/claude-settings.json) into `.claude/settings.json`.

Preserve unrelated keys, arrays, hooks, and permissions. Add each managed command exactly once. Install both host integrations only when the user explicitly requests both.

## 6. Add Agent Directives

Choose the directive file in this order:

1. Use `AGENTS.md` when it exists or is imported by `CLAUDE.md`.
2. Otherwise use an existing `CLAUDE.md`.
3. Create `CLAUDE.md` when neither file exists.

Append each missing heading while preserving existing content:

```markdown
## Knowledge Vault
- A UserPromptSubmit hook reminds you to query the vault when active entries exist
- For code changes, query with `knowledge-gate query-paths <file>`, `domain-resolve-path` plus `query-domain`, or `search <keyword>` before planning
- Fetch full details only for needed IDs with `knowledge-gate get <id>` or `get-many <id...>`
- Follow MUST/MUST-NOT rules; ask before structural changes in uncovered areas
- Never read `.knowledge/` files directly; use `knowledge-gate`

## Memento
- Use the installed `memento-commit` skill for every commit
- Attach its 7-section summary as a git note on `refs/notes/commits`
- Follow hook reminders and use `memento-summary` for recovery

## Decision Recording
- Use `record-decision` for confirmed scope, architecture, constraint, or direction decisions
- Do not record preferences, temporary debugging choices, or details obvious from code
```

## 7. Update Ignore Rules

Append these rules when missing. Do not remove existing rules:

```gitignore
# Knowledge Distillery temporary files
.knowledge/tmp/
tmp/

# Dynamic MCP config can contain runtime secrets
.mcp.json
```

## 8. Verify and Report

Verify:

- the four runtime skills are installed at project scope;
- the vault schema version and five required tables are healthy;
- `.knowledge/reports`, `.knowledge/changesets`, and `.knowledge/decisions` exist;
- all four workflows are byte-identical to their templates;
- all three active-host hook scripts exist and are executable;
- all three directive headings and ignore rules exist; and
- each managed hook command appears exactly once in the active host configuration.

For Codex, tell the user to trust the repository and review hooks with `/hooks`.

Report every managed path as `created`, `updated`, or `unchanged`, plus the vault schema version and verification result. Include these GitHub Actions follow-ups:

- Configure `ANTHROPIC_API_KEY`.
- Configure `LINEAR_API_KEY`, `SLACK_API_KEY`, or `NOTION_API_KEY` only for evidence sources the repository uses.
- Review workflow branches and schedules.
- Require `validate-changeset` before Report PRs can merge.
