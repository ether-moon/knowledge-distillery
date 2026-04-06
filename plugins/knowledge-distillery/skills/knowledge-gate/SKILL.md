---
name: knowledge-gate
description: "Queries team-verified knowledge from the Knowledge Vault. A UserPromptSubmit hook reminds you when active vault entries exist — use this skill to query and interpret them before planning code changes."
argument-hint: "[file-path or keyword]"
---

# knowledge-gate

Query the Knowledge Vault (`.knowledge/vault.db`) before planning code changes. The vault contains team-verified Facts and Anti-Patterns that constrain how code should be written.

A `UserPromptSubmit` hook fires on each user prompt. When the vault has active entries, it reminds you to query before planning. Follow the reminder when the task involves code modifications; ignore it for non-code tasks.

**You MUST NOT directly read files in the `.knowledge/` directory.** All vault access goes through the `knowledge-gate` CLI.

## CLI Path

Resolve the CLI path once at session start. If `plugins/knowledge-distillery/scripts/knowledge-gate` exists in the current repo root, use the local development path. Otherwise use the installed plugin path:

- **Development repo**: `plugins/knowledge-distillery/scripts/knowledge-gate`
- **Installed plugin**: `${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate`

All commands below use `<knowledge-gate>` as a placeholder for the resolved executable path. Substitute the concrete path directly in the command; do NOT create or execute a shell variable such as `$GATE`.

```bash
<knowledge-gate> <command> [args]
```

If the CLI or vault is not available, inform the user: "Knowledge vault not configured. Proceeding without vault guidance." Then continue normally -- do not block work.

## Query Decision Tree

### Modifying a single file

```bash
# Returns a lightweight summary index by default
<knowledge-gate> query-paths "<filepath>"
```

### Modifying multiple files

Resolve domains first to avoid duplicate queries:

```bash
# 1. Resolve each file to its domain(s) -- a few representative files suffice
<knowledge-gate> domain-resolve-path "<filepath>"

# 2. Deduplicate the resolved domains, then query each one (summary index by default)
<knowledge-gate> query-domain "<domain>"
```

### Investigating a topic or concept

```bash
# Returns a lightweight summary index by default
<knowledge-gate> search "<keyword>"
```

### Getting full details for an entry

When a query returns entry IDs and you need the complete body:

```bash
<knowledge-gate> get "<id>"
<knowledge-gate> get-many "<id-1>" "<id-2>" ...
```

### Exploring what knowledge exists

When the relevant domain or keyword is unknown:

```bash
# Load a lightweight navigation-only domain index
<knowledge-gate> domain-list --ids-only

# Browse all active entries as a summary index
<knowledge-gate> list

# Browse full domain metadata only when needed
<knowledge-gate> domain-list
```

Then use `query-paths`, `query-domain`, or `search` for precise queries.

### Checking which domain a file belongs to

```bash
<knowledge-gate> domain-resolve-path "<filepath>"
<knowledge-gate> domain-info "<domain>"
```

## Behavioral Rules

### 1. Query once before planning

When the hook reminder fires and the task involves code changes, query relevant paths or domains before you start planning. Prefer one broad summary-index query for the task, then fetch full bodies only for the specific entry IDs you need with `get` or `get-many`. You do not need to re-query before each individual file edit.

### 2. Respect MUST / MUST-NOT claims

Vault entries are team-verified constraints. Treat them as authoritative rules:

- **MUST** rules: Follow unconditionally.
- **MUST-NOT** rules: Do not violate. Use the `alternative` field to find the correct approach.

### 3. Report conflicts

If your planned changes contradict a vault entry, surface the conflict to the user before proceeding. Never silently override a vault constraint.

### 4. Handle empty results (Soft Miss Principle)

No vault entries for a path or domain is a normal state -- the vault does not cover every code path.

- **Non-structural changes** (bug fixes, local refactoring, changes within existing patterns): Proceed normally, preserving existing code structure.
- **Structural changes** (new modules, architecture changes, pattern introductions): Trigger the Question Protocol below.

### 5. Question Protocol

When making structural changes and the vault returns no results, ask the user before proceeding. Present the question in this format:

```yaml
question_type: scope_gap | conflict | risk_check
blocking_scope: "<affected files/modules>"
needed_decision: "<what human choice is required>"
fallback: "<safe default behavior until answered>"
evidence_link:
  - "<related PR/issue references, if any>"
```

**Question types:**

- `scope_gap` -- Structural change in an area with no vault coverage
- `conflict` -- Planned change contradicts an existing vault entry
- `risk_check` -- Change touches a domain with existing constraints and needs human confirmation

### 6. Record vault usage

After using a vault entry's guidance in your work, append a usage record to `tmp/vault-refs.jsonl` (project root). Only record entries that influenced your decisions — not every queried result. See [Vault Usage Tracking](#vault-usage-tracking) below.

## Presenting Results

When vault queries return entries, present them as follows:

- Show `claim` prominently -- it is the actionable rule.
- Show `considerations` alongside -- caveats matter.
- For anti-patterns, show `alternative` -- it tells the user what to do instead.
- Reference `evidence` links only if the user asks "why?"
- Do NOT show `body` by default. Show it only if the user asks for details.

## Example Workflow

User asks: "Refactor the batch-refine pipeline to support parallel PR processing."

1. Hook fires: "Knowledge Vault active (12 entries). If this task involves code modifications, query relevant entries before planning."
2. Query the relevant domain:
   ```bash
   <knowledge-gate> domain-resolve-path "plugins/knowledge-distillery/skills/batch-refine/SKILL.md"
   # → domain: distillation-pipeline
   <knowledge-gate> query-domain "distillation-pipeline"
   <knowledge-gate> get-many "pipeline-stage-order" "parallelism-boundary"
   ```
3. Vault returns an entry:
   ```
   [FACT] Pipeline stages must execute sequentially per PR
   claim: "Stage B steps (collect → extract → quality-gate) MUST run in sequence for each PR."
   considerations: "Cross-PR parallelism is allowed; intra-PR parallelism is not."
   ```
4. Inform the user: "Vault says intra-PR stages must be sequential. I'll parallelize across PRs while keeping per-PR stages sequential."
5. Proceed with implementation respecting the constraint.

## Error Handling

| Failure | Response |
|---------|----------|
| `knowledge-gate` CLI not found | Inform user: "Knowledge vault not configured. Proceeding without vault guidance." Continue normally. |
| `vault.db` not found | Same as CLI not found -- degrade gracefully. |
| Query returns no results | Normal. Apply the Soft Miss Principle (see Behavioral Rules section 4). |
| Query returns an error | Log a warning, proceed without vault constraints. Do NOT block work. |

## Vault Usage Tracking

After querying the vault and **using** the results to guide your work, record the usage in `tmp/vault-refs.jsonl` (project root, gitignored):

```bash
mkdir -p tmp && echo '{"entry_id":"<entry-id>","queried_at":"<ISO-8601>","command":"<command-used>"}' >> tmp/vault-refs.jsonl
```

**Rules:**
- Only record entries you actually used to make decisions — do not record every query result
- Append one JSONL line per entry used
- Create the `tmp/` directory if it doesn't exist
- This file is consumed by `memento-commit` and cleared after each commit
- If the file cannot be written (permissions, disk), proceed normally — vault tracking is best-effort
