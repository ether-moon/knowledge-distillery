# Quality Gate — Skill Creation Prompt

## Purpose

Generate a skill file that validates knowledge candidates against defined quality rules before vault insertion. This is Stage B step 3 — a two-layer verification combining deterministic rule checks with LLM-based semantic judgment.

## Pipeline Position

- **Trigger**: Called by `/batch-refine` orchestrator after `/extract-candidates` completes (same subagent)
- **Depends on**: Candidate array from `/extract-candidates`
- **Produces**: Verdict array (pass/fail per candidate) + curation queue entries
- **Consumed by**: `/batch-refine` orchestrator (for vault INSERT decisions and report generation)

## Prerequisites

### Runtime Environment
- Claude Code agent context (subagent, continuing from `/extract-candidates`)
- `knowledge-gate` CLI available for existing entry queries
- Access to vault.db via CLI only

### Allowed Tools
- `knowledge-gate query-domain` — existing entries for semantic comparison
- `knowledge-gate get` — full entry details for conflict analysis
- `knowledge-gate search` — keyword search for duplicate detection
- No direct vault.db access. No file writes.

## Input Contract

| Field | Source | Format |
|-------|--------|--------|
| Candidates | In-memory from `/extract-candidates` | Array of candidate objects per Candidate Required Schema |
| Existing vault entries | Queried via `knowledge-gate` CLI at runtime | CLI output per cli.md §1 |

If the candidate array is empty, return an empty verdict array immediately.

## Output Contract

Array of verdict objects, one per input candidate:

```json
{
  "candidate_id": "<matches candidate.id>",
  "verdict": "pass | fail",
  "rejection_codes": [],
  "curation_queue_entry": null,
  "notes": "<human-readable explanation>"
}
```

### When `verdict` is `"fail"`:
- `rejection_codes` contains one or more codes (see Rejection Codes below)
- `notes` explains the specific failure

### When a conflict is detected but candidate passes:
- `verdict` is `"pass"`
- `curation_queue_entry` is set:

```json
{
  "type": "conflict",
  "related_id": "<existing vault entry ID>",
  "reason": "<why these entries may conflict>"
}
```

## Behavioral Requirements

### Two-Layer Verification

Verification proceeds in two layers. Layer 1 is deterministic (no LLM judgment needed). Layer 2 requires LLM evaluation. Both layers run for every candidate.

### Layer 1: Rule-Based Checks (Deterministic)

These checks are mechanical — they inspect the candidate structure without interpretation.

| Code | Rule | Check |
|------|------|-------|
| `R3_NO_ALTERNATIVE` | Anti-pattern requires alternative | `type == "anti-pattern" AND (alternative == null OR alternative == "")` → FAIL |
| `R5_UNCONSIDERED` | Considerations must not be empty | `considerations == null OR considerations == "" OR considerations == "none"` → FAIL |
| `SCHEMA_INVALID` | Schema conformance | Missing required fields (`id`, `type`, `title`, `claim`, `body`, `applies_to`, `evidence`, `considerations`) → FAIL |
| `SCHEMA_INVALID` | Evidence array | `evidence` is empty array → FAIL |
| `SCHEMA_INVALID` | Claim format | `claim` is empty or exceeds 200 characters → FAIL |
| `SCHEMA_INVALID` | Body sections | `body` missing `## Background` or `## Details` sections → FAIL |

Any Layer 1 failure → immediate `"fail"` verdict. Layer 2 still runs (to provide complete feedback) but cannot override.

### Layer 2: LLM Judgment Checks

These require semantic understanding and comparison against existing vault content.

#### R1: Evidence Sufficiency

Evaluate whether the candidate's `claim` is adequately supported by the cited evidence:

- Does the evidence contain explicit team agreement or demonstrated outcome?
- Is the claim a reasonable conclusion from the evidence, not an overreach?
- Would a skeptical reviewer accept this evidence as sufficient?

If insufficient → `R1_EVIDENCE_INSUFFICIENT`

#### R6: Semantic Duplicate Detection

Compare the candidate against existing vault entries in the same domains:

1. Fetch existing entries via `knowledge-gate query-domain` for each domain in `applies_to.domains`
2. For each existing entry, classify the relationship:

| Classification | Definition | Verdict |
|---------------|------------|---------|
| `duplicate` | Semantically identical claim — same rule, same scope | FAIL (`R6_DUPLICATE`) |
| `conflict` | Related but contradictory — different conclusion for overlapping scope | PASS + `curation_queue_entry` |
| `unrelated` | Different topic or non-overlapping scope | PASS (no action) |

3. If `candidate.conflict_check` references an existing entry, compare against that entry specifically

#### Duplicate vs Conflict Heuristics

- **Duplicate**: Both entries would give an agent the same behavioral guidance. Wording differs but intent is identical.
  - Example: "Use Service Objects for payments" vs "Payment logic belongs in Service Objects" → duplicate
- **Conflict**: Both address the same scope but prescribe different behavior. Human must decide which is correct.
  - Example: "Use Service Objects for payments" vs "Keep payment logic in controllers for simplicity" → conflict
- **When unsure**: Classify as `conflict` (safer — human reviews).

## Rejection Codes

