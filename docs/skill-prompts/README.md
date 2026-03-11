# Skill Prompts — Catalog

This directory contains **skill creation prompts** for the Knowledge Distillery pipeline. Each `.prompt.md` file is designed to be fed to an LLM to generate a working skill file for the specified stage of the pipeline.

These prompts do NOT implement the skills themselves — they specify what a generated skill must do, with enough precision for an LLM to produce a functional implementation.

## File Index

| File | Stage | Description |
|------|-------|-------------|
| `evidence-manifest.spec.md` | — | Data format specification for Evidence Bundle Manifest |
| `mark-evidence.prompt.md` | A | Merge-time identifier extraction and Manifest posting |
| `collect-evidence.prompt.md` | B-1 | Full evidence content collection from identified sources |
| `extract-candidates.prompt.md` | B-2 | Core LLM extraction of knowledge candidates |
| `quality-gate.prompt.md` | B-3 | Two-layer quality verification (rule-based + LLM) |
| `batch-refine.prompt.md` | B-orch | Orchestrator: discovery, subagent dispatch, vault INSERT, report PR |
| `knowledge-gate.prompt.md` | Runtime | Agent configuration for vault-aware coding |
| `memento-summary.prompt.md` | Pre-pipeline | git-memento custom summary skill |

## Dependency Graph

```
                    evidence-manifest.spec.md
                              │
              ┌───────────────┼───────────────┐
              ▼               │               │
    mark-evidence             │               │
    (Stage A)                 │               │
              │               │               │
              ▼               ▼               │
    collect-evidence ─────────┘               │
    (B-step 1)                                │
              │                               │
              ▼                               │
    extract-candidates                        │
    (B-step 2)                                │
              │                               │
              ▼                               │
    quality-gate                              │
    (B-step 3)                                │
              │                               │
              ▼                               │
    batch-refine ─────────────────────────────┘
    (B-orchestrator)


    knowledge-gate          memento-summary
    (Runtime)               (Pre-pipeline)
    [independent]           [independent]
```

### Dependency Details

- **evidence-manifest.spec.md**: Foundation. All pipeline skills reference this format.
- **mark-evidence**: First consumer of the Manifest format. Writes Manifest comments.
- **collect-evidence**: Reads Manifest comments. Produces Evidence Bundle.
- **extract-candidates**: Reads Evidence Bundle. Produces candidate array.
- **quality-gate**: Reads candidate array. Produces verdict array.
- **batch-refine**: Orchestrates B-step 1→2→3 per PR. Reads/writes vault.db.
- **knowledge-gate**: Independent. Reads vault.db at agent runtime.
- **memento-summary**: Independent. Produces git notes consumed later by collect-evidence.

## Pipeline Overview

```
PR merged to main
        │
        ▼
   ┌─────────────┐
   │ mark-evidence│ ← GitHub Action (Stage A)
   │  (A-stage)   │
   └──────┬──────┘
          │ Manifest comment + knowledge:pending label
          ▼
   ┌──────────────┐
   │ batch-refine  │ ← Cron / manual dispatch (Stage B)
   │ (orchestrator)│
   └──────┬───────┘
          │ Per-PR subagent:
          ▼
   ┌─────────────────┐    ┌──────────────────┐    ┌─────────────┐
   │collect-evidence  │ →  │extract-candidates │ →  │quality-gate  │
   │  (B-step 1)      │    │  (B-step 2)       │    │  (B-step 3)  │
   └─────────────────┘    └──────────────────┘    └──────┬──────┘
                                                         │
          ┌──────────────────────────────────────────────┘
          │ Passed candidates
          ▼
   vault.db INSERT + Report PR
          │
          ▼
   Human reviews & merges report PR
```

## Prompt File Structure

All `.prompt.md` files follow a consistent structure:

| Section | Purpose |
|---------|---------|
| Purpose | What the generated skill does |
| Pipeline Position | Trigger → dependencies → outputs |
| Prerequisites | Runtime environment, allowed tools |
| Input Contract | Data format, source, schema |
| Output Contract | Data format, consumer, parsing |
| Behavioral Requirements | Numbered step-by-step logic |
| Error Handling | Failure mode table |
| Example Scenarios | 2-3 scenarios (success + failure + edge case) |
| Reference Specifications | Design doc section references (no content duplication) |
| Constraints | MUST NOT list |
| Validation Checklist | 5-8 yes/no verification questions |

## Usage Guide

### Generating a Skill

1. Choose the prompt file for the skill you need
2. Feed the prompt to an LLM along with the referenced design documents
3. The LLM produces a skill file (format depends on target: GitHub Action, Claude Code Skill, etc.)
4. Validate the generated skill against the prompt's Validation Checklist

### Contract Chain Verification

Before using generated skills together, verify the contract chain:

| Producer | Output | Consumer | Input |
|----------|--------|----------|-------|
| mark-evidence | Manifest comment (JSON) | collect-evidence | Manifest JSON (parsed from comment) |
| collect-evidence | Evidence Bundle (in-memory JSON) | extract-candidates | Evidence Bundle |
| extract-candidates | Candidate array | quality-gate | Candidate array |
| quality-gate | Verdict array | batch-refine | Verdict array (pass/fail decisions) |

### E2E Scenario Trace

To verify the full pipeline, trace a single PR through all stages:

1. **mark-evidence**: PR #1234 merged → Manifest posted with Linear IDs, memento SHAs
2. **collect-evidence**: Manifest parsed → PR diff, Linear issues, memento notes fetched → Evidence Bundle
3. **extract-candidates**: Evidence analyzed → 1 Fact candidate extracted
4. **quality-gate**: Candidate validated → passes all gates
5. **batch-refine**: Candidate inserted into vault.db → report PR created → human merges

## Design Document References

| Document | Key Sections |
|----------|-------------|
| `design-implementation.md` | §3.1 (pipeline triggers), §3.2 (evidence bundle), §3.3 (extraction), §3.4 (quality gates), §4.2 (vault schema), §4.3 (body template), §4.5 (domain model) |
| `cli.md` | §1-2 (query commands), §4 (domain report), §5 (skill template), §6 (auto domain derivation) |
| `design-philosophy.md` | §1-4 (three-layer architecture, information types, air gap) |
| `evidence-manifest.spec.md` | Manifest format, validation rules, parsing instructions |
