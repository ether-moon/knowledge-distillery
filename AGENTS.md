# AGENTS.md

Knowledge Distillery — A system that delivers only verified knowledge to AI coding agents.
3-layer architecture with convention-based air gap (operational isolation).

- Design documents in `docs/`.

## Project Nature

This project builds the Knowledge Distillery tool AND dogfoods it on itself.
The repository uses its own distillation pipeline to capture knowledge about its own development.

- MUST: All implementation artifacts must be built in a form deployable/applicable to other projects
- Delivery format: Claude Code Plugin (Skill + CLI + schema를 하나의 plugin으로 배포). 배포는 Claude-first, 런타임 CLI(`knowledge-gate`)는 벤더 중립(`sqlite3` 기반)
- Dogfooding: This repo has its own `.knowledge/vault.db` and GitHub Actions workflows. Plugin assets live under `plugins/knowledge-distillery/`

## Implementation Philosophy

The current implementation serves as a proof of concept. Do not over-engineer for edge cases or enforce rigid policies. Keep the design open to change — tight constraints and exhaustive safeguards make future iteration harder. Focus on experiencing real-world usability first and refining incrementally based on what you learn.

## Knowledge Vault
- Before modifying code, query related rules with `knowledge-gate query-paths <file-path>`
- Domain-level rule query: `knowledge-gate query-domain <domain-name>`
- Domain lookup: `knowledge-gate domain-info <domain-name>`, `domain-resolve-path <path>`
- MUST/MUST-NOT rules from related entries must be strictly followed
- For structural changes in areas without related rules, confirm with a human first
- Do not directly read files in the .knowledge/ directory

## Memento
- After every git commit, attach a memento session summary as a git note on `refs/notes/commits`
- The summary follows the 5-section format: Decisions Made, Problems Encountered, Constraints Identified, Open Questions, Context
- See `/knowledge-distillery:memento-commit` for the full workflow and format specification
- If the PostToolUse hook fires a reminder, follow it — generate the summary and attach the note
