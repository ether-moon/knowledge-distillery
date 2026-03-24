---
description: "Validates knowledge candidates against quality rules before vault insertion. Stage B step 3. Two-layer verification: deterministic rule checks (schema, R3, R5) followed by LLM-based semantic judgment (R1 evidence sufficiency, R6 duplicate detection, conflict identification)."
---

# quality-gate — Stage B-3 Quality Verification

## When This Skill Runs

- Called by `/knowledge-distillery:batch-refine` orchestrator after `/knowledge-distillery:extract-candidates` completes
- Runs within the same subagent context (candidate array is in-memory)
- Invoked as `/knowledge-distillery:quality-gate`

## Prerequisites

- `knowledge-gate` CLI available (resolve path as described in the `knowledge-gate` skill — local dev path if available, else `${CLAUDE_PLUGIN_ROOT}`)
- `.knowledge/vault.db` accessible via CLI only (no direct reads)
- Candidate array from `/knowledge-distillery:extract-candidates` available in-memory

## Allowed Tools

- `GATE query-domain` — existing entries for semantic comparison
- `GATE get` — full entry details for conflict analysis
- `GATE search` — keyword search for duplicate detection
- No direct vault.db access. No file writes.

## Input

| Field | Source | Format |
|-------|--------|--------|
| Candidates | In-memory from `/knowledge-distillery:extract-candidates` | Array of candidate objects per Candidate Required Schema |

If the candidate array is empty, return an empty verdict array immediately. This is not an error.

## Output

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
- `rejection_codes` contains one or more codes from the Rejection Codes table
- `notes` explains each specific failure

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

## Execution Steps

### Overview: Two-Layer Verification

Verification proceeds in two layers. **Both layers run for every candidate.** Layer 1 failures are immediate FAILs, but Layer 2 still runs to provide complete feedback.

### Layer 1: Rule-Based Checks (Deterministic)

These checks are mechanical — they inspect the candidate structure without interpretation. No LLM judgment needed.

For each candidate, check ALL of the following:

**SCHEMA_INVALID — Schema Conformance:**
- Missing required fields → FAIL. Required fields: `id`, `type`, `title`, `claim`, `body`, `applies_to`, `evidence`, `considerations`
- `evidence` is an empty array → FAIL
- `claim` is empty or exceeds 200 characters → FAIL
- `body` is missing `## Background` or `## Details` section headers → FAIL

**R3_NO_ALTERNATIVE — Anti-pattern Requires Alternative:**
- `type == "anti-pattern"` AND (`alternative` is null OR `alternative` is empty string) → FAIL

**R5_UNCONSIDERED — Considerations Must Not Be Empty:**
- `considerations` is null OR empty string OR equals `"none"` (case-insensitive) → FAIL

Any Layer 1 failure → immediate `"fail"` verdict. Layer 2 still runs (to provide complete feedback) but cannot override a Layer 1 failure.

### Layer 2: LLM Judgment Checks

These require semantic understanding and comparison against existing vault content.

#### R1: Evidence Sufficiency

Evaluate whether the candidate's `claim` is adequately supported by the cited evidence:

1. Does the evidence contain **explicit team agreement** or a **demonstrated outcome** (e.g., post-incident fix)?
2. Is the claim a **reasonable conclusion** from the evidence, not an overreach?
3. Would a **skeptical reviewer** accept this evidence as sufficient?

If the evidence is weak, ambiguous, or does not support the claim → `R1_EVIDENCE_INSUFFICIENT`

**Borderline R1 decisions:** Err on the side of rejecting. Better to miss a valid candidate than to insert an unsupported claim into the vault.

#### R6: Semantic Duplicate Detection

Compare the candidate against existing vault entries in the same domains:

1. Fetch existing entries for each domain in `applies_to.domains`:
   ```bash
   GATE query-domain "<domain>"
   ```

2. If the candidate has a `conflict_check` value referencing an existing entry, also fetch that entry:
   ```bash
   GATE get "<conflict_check_id>"
   ```

3. For each existing entry, classify the relationship:

| Classification | Definition | Verdict |
|---------------|------------|---------|
| `duplicate` | Semantically identical claim — same rule, same scope | FAIL (`R6_DUPLICATE`) |
| `conflict` | Related but contradictory — different conclusion for overlapping scope | PASS + `curation_queue_entry` |
| `unrelated` | Different topic or non-overlapping scope | PASS (no action) |

#### Duplicate vs Conflict Heuristics

- **Duplicate**: Both entries would give an agent the **same behavioral guidance**. Wording differs but intent is identical.
  - Example: "Use Service Objects for payments" vs "Payment logic belongs in Service Objects" → **duplicate**

