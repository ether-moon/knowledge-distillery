# Decision: All commits must use memento-commit skill

**Decision**: Always use `/knowledge-distillery:memento-commit` instead of bare `git commit` for every commit in this project.

**Context**: A commit was made using bare `git commit` without attaching a memento session summary. This broke the evidence chain — the downstream mark-evidence pipeline reported 0 git sessions because no notes existed on the commit. The omission was discovered while investigating why the evidence bundle for PR #18 showed empty git sessions.

**Rationale**: Every commit must carry session context (decisions, problems, constraints) as a git note on `refs/notes/commits`. The memento-commit skill automates this by generating a structured 5-section summary and attaching it alongside the commit. Without it, the knowledge distillery pipeline loses visibility into the reasoning behind code changes, reducing the quality and completeness of extracted knowledge candidates.
