---
name: memento-commit
description: "Commits changes with an auto-generated message and attaches a structured session summary as a git note for the Knowledge Distillery evidence pipeline. Replaces the default commit workflow in knowledge-distillery-enabled projects. Use whenever the user says 'commit', 'save changes', 'git commit', or invokes any commit action — this ensures every commit carries session context for downstream knowledge extraction."
---

# memento-commit

Commit workflow that creates a normal git commit AND attaches a memento session summary as a git note on `refs/notes/commits`. The downstream pipeline (mark-evidence, collect-evidence, extract-candidates) reads these notes as evidence for knowledge distillation.

Replaces the default commit workflow when the knowledge-distillery plugin is installed.

## When to Use

- Any time the user asks to commit, save changes, or invokes a commit action
- In repositories with the knowledge-distillery plugin installed

## Allowed Tools

`Bash` (git commands only). No file writes, no MCP servers, no vault access.

## Execution Steps

### Step 1: Gather Context (Bash call 1 of 2)

```bash
git status --porcelain; echo "---LOG---"; git log --oneline -10; echo "---DIFF---"; git diff HEAD --stat; echo "---BRANCH---"; git branch --show-current
```

Parse into 5 sections:
1. **Status**: File changes — empty means nothing to commit
2. **Log**: Recent commit patterns and style
3. **Diff stat**: Summary of what changed
4. **Branch**: Current branch name for ticket extraction
5. **Staging plan**: From the status output, determine which files to stage:
   - Modified/deleted tracked files (lines starting with ` M`, ` D`, `M `, `D `, etc.): always include
   - New untracked files (lines starting with `??`): include UNLESS they match sensitive patterns (`.env*`, `credentials*`, `*.key`, `*.pem`, `*.secret`, `settings.local.json`)
   - If excluding any untracked files, note them for the user

**Exit if:** Status is empty. Report "Nothing to commit." and stop.

### Step 2: Generate Commit Message (no Bash)

- **Language**: Match the project's language from existing commits and docs. Default to English if unclear.
- **Style**: Follow patterns from the log output — consistency with existing commits matters.
- **Ticket numbers**: Extract from branch name if present (e.g., `feature/PROJ-123-add-auth` -> `PROJ-123`).
- **First line**: Under 72 characters, imperative mood ("Add", "Fix", "Refactor").
- **Body**: Optional, separated by blank line, for larger changes.

### Step 3: Generate Memento Summary (no Bash)

Reflect on the **current session** — what was discussed, decided, and encountered — NOT just the diff. The diff is the "what changed"; the memento is the "why and how it was decided."