- **Conflict**: Both address the **same scope** but prescribe **different behavior**. Human must decide which is correct.
  - Example: "Use Service Objects for payments" vs "Keep payment logic in controllers for simplicity" → **conflict**

- **When unsure**: Classify as `conflict` (safer — routes to human review) rather than `duplicate` (auto-reject).

### Compose Verdicts

For each candidate, produce a verdict:

1. Collect ALL rejection codes from both layers (not just the first failure)
2. If any rejection codes exist → `verdict: "fail"`
3. If no rejection codes but a conflict was detected → `verdict: "pass"` with `curation_queue_entry`
4. If no rejection codes and no conflict → `verdict: "pass"` with `curation_queue_entry: null`
5. Write `notes` explaining the outcome in human-readable form. For failures, explain each rejection code.

## Rejection Codes

| Code | Layer | Description |
|------|-------|-------------|
| `SCHEMA_INVALID` | 1 (Rule) | Candidate does not conform to required schema |
| `R3_NO_ALTERNATIVE` | 1 (Rule) | Anti-pattern entry missing required alternative |
| `R5_UNCONSIDERED` | 1 (Rule) | Considerations field empty or trivially dismissed |
| `R1_EVIDENCE_INSUFFICIENT` | 2 (LLM) | Claim not adequately supported by cited evidence |
| `R6_DUPLICATE` | 2 (LLM) | Semantically identical to existing vault entry |

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| `knowledge-gate` CLI unavailable | Cannot perform R6 duplicate check. Skip R6 — pass candidates on other rules. Log warning in `notes`. |
| Empty candidate array | Return empty verdict array `[]`. Not an error. |
| Single candidate has multiple failures | Report ALL rejection codes, not just the first. |
| Borderline R1 judgment | Err on the side of rejecting. |
| Borderline R6 duplicate | Classify as `conflict` (human review) rather than `duplicate` (auto-reject). |
| `query-domain` returns error for a domain | Log warning. Skip R6 check for that domain only. Continue with other domains. |
| `get` returns error for conflict_check entry | Log warning. Skip that specific conflict comparison. Continue. |

## Example Verdicts

### Candidate Passes All Gates

```json
{
  "candidate_id": "payment-service-object-pattern",
  "verdict": "pass",
  "rejection_codes": [],
  "curation_queue_entry": null,
  "notes": "All checks passed. Evidence shows team consensus in LIN-456."
}
```

### Anti-Pattern Missing Alternative (R3)

```json
{
  "candidate_id": "no-direct-db-access",
  "verdict": "fail",
  "rejection_codes": ["R3_NO_ALTERNATIVE"],
  "curation_queue_entry": null,
  "notes": "Anti-pattern entries require an alternative approach. What should developers do instead?"
}
```

### Semantic Duplicate (R6)

```json
{
  "candidate_id": "no-api-in-callbacks",
  "verdict": "fail",
  "rejection_codes": ["R6_DUPLICATE"],
  "curation_queue_entry": null,
  "notes": "Semantically identical to existing entry 'no-ar-callback-api'. Same rule, same scope."
}
```

### Conflict Detected — Passes with Curation Queue

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

### Multiple Failures

```json
{
  "candidate_id": "bad-candidate",
  "verdict": "fail",
  "rejection_codes": ["R3_NO_ALTERNATIVE", "R5_UNCONSIDERED", "R1_EVIDENCE_INSUFFICIENT"],
  "curation_queue_entry": null,
  "notes": "Multiple failures: (1) Anti-pattern missing alternative, (2) Empty considerations, (3) Evidence is a single commit with no review or discussion."
}
```

## Constraints

- MUST apply ALL applicable rejection codes per candidate, not just the first failure
- MUST NOT modify candidates — only produce verdicts
- MUST NOT access vault.db directly — use `knowledge-gate` CLI only
- MUST NOT write files to disk
- MUST classify borderline duplicates as `conflict` (human review) rather than auto-rejecting
- MUST err toward rejection on borderline R1 evidence checks
- MUST return empty array for empty input (not error)
- MUST run both Layer 1 and Layer 2 for every candidate (Layer 2 provides feedback even on Layer 1 failures)

## Validation Checklist

Before returning verdicts, verify:

1. Does Layer 1 catch all structural/schema violations deterministically?
2. Does Layer 2 evaluate evidence sufficiency (R1) for every candidate?
3. Does R6 check compare against existing vault entries via CLI?
4. Does the skill distinguish `duplicate` (FAIL) from `conflict` (PASS + curation queue)?
5. Are ALL applicable rejection codes reported per candidate (not just first)?
6. Does the skill return empty array for empty candidate input?
7. Does the skill handle `knowledge-gate` CLI unavailability gracefully?
8. Are borderline cases handled conservatively (reject R1, queue R6)?
