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