Generate a summary following the format and rules in [Memento Summary Format](#memento-summary-format) below.

For trivial changes (typo fixes, formatting, single-line changes with no technical decisions): produce a minimal summary with "None" in all sections except Context.

### Step 4: Stage, Commit, and Attach Note (Bash call 2 of 2)

Combine staging, commit, and note attachment in a single Bash call. This ensures the PostToolUse hook sees the note already attached when it fires.

**Staging rules — never use `git add -A` or `git add .`:**
- Stage specific files by name from the staging plan in Step 1
- If all changes are to tracked files only (no untracked), `git add -u` is acceptable as shorthand
- If untracked files should be committed, add them by name alongside `git add -u`
- NEVER stage files matching: `.env*`, `credentials*`, `*.key`, `*.pem`, `*.secret`, `settings.local.json`

```bash
git add <file1> <file2> ... && git commit -m "$(cat <<'COMMIT_EOF'
<generated message>
COMMIT_EOF
)" && SHA=$(git log --format=%h -1) && cat <<'MEMENTO_EOF' | git notes --ref=refs/notes/commits add --force --file=- $SHA
<generated summary>
MEMENTO_EOF
echo "$SHA $(git log --format=%s -1)"
```

After the commit+note command succeeds, push the notes ref so that the downstream pipeline (mark-evidence in CI) can access them:

```bash
PUSH_OUT=$(git push origin refs/notes/commits 2>&1) && echo "Notes push: synced to origin" || echo "FAILED — $PUSH_OUT"
```

- `git add <files>`: Stage only the files identified in the staging plan. Use `git add -u` when only tracked files changed.
- `--force`: Ensures idempotency if rerun on the same SHA.
- `--file=-`: Avoids shell quoting issues with multi-line markdown.
- `refs/notes/commits`: Matches the ref that mark-evidence and collect-evidence expect.
- `git push origin refs/notes/commits`: Pushes notes to remote. Without this, notes exist only locally and the CI pipeline (mark-evidence) cannot detect them. This is a separate Bash call because a push failure should not affect the commit result.

If `git commit` fails (hooks, conflicts, empty), the chain stops — no note is attempted. If `git notes add` fails, the commit is preserved — report the note failure separately. If `git push` of notes fails, the commit and local note are preserved — report the push failure separately.

### Step 5: Report Result (no Bash)

```
Committed: <sha> <first line of message>
Memento:   attached to refs/notes/commits
Notes push: synced to origin
```

If note attachment failed:
```
Committed: <sha> <first line of message>
Memento:   FAILED — <reason>. Commit succeeded without session note.
```

If notes push failed:
```
Committed: <sha> <first line of message>
Memento:   attached to refs/notes/commits
Notes push: FAILED — <reason>. Run `git push origin refs/notes/commits` manually before merging.
```

---

## Memento Summary Format

The summary MUST follow this exact 5-section markdown structure. All five sections are required. Use "None" as a single item for any empty section.

```markdown
## Decisions Made
- [Decision]: [Rationale]

## Problems Encountered
- [Problem]: [How it was resolved or current status]

## Constraints Identified
- [Constraint]: [Why it matters]

## Open Questions
- [Question]: [Context]

## Context
[2-4 sentence paragraph: what was being done, key files, outcome]
```

### Extraction Rules

**Decisions Made** — Confirmed choices only:
- Explicit selections ("Use X instead of Y"), implicit path choices, architecture/design/pattern selections
- Include rationale. MUST-NOT decisions must name the chosen alternative.
- Do NOT include exploration steps, abandoned experiments, or intermediate reasoning.

**Problems Encountered** — Issues actively worked on:
- Errors debugged, unexpected behaviors investigated, failed approaches before a solution
- Include resolution status or "Unresolved" if still open.

**Constraints Identified** — Limitations and boundaries discovered:
- API/framework restrictions, performance boundaries, compatibility requirements, user-specified restrictions
- Include why it matters for future work.

**Open Questions** — Unresolved items:
- Deferred decisions, unresolved uncertainties, TODO items, areas flagged for review

**Context** — 2-4 sentence paragraph:
- Session goal, key files/modules involved, outcome (completed/partial/blocked)

### Formatting Rules

- Each item: single bullet, 1-2 sentences max
- Aim for 3-7 items per section for a typical session; fewer for short sessions
- Write in the language primarily used during the session
- Do NOT include raw code blocks or sensitive information (API keys, credentials, PII)
- Focus on decisions, constraints, problems — not step-by-step implementation details

For the complete extraction specification with examples, see `/knowledge-distillery:memento-summary`.

---

## Error Handling

| Failure | Behavior |
|---------|----------|
| Nothing to commit (clean working tree) | Report "Nothing to commit." Stop. |
| `git commit` fails (hooks, conflicts, empty) | Report error. Do not proceed to note attachment. |
| `git notes add` fails | Report error. Confirm the commit succeeded. |
| `git push origin refs/notes/commits` fails | Report error. Confirm commit and note succeeded. Instruct user to push notes manually. |
| Session context too minimal to summarize | Produce minimal summary (all "None" + one-sentence Context). |

## Constraints

- MUST NOT depend on the git-memento binary — uses `git notes` directly
- MUST use `refs/notes/commits` as the notes ref (pipeline compatibility)
- MUST produce all 5 sections in the memento summary (even if all are "None")
- MUST NOT block on note failure — the commit is the primary deliverable
- MUST match the language and style of recent commits for the commit message
