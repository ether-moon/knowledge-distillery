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
| **alternatives** | *(optional)* Considered alternatives and why each was rejected | "Approach B was rejected because..." |
| **supersedes** | *(optional)* Previous decision file this one replaces | `2026-03-24-pr-template-out-of-scope` |

**Optional field guidelines:**

- **alternatives** — Include only when the session involved genuine deliberation between multiple approaches. Do NOT pad with self-evidently inferior options (the quality gate rejects padding alternatives as non-residual value per Q2). Each alternative should name the approach and state why it was rejected.
- **supersedes** — Include only when a previous decision file exists in `.knowledge/decisions/` and the new decision explicitly replaces or revises it. Use the full filename without extension (e.g., `2026-03-24-pr-template-out-of-scope`). Omit if no prior decision is being replaced.
- If neither optional field applies, omit them entirely — do not include empty sections.

**Language**: Write in the language primarily used during the session (same rule as memento-commit).

### Step 2: Write File and Commit (single Bash call)

**IMPORTANT — No command substitution:** Never use `$(...)` or backtick substitution in Bash calls. Claude Code's security layer blocks these patterns.

```bash
test -d .knowledge || { echo "knowledge-distillery not initialized. Run /knowledge-distillery:setup"; exit 1; }
mkdir -p .knowledge/decisions && cat > ".knowledge/decisions/YYYY-MM-DD-<slug>.md" << 'DECISION_EOF'
# Decision: <title>

**Decision**: <decision statement>

**Context**: <context>

**Rationale**: <rationale>

**Alternatives considered**:
- **<Option A>**: <why rejected>
- **<Option B>**: <why rejected>

**Supersedes**: `YYYY-MM-DD-<previous-slug>`
DECISION_EOF

git add ".knowledge/decisions/YYYY-MM-DD-<slug>.md" &&
git commit --only ".knowledge/decisions/YYYY-MM-DD-<slug>.md" -m "decision: <slug>"
```

**Optional sections** — when `alternatives` or `supersedes` apply (from Step 1), append them to the heredoc body before the `DECISION_EOF` marker:

```markdown
**Alternatives considered**:
- **<Option A>**: <why rejected>
- **<Option B>**: <why rejected>

**Supersedes**: `YYYY-MM-DD-<previous-slug>`
```

Include only the sections that apply. Most decisions will use only the core 4 fields.

Key details:
- `test -d .knowledge` fails fast if the distillery is not initialized, matching the error handling table.
- `mkdir -p` ensures the `decisions/` subdirectory exists (idempotent).
- `git add` + `git commit --only` ensures ONLY the decision file is committed — even if other files are already staged from the user's work in progress, they won't be swept into this commit.
- Commit message is a single-line `decision:` prefix — no heredoc or command substitution needed.
- Commit message uses the `decision:` prefix for pipeline discoverability.
- The `Alternatives considered` and `Supersedes` sections are **optional** — omit them entirely from the heredoc when they don't apply. The template above shows the maximal form; most decisions will use only the core 4 fields.

### Step 3: Report Result (no Bash)

```text
Decision recorded: <sha> decision: <slug>
```

## Error Handling

| Failure | Behavior |
|---------|----------|
| `.knowledge/` directory does not exist | Report that knowledge-distillery is not initialized. Suggest `/knowledge-distillery:setup`. |
| File with same date+slug already exists | Append numeric suffix to slug (e.g., `pr-template-out-of-scope-2`). |
| `git commit` fails | Report the error. The file remains on disk for manual review. |

## Constraints

- MUST NOT stage or commit any files other than the decision file
- MUST NOT attach a memento note — the decision file itself is the session context
- MUST NOT create a PR — the commit joins the branch's eventual PR naturally
- MUST NOT access vault.db or knowledge-gate CLI
- MUST use the `decision:` commit message prefix
- MUST match the session language for decision content
