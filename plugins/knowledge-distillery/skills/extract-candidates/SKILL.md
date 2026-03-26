---
name: extract-candidates
description: "Analyzes an Evidence Bundle and extracts knowledge candidates — the core LLM extraction step of the distillation pipeline. Stage B step 2. Transforms raw evidence into structured vault entry candidates by identifying confirmed team decisions, anti-patterns from incidents, and established conventions."
user-invocable: false
---

# extract-candidates — Stage B-2 Candidate Extraction

## When This Skill Runs

- Called by `/knowledge-distillery:batch-refine` orchestrator after `/knowledge-distillery:collect-evidence` completes
- Runs within the same subagent context (Evidence Bundle is in-memory)
- Invoked as `/knowledge-distillery:extract-candidates`

## Prerequisites

- `knowledge-gate` CLI available (resolve path as described in the `knowledge-gate` skill — local dev path if available, else `${CLAUDE_PLUGIN_ROOT}`)
- `.knowledge/vault.db` accessible via CLI only (no direct reads)
- Evidence Bundle from `/knowledge-distillery:collect-evidence` available in-memory

## Allowed Tools

- `GATE domain-resolve-path` — resolve changed files to domains
- `GATE query-domain` — fetch existing entries for relevant domains
- `GATE search` — keyword search for potential duplicates
- `GATE get` — full entry details for conflict check
- GitHub MCP (read-only) or `git diff` / `git show` — selective diff inspection for the specific files or hunks that need code confirmation
- No direct vault.db reads. No file writes.

## Input

| Field | Source | Format |
|-------|--------|--------|
| Evidence Bundle | In-memory from `/knowledge-distillery:collect-evidence` | JSON object with `pr_number`, `changed_files`, `evidence`, `sufficiency` fields |

If the Evidence Bundle has `sufficiency.verdict == "insufficient"`, return an empty array immediately. This should not normally happen (the orchestrator handles it), but guard against it.

## Output

An array of candidate objects. **Zero candidates is a valid and expected result.** Not every PR produces knowledge.

Do NOT filter candidates — that is the quality gate's job. Return all candidates that meet the extraction criteria.

## Execution Steps

### Step 1: Derive Target Domains

For each file path in the Evidence Bundle's root-level `changed_files` array:

```bash
GATE domain-resolve-path "<filepath>"
```

Collect all matched domains from the output. Results include global domains (pattern = `*`) automatically — do not exclude them; they serve as the scope for project-wide rules.

If no domains match any file (aside from global domains), note this — the candidate's `applies_to.domains` will contain proposed names for new domains. When proposing a new domain, include in the candidate a `_proposed_domain` annotation array. `_pipeline-insert` will consume this to create domains with proper descriptions and path mappings:

```json
{
  "name": "proposed-domain-name",
  "description": "Brief description of what this domain covers",
  "suggested_patterns": ["path/prefix/"]
}
```

Deduplicate the final domain list.

**Domain definition guidelines:**
- **Granularity:** The unit at which a team makes independent decisions. "payment" is appropriate; over-splitting into "payment-refund" and "payment-charge" is not.
- **Cross-cutting concerns:** Rules not confined to a specific directory (security policies, testing practices, error handling) are classified as technical cross-cutting domains.
- **Naming convention:** Lowercase kebab-case. Distinguish business domains from technical domains (e.g., `payment` vs `activerecord`).

### Step 2: Fetch Existing Vault Entries

For each resolved domain from Step 1:

```bash
GATE query-domain "<domain>"
```

Collect all existing active entries for these domains. These are needed for:
- Avoiding duplicate extraction
- Identifying conflicts with existing entries
- Understanding existing coverage

### Step 3: Analyze Evidence for Extractable Knowledge

Read through the Evidence Bundle **holistically**. Look for:

| Signal | What to extract |
|--------|-----------------|
| Explicit architectural decisions in PR body/comments | Fact |
| "We agreed to..." / "Going forward..." in Linear discussions | Fact |
| Failed approaches documented in PR description | Anti-Pattern |
| Reviewer corrections with agreement ("good catch, fixed") | Fact or Anti-Pattern |
| Post-incident changes with root cause analysis | Anti-Pattern |
| Pattern establishment ("introducing Service Object pattern for...") | Fact |
| Constraint discoveries ("we can't do X because Y") | Fact or Anti-Pattern |

