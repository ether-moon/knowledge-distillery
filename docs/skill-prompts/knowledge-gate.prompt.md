# Knowledge Gate — Skill Creation Prompt

## Purpose

Generate a skill file that integrates knowledge-gate CLI queries into an AI coding agent's workflow. When installed in a project, this skill instructs the agent to consult the Knowledge Vault before making code changes, ensuring decisions align with team-verified knowledge.

The generated skill file is designed for inclusion in agent configuration files (CLAUDE.md, .cursorrules, etc.) — not as a standalone executable.

## Pipeline Position

- **Trigger**: Agent runtime — before code changes, during architecture decisions, on scope uncertainty
- **Depends on**: Populated vault.db with active entries
- **Produces**: Agent configuration content (skill definition for embedding)
- **Consumed by**: AI coding agents (Claude Code, Cursor, etc.)

## Prerequisites

### Runtime Environment (of the generated skill)
- `knowledge-gate` CLI installed and on PATH
- `.knowledge/vault.db` present in the repository
- Agent has Bash tool access to run CLI commands
- Domain registry populated with at least initial domains

### Allowed Tools (of the generated skill)
- Bash: `knowledge-gate query-paths`, `query-domain`, `search`, `get`, `list`
- Bash: `knowledge-gate domain-info`, `domain-resolve-path`, `domain-list`
- No vault.db direct access. No write operations.

## Input Contract

The skill creation prompt receives no runtime input. It generates a static skill definition.

Configuration context needed at generation time:

| Field | Source | Required |
|-------|--------|----------|
| Agent type | User specification (Claude Code, Cursor, etc.) | Yes |
| Config file path | User specification (CLAUDE.md, .cursorrules, etc.) | Yes |
| knowledge-gate CLI path | Default: `${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate` (Plugin 환경). Non-plugin: `bin/knowledge-gate` or user override | Yes |

## Output Contract

A skill file containing:

1. **Skill definition block** — ready to embed in agent config
2. **Usage instructions** — when and how the agent should invoke it
3. **Query decision tree** — which CLI command to use for which situation

The generated content MUST be self-contained — an agent reading only this skill definition should know exactly when and how to query the vault.

## Behavioral Requirements

### Step 1: Generate Skill Header

Include skill metadata:
- Name: `knowledge-gate`
- Purpose: Query team-verified knowledge before code changes
- Trigger conditions: File modifications, architecture decisions, unfamiliar domains

### Step 2: Generate Query Decision Tree

The skill MUST include a clear decision tree (derived from cli.md §5):

```
When modifying a single file:
  → knowledge-gate query-paths "<filepath>"

When modifying multiple files:
  → For each file: knowledge-gate domain-resolve-path "<filepath>"
  → Deduplicate resolved domains
  → For each domain: knowledge-gate query-domain "<domain>"

When investigating a topic/concept:
  → knowledge-gate search "<keyword>"

When a query returns an entry ID and you need details:
  → knowledge-gate get "<id>"

When exploring what knowledge exists:
  → knowledge-gate list
  → knowledge-gate domain-list

When unsure which domain a file belongs to:
  → knowledge-gate domain-resolve-path "<filepath>"
  → knowledge-gate domain-info "<domain>"
```

### Step 3: Generate Behavioral Instructions

The skill MUST instruct the agent to:

1. **Query before modifying**: Before changing any file, run `query-paths` for that file
2. **Respect MUST/MUST-NOT claims**: Treat vault entries as team-verified constraints
3. **Report conflicts**: If planned changes contradict a vault entry, surface the conflict to the user before proceeding
4. **Handle empty results**: No vault entries for a path/domain is fine — proceed normally
5. **Soft miss — proceed or ask based on change scope**: If vault returns no results:
   - **Non-structural changes** (bug fixes, local refactoring): Proceed normally, preserving existing code structure
   - **Structural changes** (new modules, architecture changes, pattern introductions): Trigger question protocol (design-implementation.md §7.2-7.3)

### Step 4: Generate Question Protocol Template

Include the question protocol format (design-implementation.md §7.3):

```yaml
question_type: scope_gap | conflict | risk_check
blocking_scope: "<affected files/modules>"
needed_decision: "<what human choice is required>"
fallback: "<safe default until answered>"
evidence_link: [<PR/issue references>]
```

### Step 5: Generate Output Format Instructions

Instruct the agent on how to present vault query results:

- Show `claim` prominently (it's the actionable rule)
- Show `considerations` alongside (caveats matter)
- Show `alternative` for anti-patterns (what to do instead)
- Link to `evidence` references for context if the user asks "why?"
- Do NOT show `body` by default — only if the user asks for details

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| `knowledge-gate` CLI not found | Instruct agent to inform user: "Knowledge vault not configured. Proceeding without vault guidance." |
| vault.db not found | Same as CLI not found — degrade gracefully |
| Query returns no results | Normal. Proceed without vault constraints for that scope. |
| Query returns error | Log warning, proceed without vault constraints. Do NOT block the agent's work. |

## Example Scenarios

### Scenario 1: Claude Code CLAUDE.md Integration

**Input**: Agent type = Claude Code, config = CLAUDE.md

**Generated skill content** (embedded in CLAUDE.md):

```markdown
## Knowledge Vault

Before modifying files, consult team-verified knowledge:

- Single file: `knowledge-gate query-paths "path/to/file"`
- Multiple files: resolve domains first with `domain-resolve-path`, then `query-domain`
- Topic search: `knowledge-gate search "keyword"`

Treat returned MUST/MUST-NOT claims as team constraints.
If your planned changes conflict with a vault entry, surface the conflict before proceeding.

If no results are returned, proceed normally — not all code paths have vault entries.
```

### Scenario 2: Cursor .cursorrules Integration

**Input**: Agent type = Cursor, config = .cursorrules

**Generated skill content** follows same structure, adapted for .cursorrules format.

### Scenario 3: Query Finds Relevant Entry

**Agent runtime behavior** (after skill is installed):

Agent is about to modify `app/services/payments/charge.rb`:
1. Runs `knowledge-gate query-paths "app/services/payments/charge.rb"`
2. Gets entry: "Use Service Objects for payment transaction orchestration"
3. Verifies planned changes align with this rule
4. Proceeds with confidence (or surfaces conflict if changes violate the rule)

## Reference Specifications

- CLI commands: cli.md §1-2 (query commands)
- Skill template: cli.md §5
- Question protocol: design-implementation.md §7.3
- Agent runtime behavior: design-implementation.md §7.1-7.5
- Context gate (convention-based access prohibition): design-implementation.md §4.1

## Constraints

- MUST NOT include vault.db direct access instructions — CLI only
- MUST NOT make the skill blocking — empty results should not halt agent work
- MUST generate self-contained content that works without referencing this prompt
- MUST adapt output format to the target agent's configuration format
- MUST include graceful degradation when CLI/vault is unavailable
- MUST include the question protocol for scope gap handling

## Validation Checklist

1. Does the generated skill include a query decision tree?
2. Does it instruct the agent to query before modifying files?
3. Does it include graceful degradation for missing CLI/vault?
4. Does it include the question protocol template?
5. Does it tell the agent how to present vault results (claim + considerations)?
6. Is the generated content self-contained (no external references needed)?
7. Does it adapt to the target agent configuration format?
8. Does it handle empty query results as normal (not error)?