| Code | Layer | Description |
|------|-------|-------------|
| `R1_EVIDENCE_INSUFFICIENT` | 2 (LLM) | Claim not adequately supported by cited evidence |
| `R3_NO_ALTERNATIVE` | 1 (Rule) | Anti-pattern entry missing required alternative |
| `R5_UNCONSIDERED` | 1 (Rule) | Considerations field empty or trivially dismissed |
| `R6_DUPLICATE` | 2 (LLM) | Semantically identical to existing vault entry |
| `SCHEMA_INVALID` | 1 (Rule) | Candidate does not conform to required schema |

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| `knowledge-gate` CLI unavailable | Cannot perform R6 duplicate check. Skip R6 — pass candidates on other rules. Log warning in `notes`. |
| Empty candidate array | Return empty verdict array. Not an error. |
| Single candidate has multiple failures | Report ALL rejection codes, not just the first. |
| Borderline R1 judgment | Err on the side of rejecting. Better to miss a valid candidate than insert unsupported claims. |
| Borderline R6 duplicate | Classify as `conflict` (human review) rather than `duplicate` (auto-reject). |

## Example Scenarios

### Scenario 1: Candidate Passes All Gates

**Input**: Candidate `payment-service-object-pattern` (fact)
- Schema complete, considerations present, evidence cites PR + Linear
- No existing vault entry about payment service objects
- Evidence shows clear team agreement in Linear discussion

**Output**:
```json
{
  "candidate_id": "payment-service-object-pattern",
  "verdict": "pass",
  "rejection_codes": [],
  "curation_queue_entry": null,
  "notes": "All checks passed. Evidence shows team consensus in LIN-456."
}
```

### Scenario 2: Anti-Pattern Missing Alternative (R3)

**Input**: Candidate with `type: "anti-pattern"`, `alternative: null`

**Output**:
```json
{
  "candidate_id": "no-direct-db-access",
  "verdict": "fail",
  "rejection_codes": ["R3_NO_ALTERNATIVE"],
  "curation_queue_entry": null,
  "notes": "Anti-pattern entries require an alternative approach. What should developers do instead?"
}
```

### Scenario 3: Semantic Duplicate (R6)

**Input**: Candidate `no-api-in-callbacks` with claim "MUST-NOT call APIs from ActiveRecord callbacks"
- Existing vault entry `no-ar-callback-api` with claim "MUST-NOT call external APIs from AR callbacks"

**Output**:
```json
{
  "candidate_id": "no-api-in-callbacks",
  "verdict": "fail",
  "rejection_codes": ["R6_DUPLICATE"],
  "curation_queue_entry": null,
  "notes": "Semantically identical to existing entry 'no-ar-callback-api'. Same rule, same scope."
}
```

### Scenario 4: Conflict Detected — Passes with Curation Queue

**Input**: Candidate `use-controller-payment-logic` with claim "Keep payment logic in controllers for simple transactions"
- Existing vault entry `payment-service-object-pattern` says "Use Service Objects for payment transactions"

**Output**:
```json
{
  "candidate_id": "use-controller-payment-logic",
  "verdict": "pass",
  "rejection_codes": [],
  "curation_queue_entry": {
    "type": "conflict",
    "related_id": "payment-service-object-pattern",
    "reason": "Prescribes controller-level payment logic, contradicting existing rule that mandates Service Objects for payments"
  },
  "notes": "Passes quality checks but conflicts with existing entry. Queued for human curation."
}
```

### Scenario 5: Multiple Failures

**Input**: Candidate with `type: "anti-pattern"`, `alternative: null`, `considerations: ""`, weak evidence

**Output**:
```json
{
  "candidate_id": "bad-candidate",
  "verdict": "fail",
  "rejection_codes": ["R3_NO_ALTERNATIVE", "R5_UNCONSIDERED", "R1_EVIDENCE_INSUFFICIENT"],
  "curation_queue_entry": null,
  "notes": "Multiple failures: (1) Anti-pattern missing alternative, (2) Empty considerations, (3) Evidence is a single commit with no review or discussion."
}
```

## Reference Specifications

- Quality gate rules: design-implementation.md §3.4
- R1/R3/R5/R6 definitions: design-implementation.md §3.4
- Conflict detection and curation queue: design-implementation.md §3.4, §5.2
- Candidate schema: design-implementation.md §3.3
- CLI commands for querying: cli.md §1

## Constraints

- MUST apply all applicable rejection codes per candidate, not just the first failure
- MUST NOT modify candidates — only produce verdicts
- MUST NOT access vault.db directly — use `knowledge-gate` CLI only
- MUST NOT write files to disk
- MUST classify borderline duplicates as `conflict` (human review) rather than auto-rejecting
- MUST err toward rejection on borderline R1 evidence checks
- MUST return empty array for empty input (not error)

## Validation Checklist

1. Does Layer 1 catch all structural/schema violations deterministically?
2. Does Layer 2 evaluate evidence sufficiency (R1) for every candidate?
3. Does R6 check compare against existing vault entries via CLI?
4. Does the skill distinguish `duplicate` (FAIL) from `conflict` (PASS + curation queue)?
5. Are ALL applicable rejection codes reported per candidate (not just first)?
6. Does the skill return empty array for empty candidate input?
7. Does the skill handle `knowledge-gate` CLI unavailability gracefully?
8. Are borderline cases handled conservatively (reject R1, queue R6)?