**Selective diff inspection:** When a signal from PR body, comments, or Linear discussions points to a specific change, fetch the relevant portion of the PR diff for that file/area. Do NOT inject the entire PR diff into the analysis — use it selectively to confirm and enrich specific candidates.

### Step 4: Apply Extraction Criteria

For each potential candidate, verify ALL of the following:

**4a. Confirmed decision** — The evidence shows **explicit** team agreement, not just one person's opinion.

- PR approved with relevant comments → agreement signal
- Linear issue with multiple participants reaching conclusion → agreement signal
- Single developer's commit with no review → weak signal, skip unless post-incident fix
- Implicit consensus (e.g., "no one objected") → NOT sufficient

Only explicit textual agreement counts. If no explicit agreement is visible in code review comments, Linear discussions, or PR descriptions, do NOT extract as Fact — regardless of how reasonable the approach appears.

> **Conservative extraction principle:** "Explicitly stated agreement only" is intentionally narrow. False positives (wrong knowledge entering the vault) cost more than false negatives (missing valid knowledge). Wrong entries silently misguide agents and are hard to discover; missed knowledge can be re-extracted in the next refinement cycle. Resist the FOMO of "we might miss something."

**4b. Not already known** — Compare against existing vault entries from Step 2.

- If a semantically identical entry exists → skip (not a candidate)
- If a related but different entry exists → set `conflict_check` to that entry's ID

**4c. Actionable** — The knowledge can guide future coding decisions.

- "We chose React" → not actionable for daily coding (too broad)
- "Use React Server Components for data-fetching pages" → actionable

**4d. Not directly derivable** — The knowledge adds value beyond what current repo artifacts already convey.

Apply two questions in sequence:

- **Q1 — Derivability:** Can the claim be directly derived by reading current repo artifacts (source code, configuration, tests, README, CLAUDE.md, design docs)?
- **Q2 — Residual value:** Does this entry preserve *why*, *boundary*, *exception*, or *failure mode* that the artifacts themselves don't explain?

| Q1 | Q2 | Decision |
|----|-----|----------|
| yes | no | **Skip** — vault adds no value over reading the code |
| yes | yes | **Keep candidate** — artifact shows *what*, entry preserves *why* |
| no | — | **Keep candidate** — knowledge is not visible in artifacts |

> **Important:** "Traceable via `git log` / `git blame`" is NOT a reject reason. Historical rationale buried in commit history is exactly what the vault should surface — it is not readily visible during normal development.

**Fact-type filter:** A `fact` candidate that merely describes current state ("X uses Y") without rationale is directly derivable — skip it. Only extract facts that carry a rule or constraint with reasoning ("When touching X, keep Y because Z").

