# Tool Evaluation Results

> **Evaluation Criteria (Alignment with Design Philosophy/Implementation)**
>
> 1. **Automatic Quality Gate Compatibility**: Can the tool's output meet or be transformed to satisfy the refinement candidate required schema ([Design Implementation §3.3.1](./design-implementation.md#331-refinement-candidate-required-schema))?
> 2. **Air Gap Principle Compliance**: Does it maintain a structure where agents cannot directly access raw data?
> 3. **Batch Pipeline Suitability**: Is it compatible with periodic batch refinement rather than real-time processing?
> 4. **Vendor Neutrality**: Can it be applied universally without being tied to a specific coding agent (Claude Code, Codex, Gemini, etc.)?
> 5. **Benefit vs. Complexity**: Does the adoption cost (infrastructure, learning curve, maintenance) not exceed the benefit?
> 6. **Rejection Code (R1/R3/R5/R6) Support**: Does the tool support or at least not interfere with the automatic quality gate's validation criteria?

## A.1 Adopted

| Tool | Application Layer | Role | Status |
|---|---|---|---|
| [obra/claude-memory-extractor](https://github.com/obra/claude-memory-extractor) | Layer 2 (Prompt Design) | Not directly integrated. Multi-dimensional extraction prompt structure referenced for system prompt design | ⚠️ No commits since 2025-09 |
| [obra/cc-plugin-decision-log](https://github.com/obra/cc-plugin-decision-log) | Layer 2 (Template Design) | Decision/Approach structure borrowed for Evidence Bundle and knowledge vault templates | Experimental (obra personal project) |
| [Agent Trace](https://github.com/cursor/agent-trace) (Schema Borrowing) | Layer 2 (Evidence Tracking) | Referenced provenance tracking schema for `evidence` field. Line-level code attribution standard | RFC v0.1.0 (Cursor-led) |
| [SKILL.md](https://agentskills.io) | Layer 3 (Distribution Format — Implementation Deployment) | Standard format for distributing/reusing knowledge vault outputs as agent skill files. Direction adopted; implementation is beyond this design scope | Industry standardization in progress |
| [git-memento](https://github.com/mandel-macaque/memento) | Layer 1 (Session Capture) | Attaches AI coding session transcripts to commits as git notes. Core input for Evidence Bundles | Active (mandel-macaque led) |
| [SQLite](https://sqlite.org) | Layer 3 (Storage + Context Gate) | Sole storage for the knowledge vault + query engine for knowledge-gate CLI | The most widely deployed DB in the world |

### claude-memory-extractor

The multi-dimensional extraction structure (Five Whys, psychological motivations, prevention strategies, uncertainty marking) is referenced for refinement prompt design. In particular, the constraint "do not force lessons when confidence is low" aligns with this design's principles (confidence is used only as an internal tool within the refinement pipeline and is not recorded in the knowledge vault). Since it is a Node.js/TypeScript-based tool exclusively for Claude CLI local logs, prompt patterns are borrowed rather than directly integrated. **There have been no commits since 2025-09, so a fork or alternative may be needed in the long term.**

### cc-plugin-decision-log (New)

A Claude Code plugin that structures and logs decisions during coding sessions. The core structures are `Decision` (topic → options → chosen → rationale) and `Approach` (approach → outcome[failed/succeeded] → details).

**Usage:**
- `Decision.options` + `Decision.chosen` structure → Explicitly captures "alternatives considered vs. approach chosen" in Evidence Bundles
- `Approach.outcome: failed` → Directly corresponds to the "failed approaches" section of Anti-Pattern candidates
- "Search before deciding" pattern → Forces the refinement prompt to query the existing knowledge vault first

Since this is a pattern and data structure borrowing rather than direct integration, it can be utilized regardless of the plugin's own maturity level.

### Agent Trace (New — Schema Borrowing)

An AI code attribution standard (RFC v0.1.0) led by Cursor with participation from Cognition (Devin), Vercel, Cloudflare, Google Jules, OpenCode, and others. It tracks which AI model and conversation generated a given piece of code at the file/line level.

**Usage:**
- Provenance tracking structure for the `evidence` field is referenced from the Agent Trace schema
- `conversation.url` → Slack/Linear links, `related` → PR/issue connections
- Content hash-based code movement tracking may be useful for validity verification ([Design Implementation §5.2](./design-implementation.md#52-human-curation-ux))

Since it is currently at the RFC stage, it is used only as a schema design reference, with direct integration to be reconsidered after official release.

### git-memento (New — Layer 1 Session Capture Infrastructure)

A CLI tool that preserves the context of "why was this changed" by attaching AI coding session transcripts to commits as `git notes`. Adopted as core infrastructure for Knowledge Distillery's Layer 1 (History Archive).

**Rationale for Adoption:**

| Evaluation Item | Assessment |
|---|---|
| Evidence Bundle Contribution | Structured summaries via custom Summary Skill are directly included as AI session context in Evidence Bundles |
| Air Gap Compatibility | `git notes` are not fetched without explicit refspec, so the air gap is naturally maintained |
| Squash Merge Survival | `notes-carry` command transfers individual commit notes to merge commits. GitHub Action automation supported |
| CI Gate | `audit --strict` verifies commits without attached notes. Can be used as a PR gate |

The role of git-memento in the pipeline is described in Design Implementation §2.5 and §3.2 (Evidence Bundle).

### SQLite (New — Knowledge Vault Storage + Context Gate)

Adopted as the **sole storage** for the knowledge vault and the query engine for the context gate (knowledge-gate CLI). Eliminates dual-format management of Markdown + YAML frontmatter by consolidating into a single SQLite file.

**Rationale for Adoption:**

| Evaluation Item | Assessment |
|---|---|
| Pre-installation Rate | Bundled by default on macOS (`/usr/bin/sqlite3`) and most Linux distributions. Zero dependencies |
| Context Gate Enforcement | Binary format means LLM `Read` is meaningless → accessible only through knowledge-gate CLI. Structural enforcement of the context gate ([Design Implementation §4.1](./design-implementation.md#41-storage-location-and-format) reference) |
| Vendor Neutrality | All coding agents (Claude Code, Codex, Gemini, etc.) can execute `sqlite3` via shell commands |
| Query Capability | Standard SQL + FTS5 full-text search + index-based lookups. The query language LLMs know best |
| Schema Enforcement | `CHECK`, `NOT NULL`, `FOREIGN KEY` guarantee refinement pipeline output integrity at the DB level |
| Deployment | Commit a single `.db` file to the master branch. Use the latest knowledge vault with just `git pull` |

**Position on Git Diff Limitations:** Since the LLM (refinement pipeline) exclusively handles knowledge vault document changes, humans do not need to view diffs. If change history is needed, query by `created_at` using `sqlite3` or track via in-DB status (`active`/`archived`) plus `archive_reason`.

**Alternative Comparison:** See §A.5 Knowledge Vault Storage + Context Gate Tool Comparison.

### SKILL.md (New)

A reusable capability package standard that AI coding agents can load on demand. Supported by 27+ agents including Claude Code, Cursor, and Gemini CLI. Agents load only ~100 tokens of description at startup and lazy-load full instructions when a task matches.

**Usage:**
- YAML frontmatter (id, name, description) + Markdown body is compatible with existing knowledge vault templates
- Suitable for standardizing the "consumption format" of the knowledge vault. Implementation to be considered beyond this design scope

**Limitation — Does Not Replace the Context Gate:**
If knowledge vault entries are exported as SKILL.md files and placed in the filesystem, agents can directly read all skill files, defeating the context gate's selective filtering. The knowledge vault accumulates rules across diverse domains spanning the entire project, and their total volume is never entirely needed for any single task. File-based delivery loads rules irrelevant to the current task into context, causing performance degradation from increased information without relevance control ([Design Philosophy §1](./design-philosophy.md#1-a-flood-of-information-becomes-noise-not-knowledge), [§4.4](./design-philosophy.md#44-context-gate--selective-exposure)). Therefore, SKILL.md serves as a **supplementary distribution format** for environments without the knowledge-gate CLI or for compatibility with projects that have not adopted Knowledge Distillery, and does not replace selective delivery through the context gate.

---

## A.2 Not Adopted

| Tool | Reason for Non-Adoption | Status (2026-03) |
|---|---|---|
| [Fabric](https://github.com/danielmiessler/fabric) | In the Claude Code native path, Skills serve as extraction prompts and the LLM is itself, so a separate prompt runner like Fabric provides no value. Only adds unnecessary complexity: Go binary dependency, separate API key setup, output parsing glue code, Rake orchestration, etc. | ✅ Active (39k+ stars). Non-adoption is due to architectural fit, not the tool itself |
| [Log4brains](https://github.com/thomvaill/log4brains) | With the knowledge vault transitioning to a single SQLite file, the application point for an ADR Markdown exploration tool has disappeared. See A.6 for curation UI role | ⚠️ Development stalled since 2024-12 |
| Zep / Graphiti | The knowledge vault is intentionally a simple single SQLite file. Introducing a graph DB is excessive complexity | MCP support added. Connection convenience improved, but fundamental complexity remains |
| Hindsight | Philosophical conflict with the "passing the refinement pipeline = qualification for vault entry" principle (confidence field is not kept in the vault). Hindsight's Temporal+Semantic memory maintains probabilistic weights, which differs from this design's "pass/fail binary" model | Active development as vectorize-io/hindsight (Temporal+Semantic+Entity memory). Philosophical differences persist |
| Mem0 | Automated memory merging conflicts with the "only items meeting automatic quality gate criteria are promoted" principle. Automatic merging that bypasses quality gate criteria (R1/R3/R5/R6) permits uncertain information to enter the vault | v1.0.0 released, MCP server + platform UI added. Pivoting toward managed service orientation |
| Obsidian / Logseq | The agent knowledge vault must be in-repo markdown, making a separate vault an unnecessary indirection layer | No change |
| Microsoft GraphRAG | Potential for refinement quality improvement, but Python-only + high LLM costs + complex infrastructure makes it unsuitable for this design's simplicity principle | v3.0.5 (2026-03), 31k+ stars. New features including DRIFT Search, LazyGraphRAG added |

### Microsoft GraphRAG (New — Not Adopted)

Builds hierarchical knowledge graphs using Leiden algorithm-based community clustering + LLM summarization. Supports three query modes: Local/Global/DRIFT, with increasing use cases in software engineering such as code dependency analysis.

**Reasons for Non-Adoption:**
- **Infrastructure Complexity:** Python 3.10+ only, Parquet/Azure Blob Storage, pandas/networkx dependencies. Heterogeneous with Claude Code native pipeline
- **LLM Cost:** High cost due to multi-pass processing (extraction + summarization) of all chunks during indexing
- **Output Format:** Parquet/CSV table output → requires Markdown+YAML conversion layer
- **Batch Compatibility:** Periodic indexing itself is compatible with batch pipelines, but total adoption cost exceeds the benefit

A lightweight alternative is [nano-graphrag](https://github.com/gusye1234/nano-graphrag), a simplified implementation of the core Leiden clustering + summarization logic. → Recorded as a candidate for further review in A.3.

### Letta (formerly MemGPT) — Non-Adoption Maintained, Subject to Reconsideration

Rebranded as Letta in 2026 and introduced **Context Repositories** (Git-based Memory). Git-based memory version control where every memory change gets a commit message. This has become directionally similar to this design's "auditable batch refinement."

**Reasons for Maintaining Non-Adoption:**
- Still fundamentally an agent runtime-level solution, operating at a different layer from build-time batch refinement
- Context Repositories is interesting but currently an internal feature of the Letta platform, with limited independent usage

**Conditions for Reconsideration:** Reconsider when Context Repositories is separated into an independent library, or when Git-backed memory management can be utilized externally.

---

## A.3 Candidates for Further Review

| Item | Review Points | Current Status |
|---|---|---|
| nano-graphrag | Lightweight alternative to GraphRAG. Simplified implementation of Leiden clustering + summarization | Follow-up comparative review planned |
| sqlite-graph | SQLite graph extension. Graph model solution candidate for the file_scopes path explosion problem | Alpha v0.1.0 — core features immature, reconsider after stabilization |
| Client-Side RAG (GitNexus, etc.) | Local RAG maintaining the air gap principle. Potential to improve knowledge vault search quality | Follow-up comparative review planned |
| claude-mem | Plugin that distills Claude Code observations into CLAUDE.md. Approach is similar to this design's refinement pipeline | Follow-up comparative review planned |
| Beads | Persistent memory across coding agent sessions. Cross-session state persistence patterns worth referencing | Follow-up comparative review planned |
| cursor-memory-bank | Provides knowledge to agents via curated Markdown files. Same family as this design's knowledge vault pattern | Follow-up comparative review planned |
| ICM (rtk-ai/icm) | `init` bootstrapping and CLI layering have reference value, but the agent-direct-memory-write model conflicts with the air gap principle | Conceptual patterns only referenced (direct borrowing not possible due to license restrictions) |

### nano-graphrag (New)

[gusye1234/nano-graphrag](https://github.com/gusye1234/nano-graphrag). A lightweight implementation of Microsoft GraphRAG's core logic (community detection + summarization). Easy output format customization makes Markdown+YAML conversion possible. Suitable for validating GraphRAG's refinement quality improvement potential at low adoption cost.

### Client-Side RAG (New — Detailed Review)

[GitNexus](https://github.com/abhigyanpatwari/GitNexus) is a "Zero-Server Code Intelligence Engine" that runs in the browser/locally, using Transformers.js local embeddings + IndexedDB vector store. It can search the knowledge vault without external API calls, making it compatible with the air gap principle.

**Review Points:**
- Bundling a local embedding model (all-MiniLM-L6-v2, etc.) enables indexing/search without network calls
- CLI-based alternatives exist, such as gptme-rag and DocuPulse
- Semantic search over Markdown files could improve validation quality as the knowledge vault grows
- License verification needed (some tools use non-commercial licenses)

### claude-mem (New)

[thedotmack/claude-mem](https://github.com/thedotmack/claude-mem). A plugin that compresses and distills observations from Claude Code sessions into `CLAUDE.md`. Its automatic compression mechanism using the Agent SDK is similar in approach to this design's refinement pipeline of "distilling conclusions from decided outcomes." However, it operates at a single-session scope, applying at a different layer from the batch refinement + automatic quality gate structure. Compression strategies can be referenced when designing refinement prompts.

### sqlite-graph (New)

[agentflare-ai/sqlite-graph](https://github.com/agentflare-ai/sqlite-graph). A C99 extension that adds graph DB capabilities (nodes/edges + Cypher queries) to SQLite. Pure C with no external dependencies; creates a graph layer inside an existing SQLite DB via `CREATE VIRTUAL TABLE graph USING graph()`.

**Review Context:** The initial model for the knowledge vault schema, `file_scopes` (Entry-Path direct mapping), had a structural limitation where paths would explode for cross-cutting concern rules, so it was replaced by the current domain model (`domain_registry` + `domain_paths` + `entry_domains`) ([Design Implementation §4.5](./design-implementation.md#45-domain-registry-lifecycle) reference). Introducing an intermediate layer of Entry → Concept → Path via a graph model resolves this issue, and sqlite-graph is a candidate that can provide graph queries while maintaining the SQLite single-file deployment model.

**Current Status (v0.1.0-alpha.0):**

| Item | Status |
|---|---|
| Cypher CREATE/MATCH/WHERE/RETURN | Supported |
| Compound WHERE (AND/OR/NOT) | **Not supported** (planned for v0.2.0) |
| Variable-length paths (`[r*1..3]`) | **Not supported** (planned for v0.2.0) |
| Aggregation (COUNT, SUM, etc.) | **Not supported** |
| Property projection (`n.property`) | **Not supported** |
| macOS | Buildable, limited testing |
| Test scale | Verified up to 1,000 nodes only |

**Reasons for Current Non-Adoption:**
- Alpha stage with explicit "not recommended for production" disclaimer
- Lack of compound WHERE and variable-length path support is critical for 2-hop queries (Path → Concept → Entry)
- Limited macOS support (development environment compatibility risk)
- The same intermediate layer model can be implemented with pure SQL JOIN tables (`concepts`, `entry_concepts`, `concept_scopes`), making the core value achievable without graph extensions

**Conditions for Reconsideration:** Reconsider after v0.2.0+ stabilization when compound WHERE, variable-length paths, and official macOS support are confirmed, and when graph traversal of 3+ hops becomes necessary beyond what pure SQL JOINs can handle.

### cursor-memory-bank (New)

[vanzan01/cursor-memory-bank](https://github.com/vanzan01/cursor-memory-bank). A framework that provides persistent context to agents through a curated set of Markdown files (VAN, PLAN, CREATIVE, IMPLEMENT). The "agents reference only the curated vault" pattern belongs to the same family as this design's knowledge vault. However, it assumes manual curation and does not consider integration with an automatic refinement pipeline.

### ICM (rtk-ai/icm) — `init` / CLI Structure Conceptual Reference

[rtk-ai/icm](https://github.com/rtk-ai/icm) is an agent memory system that positions itself as "single binary, zero dependencies, MCP native." As a complete product, it is closer to a runtime memory system where agents directly save, modify, and delete memories, making its core philosophy different from this design's focus on knowledge air gap and batch refinement. However, the **initial setup UX** and **CLI command layer separation** visible in public documentation have reference value for our design, which aims for a vendor-neutral runtime CLI.

**Structure Identified from Public Documentation:**
- A single `icm init` command auto-detects and modifies MCP configuration files for multiple clients including Claude Code, Cursor, Codex CLI, and OpenCode
- `icm init --mode skill` separates MCP registration from slash command / rule installation
- `icm serve` serves as the MCP server entry point, with a separate CLI layer providing `store`, `recall`, `forget`, `consolidate`, `stats`, `config`, `memoir ...`, etc.
- Operational inspection commands like `health`/`stats` and `config` exposure are placed in a separate management layer

This structure can be summarized as a command system that separates "installation/bootstrapping," "agent runtime queries," "operational management," and "server entry point." While this separation itself is valid for Knowledge Distillery, the responsibilities of each layer must be redefined to align with the air gap principle.

**What to Borrow (Concepts Only):**
- **One-Shot Multi-Client Bootstrap:** Having a bootstrap entry point that installs the Claude plugin and then runs a single adoption step such as `/knowledge-distillery:init` has high adoption value. Since our design aims for "Claude-first (distribution) / vendor-neutral (runtime)" per [design-implementation.md §7.5](./design-implementation.md#75-context-gate-knowledge-gate-skill--cli), the appropriate configuration is to keep the runtime data path on the common `knowledge-gate` while adapting only the installation UX per agent.
- **Installation Mode Separation:** The pattern of separating plugin/runtime installation from project adoption setup is directly useful. In our case, plugin installation provides `skills/`, `scripts/`, and `schema/`, while `/knowledge-distillery:init` performs repository-local adoption work such as vault creation and workflow setup.
- **CLI Layer Clarification:** Currently, `knowledge-gate` has query/domain management/pipeline post-processing coexisting in a single document. In the long term, it would be better for usability and document navigability to more clearly separate `agent runtime` (`query-paths`, `query-domain`, `search`, `get`), `pipeline/admin` (`_pipeline-insert`, `domain-*`, `migrate`), and `diagnostics` (`doctor`, `domain-report`, future `vault-health`, `vault-stats`).
- **Diagnostic Command Enhancement:** In line with the human's role as strategic overseer ([Design Philosophy §6.3](./design-philosophy.md#63-the-role-of-humans-strategic-overseers-not-approvers-of-individual-items)), adding `vault-health` type commands in the future is reasonable. Candidate items include domain overcrowding/underpopulation, orphan domains, archived ratios, potential duplicates, and the current `knowledge:pending` backlog.
- **Configuration Visibility:** While CLI specs are already clear, `config`/`doctor` type commands for quickly inspecting the active vault path and current settings are helpful from an operational convenience perspective. Having a layer that diagnoses installation issues like "why can't this agent find knowledge-gate" improves plugin deployment quality.

**What Not to Borrow:**
- Write paths like `store` / `update` / `forget` where agents directly modify the knowledge store at runtime
- Automatic extraction structure that creates and injects memory directly from session hooks (PostToolUse, SessionStart, PreCompact)
- Using decay/consolidation as lifecycle management rules for authoritative knowledge itself
- A structure that centers the memory system as the product's core while subordinating the batch refinement pipeline

**Our Adoption Direction:**
- `knowledge-gate` continues to be maintained as the **sole runtime access path** ([design-implementation.md §7.5](./design-implementation.md#75-context-gate-knowledge-gate-skill--cli)).
- Only installation UX and operational UX are borrowed; the knowledge creation/promotion path continues to follow [Design Implementation §3.1](./design-implementation.md#31-trigger-2-stage-pipeline)'s 2-stage refinement pipeline.
- `knowledge-gate doctor` is now a valid auxiliary interface for adoption validation. Future diagnostics may add `knowledge-gate vault-health` and related read-only status commands, but these must remain **auxiliary interfaces that do not grant vault write permissions**.

**License Notice:**
The [ICM License](https://github.com/rtk-ai/icm/blob/main/LICENSE) is source-available and explicitly states `NO COPYING OR REDISTRIBUTION` and `NO DERIVATIVE WORKS`. Therefore, this project does not reuse ICM's code, wording, or configuration templates, and only references publicly visible product ideas and UX patterns at a conceptual level.
Reference documents: [README](https://github.com/rtk-ai/icm/blob/main/README.md), [LICENSE](https://github.com/rtk-ai/icm/blob/main/LICENSE)

---

## A.4 Research Materials

Papers and guides referenced as theoretical foundations for the design.

| Material | Core Concept | Where Applied |
|---|---|---|
| [Lost in the Middle](https://arxiv.org/abs/2307.03172) (2023) | Performance degradation for information buried in the middle of long contexts | Position bias mitigation: TL;DR placed at top + restated at bottom ([Design Implementation §4.3](./design-implementation.md#43-output-format)) |
| [Context Rot](https://research.trychroma.com/context-rot) | Performance instability as input length increases | Theoretical basis for the "conservative about additions" principle |
| [Distraction in Long Context](https://arxiv.org/abs/2404.08865) (2024) | Attention distraction effects from irrelevant information | Raison d'etre for the knowledge air gap — blocking low-value information from agents |
| [Do Context Files Help Coding Agents?](https://arxiv.org/abs/2602.11988) (2025, ETH Zurich) | Empirical results showing context files actually decreased agent success rates and increased reasoning costs by 20%+. Phenomenon of failing to reach core code by following unnecessary requirements | Why selective exposure through the context gate is essential — evidence that file-based delivery (SKILL.md, etc.) cannot replace the context gate ([Design Philosophy §4.4](./design-philosophy.md#44-context-gate--selective-exposure)) |
| Anthropic Context Engineering Principles | Minimal set of high-value tokens under attention budget | Foundation of the overall operational philosophy |

---

**Common Evaluation Criteria:** Alignment with the principle of "only items verified by automatic quality gates (R1/R3/R5/R6) are promoted, humans provide strategic oversight, and additions are conservative." Tools that do not align with this principle or whose benefit is insufficient relative to complexity are not adopted.

---

## A.5 Knowledge Vault Storage + Context Gate Tool Comparison

Candidates reviewed to determine the knowledge vault's storage format and agent access mechanism (context gate).

### Review Context

The context gate is a filter that determines "what to expose and what to exclude" at the start of each agent session. Core requirements:

1. **Vendor Neutrality**: Works across all coding agents — Claude Code, Codex, Gemini, etc.
2. **Context Gate Enforcement**: Technically prevents agents from directly reading the knowledge vault (only selective access through CLI is permitted)
3. **File Path-Based Matching**: Automatically retrieves relevant rules based on file paths modified in PRs
4. **Full-Text Search**: Explores relevant rules by keyword
5. **Minimal Dependencies**: Usable without additional installation

### Candidate Comparison

| | **SQLite** (Adopted) | **JSON + jq** | **DuckDB** | **`.claude/rules/`** |
|---|---|---|---|---|
| **Pre-installed** | Bundled on macOS/Linux | jq requires separate installation | Requires separate installation (~20-30MB) | Claude Code only |
| **Context Gate Enforcement** | Binary → LLM Read meaningless | Text → LLM can directly Read | Binary → Read meaningless | N/A (always loaded) |
| **Query Language** | Standard SQL | jq expressions | SQL (PostgreSQL compatible) | glob patterns (runtime automatic) |
| **Indexing** | B-tree + FTS5 | None (full scan) | Column indexes | Runtime glob matching |
| **Schema Enforcement** | CHECK, NOT NULL, FK | None (schema-free) | CHECK, NOT NULL | YAML frontmatter convention |
| **Vendor Neutrality** | All agents (shell commands) | All agents (shell commands) | All agents (shell commands) | **Claude Code only** |
| **Git Diff** | Not possible (binary) | Possible (text) | Not possible (binary) | Possible (Markdown) |
| **LLM Query Accuracy** | High (SQL is LLM's most proficient) | Medium (jq syntax errors possible) | High (SQL) | N/A (automatic) |

### Detailed Non-Adoption Reasons

**JSON + jq:**
- Git diff capability was the main advantage, but since the LLM exclusively handles knowledge vault changes, the need for diff is eliminated
- As a text file, an agent can load the entire contents into context with a single `Read`, defeating the context gate — context gate enforcement is impossible
- Full scan queries without indexes. No performance issues at knowledge vault scale, but no reason not to use indexes when available
- LLMs are more likely to write incorrect jq expressions than SQL

**DuckDB:**
- The ability to directly SQL-query JSON files without import is attractive
- However, it is not pre-installed, introducing an additional dependency (~20-30MB)
- Since SQLite is already pre-installed and supports identical SQL queries, DuckDB's additional benefits are insufficient

**`.claude/rules/` path-scoping:**
- A built-in feature where the Claude Code runtime deterministically matches `paths` YAML frontmatter glob patterns to automatically inject relevant rules
- Technically excellent but **Claude Code only** — does not work with other coding agents (Codex, Gemini, OpenCode, etc.)
- Conflicts with vendor neutrality requirements, so not adopted as the primary mechanism
- Can be used supplementarily alongside knowledge-gate CLI in Claude Code environments

### Final Decision

**SQLite adopted as the sole storage for the knowledge vault.** The knowledge-gate CLI (shell script) is the only interface that queries SQLite, and agent skill files provide the query protocol. Binary format structurally enforces the context gate, and pre-installation rates combined with SQL query LLM-friendliness are the decisive advantages.

---

## A.6 Knowledge Vault Curation Client Reference

Human curation of the knowledge vault (vault.db) ([Design Implementation §5.2](./design-implementation.md#52-human-curation-ux)) is currently only possible via raw SQL SELECT. Using SQLite-specific clients can improve curation UX while maintaining SSoT in vault.db. Below is a reference tool list.

### Review Context

Core requirements for curation tasks:
- State transitions of the `entries` table (active → archived)
- Reviewing and resolving pending conflict pairs in `curation_queue`
- Managing `domain_registry` / `domain_paths`
- Schema exploration including FTS5 virtual tables
- Compatibility with vault.db structure that has CHECK constraints, FKs, and triggers

### Tool Comparison

| | **sqlit** | **SQLiteStudio** | **DB Browser** | **Base** | **datasette** | **TablePlus** | **litecli** |
|---|---|---|---|---|---|---|---|
| **Type** | TUI (terminal) | GUI (desktop) | GUI (desktop) | GUI (desktop) | Web UI | GUI (desktop) | CLI (terminal) |
| **Platform** | Cross-platform | Cross-platform | Cross-platform | **macOS only** | Cross-platform | Cross-platform | Cross-platform |
| **License** | OSS | GPL | OSS | Paid (£29.99) | Apache 2.0 | Premium ($99+) | BSD-3 |
| **FTS5** | Via SQL queries | Full support | Full support | Native/visual | **Automatic search UI** | Visual support | Via SQL queries |
| **Schema Exploration** | Tree view (triggers/virtual tables) | **ERD included (4.0)** | Basic | **Visual inspector** | Metadata browsing | Structure view | Autocomplete |
| **Inline Editing** | SQL generation approach | Direct editing | Direct editing | Direct editing | Plugin (`write-ui`) | **Change staging** | N/A |
| **Team Sharing** | No | No | No | No | **Yes (web-based)** | No | No |
| **Installation** | `pipx install sqlit-tui` | Portable binary | Installation required | App Store/direct | `pip install datasette` | Installation required | `pip install litecli` |

### Individual Tool Details

#### sqlit — TUI for Terminal Power Users

[Maxteabag/sqlit](https://github.com/Maxteabag/sqlit). "The lazygit of SQL Databases." A TUI client based on Python/Textual.

- **Status:** v1.3.1 (2026-02), ~3.8k stars, actively maintained
- **Editing Approach:** Auto-generates `UPDATE` SQL when editing cells and displays it in the query editor — lets you directly verify the SQL to be executed
- **CLI Mode:** `sqlit query -c "vault" -q "SELECT ..." --format json` — supports non-interactive JSON/CSV output
- **vault.db Compatibility:** Recursive CTEs, triggers, and virtual tables are all natively handled by the Python `sqlite3` driver
- **Curation Suitability:** Optimal for single-user, keyboard-centric workflows. Vim-style keybindings. Fuzzy search/filtering over millions of rows

#### SQLiteStudio — Extensible Cross-Platform Tool

[sqlitestudio.pl](https://sqlitestudio.pl). C++/Qt based, GPL license.

- **Status:** v3.4.21 (2026-01), 10+ years of development, actively maintained. ERD editor to be added in 4.0
- **Custom SQL Functions:** User-defined functions can be implemented in JavaScript, Python, or Tcl — curation logic (regex validation, text cleanup, etc.) can be embedded as SQL functions
- **DDL History:** Schema change history tracking — useful for vault.db schema evolution auditing
- **Portable:** Run after extraction without installation. No admin privileges required
- **Curation Suitability:** Optimal for power users who need complex custom logic. SQLCipher encryption support. Multi-DB cross-reference queries

#### DB Browser for SQLite — General-Purpose Visual Browser

[sqlitebrowser.org](https://sqlitebrowser.org). Cross-platform open source.

- **Status:** v3.13.1 (2024-10), community-driven, stable but slow release cycle
- **CSV Handling:** Large CSV import/loading is the most robust compared to other tools
- **SQLCipher:** Excellent encrypted DB support
- **Known Issues:** Performance degradation reported with large FTS5 indexes. UI is functional but not modern. Some users report stability issues
- **Curation Suitability:** Suitable for basic data exploration/editing. Unremarkable general-purpose utility rather than standout features

#### Base — macOS Native SQLite Editor

[menial.co.uk/base](https://menial.co.uk/base/). Swift/AppKit native, macOS only.

- **Status:** v3.0 (2025-08), 15+ years of development history, single artisan developer
- **Schema Inspector:** Visualizes CHECK constraints and FKs with interactive icons — more intuitive than raw DDL
- **FK Auto-Activation:** Automatically applies `PRAGMA foreign_keys = ON` per session
- **FTS5:** Native support. Includes STRICT tables, WITHOUT ROWID, and generated columns
- **Table Refactoring:** Handles SQLite `ALTER TABLE` limitations (requiring table recreation) through the GUI
- **Curation Suitability:** The most pleasant editing experience for macOS users. Clean, fast, and stable

#### datasette — Team-Shared Web Browser

[datasette.io](https://datasette.io). Created by Simon Willison, Apache 2.0.

- **Status:** v0.65.2 (stable) / v1.0a9 (alpha), ~10.8k stars, actively maintained
- **Faceted Browsing:** Auto-generates facet filters by status, type, etc. — explore entries without SQL
- **FTS5 Integration:** Automatically provides search UI for FTS5-enabled tables
- **Write Support:** Read-only by default, extensible via plugins
  - `datasette-write-ui`: Adds Edit/Insert/Delete buttons to the web UI
  - `datasette-auth-passwords`: Write access permission control
  - Canned Queries: Exposes specific UPDATE/INSERT SQL as web forms via `metadata.yml`
- **Deployment:** `datasette vault.db` (local), `datasette publish cloudrun` (cloud), Docker packaging
- **Curation Suitability:** **The only team-sharing option.** Optimal when multiple curators need to explore/edit the vault via browser

#### TablePlus — Native Multi-DB Client

[tableplus.com](https://tableplus.com). Native implementation (macOS: Swift, Windows: C#).

- **Status:** Actively maintained, supports macOS/Windows/Linux/iOS
- **Pricing:** Free tier (limited to 2 tabs, 2 connections) / Paid $99+ (perpetual license, 1 year updates)
- **Change Staging:** Does not immediately apply edits; instead previews SQL like a "code review" before committing — safe curation
- **Safe Mode:** Prevents mistakes on production DBs
- **Curation Suitability:** Not SQLite-specific but a stable and pleasant general-purpose DB client. Free tier limitations may be inconvenient for curation workflows

#### litecli — Enhanced SQLite CLI

[dbcli.com/litecli](https://dbcli.com/litecli). Python based, BSD-3.

- **Status:** v1.17.1 (2026), dbcli family (same lineage as pgcli, mycli)
- **Autocomplete:** Context-aware autocomplete for table names, column names, and aliases. Fuzzy matching (`djmi` → `django_migrations`)
- **Output Formats:** 15+ formats (fancy_grid, github/Markdown, csv, html, etc.). Switch instantly with `\T csv`
- **vs. sqlite3 CLI:** Syntax highlighting, multi-line queries, config file (`.liteclirc`), Emacs/Vi keybindings
- **Curation Suitability:** Drop-in upgrade from raw `sqlite3`. Optimal for quick ad-hoc queries but no editing UI

### Recommendations by Use Case

| Scenario | Recommended Tool |
|---|---|
| Single curator, macOS | **Base** or **sqlit** |
| Single curator, cross-platform | **SQLiteStudio** |
| Team curation (multiple participants) | **datasette** + write-ui plugin |
| Quick one-off checks (terminal) | **litecli** |
| Custom curation logic needed | **SQLiteStudio** (custom SQL functions) |

---

> **Last Reviewed:** 2026-03-06 | **Alignment Targets:** design-philosophy.md, design-implementation.md, README.md
