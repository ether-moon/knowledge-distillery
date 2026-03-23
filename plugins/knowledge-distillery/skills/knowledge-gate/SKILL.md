---
description: Queries team-verified knowledge from the Knowledge Vault before code modification. Must be used when modifying files, creating new modules, or making architectural decisions.
---

# knowledge-gate

Query the Knowledge Vault (`.knowledge/vault.db`) before making code changes. The vault contains team-verified Facts and Anti-Patterns that constrain how code should be written.

**You MUST NOT directly read files in the `.knowledge/` directory.** All vault access goes through the `knowledge-gate` CLI.

## When to Use

- Before modifying code files
- Before creating new files or modules
- When making architectural or structural decisions
- When introducing new patterns or conventions
- When working in an unfamiliar area of the codebase

## CLI Path

All commands use the following path:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate <command> [args]
```

If the CLI or vault is not available, inform the user: "Knowledge vault not configured. Proceeding without vault guidance." Then continue normally -- do not block work.

## Query Decision Tree

### Modifying a single file

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate query-paths "<filepath>"
```

### Modifying multiple files

Resolve domains first to avoid duplicate queries:

```bash
# 1. Resolve each file to its domain(s) -- a few representative files suffice
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate domain-resolve-path "<filepath>"

# 2. Deduplicate the resolved domains, then query each one
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate query-domain "<domain>"
```

### Investigating a topic or concept

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate search "<keyword>"
```

### Getting full details for an entry

When a query returns an entry ID and you need the complete body:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate get "<id>"
```

### Exploring what knowledge exists

When the relevant domain or keyword is unknown:

```bash
# Browse all active entries
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate list

# Browse all domains
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate domain-list
```

Then use `query-paths`, `query-domain`, or `search` for precise queries.

### Checking which domain a file belongs to

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate domain-resolve-path "<filepath>"
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate domain-info "<domain>"
```

## Behavioral Rules

### 1. Query before modifying

Before changing any file, run `query-paths` for that file. Read and understand all returned entries before proceeding.

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

## Presenting Results

When vault queries return entries, present them as follows:

- Show `claim` prominently -- it is the actionable rule.
- Show `considerations` alongside -- caveats matter.
- For anti-patterns, show `alternative` -- it tells the user what to do instead.
- Reference `evidence` links only if the user asks "why?"
- Do NOT show `body` by default. Show it only if the user asks for details.

## Error Handling

| Failure | Response |
|---------|----------|
| `knowledge-gate` CLI not found | Inform user: "Knowledge vault not configured. Proceeding without vault guidance." Continue normally. |
| `vault.db` not found | Same as CLI not found -- degrade gracefully. |
| Query returns no results | Normal. Apply the Soft Miss Principle (see Behavioral Rules section 4). |
| Query returns an error | Log a warning, proceed without vault constraints. Do NOT block work. |