Examples:
- "The `/curate` workflow checks branch prefix `knowledge/batch-*`" → Q1=yes (YAML file), Q2=no → **skip**
- "Archive rejected vault entries instead of deleting to preserve audit history" → Q1=partially (function exists), Q2=yes (preserves *why*) → **keep**
- "PR body template enforcement is out of scope for knowledge-distillery" → Q1=no (scope decisions aren't in code), Q2=yes (boundary + rejected alternative) → **keep**

**When in doubt, leave it out.** If confidence in any criterion is low, do NOT extract.

### Step 5: Compose Candidates

For each validated extraction, produce a candidate object:

1. **`id`**: Generate a kebab-case identifier (descriptive, 3-5 words). Example: `payment-service-object-pattern`

2. **`type`**: Set to `"fact"` or `"anti-pattern"`

3. **`title`**: Concise descriptive title

4. **`claim`**: A single imperative sentence
   - **Fact**: Starts with a verb in imperative form. E.g., "Use Service Objects for payment transaction orchestration"
   - **Anti-Pattern**: Starts with "MUST-NOT" or "Do not". E.g., "MUST-NOT call external APIs from ActiveRecord callbacks"
   - Must be specific enough to verify compliance. One sentence only.

5. **`body`**: Structured markdown following this template:

```markdown
## Background
[Why this rule exists. Context that led to the decision. 2-4 sentences from the evidence.]

## Details
[Specific guidance. Scope boundaries, exceptions, operational guidance.]

## Rejected Alternatives
[Optional for facts. REQUIRED for anti-patterns. Approaches tried and failed, or considered and dismissed.]

## Open Questions
[Optional. Only if genuinely unresolved aspects exist in the evidence.]

## Stop Conditions
[Optional. When this rule should be reconsidered. Trigger for re-evaluation.]
```

6. **`applies_to`**: The applicability scope from Step 1
   - `applies_to.domains`: domain list derived in Step 1

7. **`evidence`**: Array citing specific sources:
   - `{ "type": "pr", "ref": "#1234" }`
   - `{ "type": "linear", "ref": "LIN-456" }`
   - `{ "type": "memento", "ref": "a1b2c3d" }`
   - `{ "type": "slack", "ref": "<url>" }`
   - `{ "type": "greptile", "ref": "<review_id>" }`
   - `{ "type": "notion", "ref": "<notion page URL>" }`
   - Memento notes being absent is normal (git-memento is optional). Other evidence types are sufficient.
   - Notion pages provide design decisions, team agreements, and architectural context as supporting evidence.

8. **`alternative`**: Required for anti-patterns (what to do instead). `null` for facts.

9. **`conflict_check`**: Existing vault entry ID if potential conflict detected in Step 4b. `null` otherwise.

10. **`considerations`**: Explicit concerns, conditions, or caveats. **NEVER empty.**
    - Even if no obvious caveats: "None identified from current evidence. Re-evaluate if [condition]."

### Step 6: Return Candidate Array

Return the array of candidate objects. May be empty — `[]` is a valid result. Do not filter; that is the quality gate's job.

### Candidate Required Schema

Each candidate MUST conform to this schema:

```json
{
  "id": "<kebab-case-identifier>",
  "type": "fact | anti-pattern",
  "title": "<concise descriptive title>",
  "claim": "<MUST or MUST-NOT one-line assertion>",
  "body": "<structured markdown per body template>",
  "applies_to": {
    "domains": ["<domain1>", "<domain2>"]
  },
  "evidence": [
    { "type": "pr | linear | slack | greptile | memento | notion", "ref": "<reference string>" }
  ],
  "alternative": "<required for anti-pattern, null for fact>",
  "conflict_check": "<existing vault entry ID if potential conflict, null otherwise>",
  "considerations": "<explicit concerns, conditions, or caveats — NEVER empty>",
  "_proposed_domain": [{"name": "<new-domain>", "description": "...", "suggested_patterns": ["path/"]}]
}
```

Note: `_proposed_domain` is only present when new domains are proposed (see Step 1). Omit when all domains already exist in the vault.

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| `knowledge-gate` CLI unavailable | Cannot check existing entries. Proceed without conflict_check (set all to null). Log warning. |
| No domains resolved for any file | Propose domain names based on file paths. Set `applies_to.domains` to proposed names with `_proposed_domain` annotation. |
| Evidence Bundle has `insufficient` verdict | Return empty array `[]`. |
| LLM cannot determine confidence in extraction | Do NOT extract. "When in doubt, leave it out." |
| `domain-resolve-path` returns error for a file | Skip that file's domain resolution. Continue with remaining files. |
| `query-domain` returns error | Log warning. Proceed without existing entries for that domain (conflict_check will be null). |

## Constraints

- MUST NOT extract hypotheses, experiments, or unconfirmed opinions as knowledge
- MUST NOT infer agreement from silence or approval-without-comment. Only explicit textual agreement counts.
- MUST NOT create candidates with empty `considerations`
- MUST NOT create anti-pattern candidates without `alternative`
- MUST NOT duplicate existing vault entries (check via `knowledge-gate`)
- MUST NOT access vault.db directly — use `knowledge-gate` CLI only
- MUST NOT write files to disk
- MUST return empty array (not error) when no candidates are extractable
- MUST cite specific evidence references for every candidate
- MUST derive domains from `changed_files` via `domain-resolve-path`, not guess
- MUST NOT inject the entire PR diff into analysis — use the diff selectively for specific signals

## Validation Checklist

Before returning candidates, verify:

1. Does each candidate have a kebab-case `id` (3-5 words)?
2. Does each `claim` follow the imperative/MUST-NOT format (one sentence)?
3. Does each `body` include `## Background` and `## Details` sections?
4. Does every anti-pattern have a non-null `alternative`?
5. Is `considerations` non-empty for every candidate?
6. Does every candidate cite at least one `evidence` source?
7. Are domains derived via `domain-resolve-path`, not hardcoded?
8. Does the skill return `[]` gracefully when no candidates are found?
9. Does each `fact` candidate preserve rationale, constraint, or boundary — not just describe current state?
