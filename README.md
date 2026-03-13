# Knowledge Distillery

**A system that delivers only verified knowledge to AI coding agents.**

[English](./README.md) | [한국어](./docs/ko/README.md)

---

## The Problem

When AI coding agents receive too much unfiltered context, they don't get smarter — they get noisier. Unverified hypotheses are treated as facts, revoked decisions persist as instructions, and irrelevant information buries the critical rules. The result: hallucinations, silent mistakes, and costly rework.

## The Approach

Knowledge Distillery takes a different path: **collect broadly, distill rigorously, deliver minimally**.

A 3-layer architecture with a convention-based air gap separates raw information from verified knowledge:

1. **History Archive** — Raw data preserved without loss (Slack, Linear, PR reviews, AI session transcripts)
2. **Distillation Pipeline** — AI-driven refinement with automated quality gates, extracting only confirmed decisions and validated anti-patterns
3. **Knowledge Vault** — A curated SQLite store of distilled insights, accessible only through the `knowledge-gate` CLI

The agent never touches raw data. It only sees what has survived distillation.

## Key Design Decisions

- **Convention-based air gap**: Operational isolation between raw data and the agent's workflow — not perfect enforcement, but sufficient and pragmatic
- **AI-autonomous distillation**: LLMs extract and compress; humans provide strategic oversight, not item-by-item approval
- **Context Gate**: Domain-based selective filtering ensures agents receive only task-relevant knowledge, not the entire vault
- **Append-only, two types only**: The vault contains only **Facts** and **Anti-Patterns** — no confidence scores, no hedging

## Documentation

| Document | Description |
|---|---|
| [Design Philosophy](docs/design-philosophy.md) | Why this architecture exists — the rationale behind information control for AI agents |
| [Implementation Design](docs/design-implementation.md) | How it works — pipeline design, vault schema, runtime policies, deployment as a Claude Code Plugin |
| [CLI Reference](docs/cli.md) | `knowledge-gate` command specification — queries, domain management, pipeline operations |
| [Tool Evaluation](docs/tool-evaluation.md) | Adopted and rejected tools with rationale |
| [Skill Prompts](docs/skill-prompts/) | Pipeline skill specifications and dependency graph |

## Delivery Format

Distributed as a **Claude Code Plugin** — install with `claude plugin install` to get runtime skills, pipeline skills, and the `knowledge-gate` CLI in one package. The CLI itself is vendor-neutral (`sqlite3`-based), runnable from any coding agent.

## Status

Proof of concept. The design is intentionally kept open to change — tight constraints and exhaustive safeguards make future iteration harder. Focus is on real-world usability first.

## License

TBD
