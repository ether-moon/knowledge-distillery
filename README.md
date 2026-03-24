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

Executable skills in `plugins/knowledge-distillery/skills/` are the source of truth for pipeline behavior.

| Document | Description |
|---|---|
| [Design Philosophy](docs/design-philosophy.md) | Why this architecture exists — the rationale behind information control for AI agents |
| [Implementation Design](docs/design-implementation.md) | How it works — pipeline design, vault schema, runtime policies, deployment as a Claude Code Plugin |
| [Adoption Guide](docs/adoption-guide.md) | How to install the plugin, initialize a repository, and start using the vault |
| [Tool Evaluation](docs/tool-evaluation.md) | Adopted and rejected tools with rationale |

## CLI Quick Reference

The `knowledge-gate` CLI is the sole access path to the knowledge vault (`.knowledge/vault.db`). Set `KNOWLEDGE_VAULT_PATH` to override the default vault location.

**Agent Runtime** — query rules before modifying code:

| Command | Purpose |
|---|---|
| `query-paths <filepath>` | Resolve file path to domains → return matching rules |
| `query-domain <domain>` | Query rules by domain name |
| `search <keyword>` | FTS5 full-text keyword search |
| `get <id>` | Retrieve full entry details (including body) |
| `list` | Summary list of all active entries (exploration/keyword discovery) |

**Domain** — explore and manage the domain registry:

| Command | Purpose |
|---|---|
| `domain-info <domain>` | Domain details (description, patterns, entry count) |
| `domain-list [--status X]` | List domains (active\|deprecated\|all) |
| `domain-resolve-path <filepath>` | Reverse-lookup file path to domains |
| `domain-add`, `domain-merge`, `domain-split`, `domain-deprecate` | Registry lifecycle |
| `domain-paths-set`, `domain-paths-add`, `domain-paths-remove` | Path pattern management |
| `domain-report` | Domain health diagnosis |

**Loading** — add entries to the vault:

| Command | Purpose |
|---|---|
| `add --type <type> --title ... --claim ... --body ... --domain ... [flags]` | Add entry with validation |
| `_pipeline-insert` | Pipeline-only bulk INSERT (JSON stdin) |

**Utility** — setup and maintenance:

| Command | Purpose |
|---|---|
| `init-db [path]` | Create a new vault from bundled schema |
| `migrate` | Apply schema migrations |
| `doctor` | Verify repository adoption state |
| `curate` | Interactive curation queue resolution |

**Examples:**

```bash
# Query rules before editing a file
knowledge-gate query-paths src/api/auth/login.ts

# Check which domains a file belongs to
knowledge-gate domain-resolve-path src/services/payment.rb

# Search for rules by keyword
knowledge-gate search "callback"
```

Run `knowledge-gate help` for full usage details.

## Delivery Format

Distributed as a **Claude Code Plugin** — install with `claude plugin install` to get runtime skills, pipeline skills, bundled schema assets, and the `knowledge-gate` CLI in one package. The CLI itself is vendor-neutral (`sqlite3`-based), runnable from any coding agent.
The repository doubles as a marketplace. `.claude-plugin/marketplace.json` declares the marketplace; the plugin itself lives under `plugins/knowledge-distillery/` with its own `plugin.json`, `skills/`, `scripts/`, and `schema/`.

## Status

Proof of concept. The design is intentionally kept open to change — tight constraints and exhaustive safeguards make future iteration harder. Focus is on real-world usability first.

## License

TBD
