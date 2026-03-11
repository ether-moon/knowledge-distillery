# AGENTS.md

Knowledge Distillery — A system that delivers only verified knowledge to AI coding agents.
3-layer architecture with structural air gap.

- Design documents in `docs/`.

## Project Nature

This project builds the tool itself, not applies it.
This repository does NOT use Knowledge Distillery — it creates a tool/framework that other projects can adopt.

- MUST-NOT: Do not apply evidence collection workflows, hooks, skills, etc. directly to this repository
- MUST: All implementation artifacts must be built in a form deployable/applicable to other projects
- Delivery format: Claude Code Plugin (Skill + CLI + schema를 하나의 plugin으로 배포)

## Implementation Philosophy

The current implementation serves as a proof of concept. Do not over-engineer for edge cases or enforce rigid policies. Keep the design open to change — tight constraints and exhaustive safeguards make future iteration harder. Focus on experiencing real-world usability first and refining incrementally based on what you learn.
