---
name: record-decision
description: "Records a project decision as a committed markdown file under .knowledge/decisions/ for the knowledge distillery pipeline. Auto-triggered when clear project decisions are detected during a session — scope decisions, architectural choices, confirmed constraints, or direction after deliberation all qualify. Do not wait for the user to ask; invoke proactively when a decision moment is observed."
---

# record-decision

Records a project-level decision as a structured markdown file and commits it to git. The commit flows into the distillery pipeline when the branch merges as a PR (mark-evidence → batch-refine → vault), preserving the decision as verified team knowledge.

Mirrors the auto-memory pattern: Claude detects a clear decision moment and invokes this skill automatically without explicit user request.

## When to Use

Auto-invoke when a clear project decision is confirmed during the session:

- **Scope decisions**: "X is out of scope", "We won't support Y"
- **Architectural choices**: "Use approach A for Z", "Introduce pattern X"
- **Constraints confirmed**: "We can't do X because Y"
- **Direction after deliberation**: User considers alternatives and settles on one

Do NOT invoke for:

- **User preferences** — use auto-memory instead (editor settings, communication style, workflow habits)
- **Temporary choices** — debugging workarounds, local-only configuration
- **Implementation details obvious from code** — naming a variable, choosing a loop construct
- **Still deliberating** — the user hasn't committed to a direction yet

## Allowed Tools

`Bash` (mkdir, git commands only). No MCP servers, no vault access, no knowledge-gate CLI.

## Execution Steps

### Step 1: Synthesize Decision (no Bash)

From the session conversation, extract:

| Field | Description | Example |
|-------|-------------|---------|
| **title** | Short descriptive title (under 60 chars) | "PR body template is out of scope" |
| **slug** | Kebab-case identifier (3-5 words) from title | `pr-template-out-of-scope` |
| **decision** | Single imperative statement — what the project does or does not do | "Do not provide PR body templates or format guidelines" |
| **context** | 2-4 sentences: what situation prompted this decision | "The question arose whether..." |
| **rationale** | Why this choice, including rejected alternatives if any | "Each project has its own PR conventions..." |

**Language**: Write in the language primarily used during the session (same rule as memento-commit).

### Step 2: Write File and Commit (single Bash call)

```bash
test -d .knowledge || { echo "knowledge-distillery not initialized. Run /knowledge-distillery:init"; exit 1; }
mkdir -p .knowledge/decisions && cat > ".knowledge/decisions/YYYY-MM-DD-<slug>.md" << 'DECISION_EOF'
# Decision: <title>

**Decision**: <decision statement>

**Context**: <context>

**Rationale**: <rationale>
DECISION_EOF
git add ".knowledge/decisions/YYYY-MM-DD-<slug>.md" && git commit --only ".knowledge/decisions/YYYY-MM-DD-<slug>.md" -m "$(cat <<'COMMIT_EOF'
decision: <slug>
COMMIT_EOF
)"
```

Key details:
- `test -d .knowledge` fails fast if the distillery is not initialized, matching the error handling table.
- `mkdir -p` ensures the `decisions/` subdirectory exists (idempotent).
- `git add` + `git commit --only` ensures ONLY the decision file is committed — even if other files are already staged from the user's work in progress, they won't be swept into this commit.
- Commit message uses the `decision:` prefix for pipeline discoverability.

### Step 3: Report Result (no Bash)

```text
Decision recorded: <sha> decision: <slug>
```

## Error Handling

| Failure | Behavior |
|---------|----------|
| `.knowledge/` directory does not exist | Report that knowledge-distillery is not initialized. Suggest `/knowledge-distillery:init`. |
| File with same date+slug already exists | Append numeric suffix to slug (e.g., `pr-template-out-of-scope-2`). |
| `git commit` fails | Report the error. The file remains on disk for manual review. |

## Constraints

- MUST NOT stage or commit any files other than the decision file
- MUST NOT attach a memento note — the decision file itself is the session context
- MUST NOT create a PR — the commit joins the branch's eventual PR naturally
- MUST NOT access vault.db or knowledge-gate CLI
- MUST use the `decision:` commit message prefix
- MUST match the session language for decision content
