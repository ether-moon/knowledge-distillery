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

- `<knowledge-gate> domain-resolve-path` — resolve changed files to domains
- `<knowledge-gate> domain-list` — inspect the existing domain registry as a controlled vocabulary
- `<knowledge-gate> query-domain` — fetch existing entries for relevant domains
- `<knowledge-gate> search` — keyword search for potential duplicates
- `<knowledge-gate> get` — full entry details for conflict check
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

Before proposing any new domains, load the existing active registry once as a lightweight controlled vocabulary:

```bash
<knowledge-gate> domain-list --ids-only
```

Use this list to:
- Reuse existing domains whenever a changed file or extracted rule clearly fits one
- Avoid inventing near-duplicate names for concepts the registry already covers
- Compare any proposed new domain against neighboring existing domains for overlap, over-breadth, or over-specificity

For each file path in the Evidence Bundle's root-level `changed_files` array:

```bash
<knowledge-gate> domain-resolve-path "<filepath>"
```

Collect all matched domains from the output. Results include global domains (pattern = `*`) automatically — do not exclude them; they serve as the scope for project-wide rules.

If no domains match any file (aside from global domains), note this — the candidate's `applies_to.domains` will contain proposed names for new domains. When proposing a new domain, include in the candidate a `_proposed_domain` annotation array. `_pipeline-insert` will consume this to create domains with proper descriptions and path mappings:

```json
{
  "name": "proposed-domain-name",
  "description": "One-sentence scope statement describing what this domain covers and, when helpful, what it excludes",
  "suggested_patterns": ["path/prefix/"]
}
```

Deduplicate the final domain list.

**Domain definition guidelines:**
- **Granularity:** The unit at which a team makes independent decisions. "payment" is appropriate; over-splitting into "payment-refund" and "payment-charge" is not.
- **Cross-cutting concerns:** Rules not confined to a specific directory (security policies, testing practices, error handling) are classified as technical cross-cutting domains.
- **Naming convention:** Lowercase kebab-case. Distinguish business domains from technical domains (e.g., `payment` vs `activerecord`).

**Domain naming rubric:**
- Optimize for **trigger quality**, not brevity. The domain ID may later be shown in a lightweight index such as `domain-list --ids-only`, so an agent must be able to infer when to query it from the name alone.
- Prefer a slightly longer but self-explanatory name over a short ambiguous one. `batch-refinement` is better than `batch`; `vault-schema` is better than `schema`.
- Use durable responsibility or workflow terms, not transient implementation details. Prefer `evidence-collection` over `collect-evidence-step`; prefer `plugin-runtime` over `bash-wrapper`.
- Include the main noun plus the distinguishing qualifier needed to separate it from neighboring domains.
- Avoid vague container names such as `core`, `system`, `misc`, `general`, `processing`, or `utils` unless the repository already uses that term as a stable, well-bounded concept.
- Avoid names that are so narrow they only fit one file, one class, or one sub-step. If the best name sounds like a function name or ticket title, it is probably too narrow.
- A strong domain name should answer both questions from the ID alone:
  1. "What kinds of tasks or files should trigger this domain?"
  2. "What adjacent tasks or files should NOT trigger this domain?"

**When proposing a new domain, do this internal naming pass before finalizing it:**
1. Draft 2-3 candidate names from the evidence and changed paths.
2. Compare each candidate against the existing registry from `domain-list --ids-only`. Eliminate names that would duplicate, shadow, or barely specialize an existing domain.
3. For each surviving candidate, mentally test a few likely trigger phrases or files that SHOULD map to it and a few nearby ones that SHOULD NOT.
4. Choose the most discriminative name, even if it is longer.
5. If none of the candidates has a clear boundary, prefer an existing broader domain instead of inventing a weak new one.

**Registry reuse and improvement rules:**
- If an existing domain already covers the responsibility or workflow with acceptable precision, reuse it.
- If the work clearly falls under an existing domain but the current name looks too broad, too narrow, or otherwise weak, still reuse it for the candidate now. Do NOT invent a replacement domain just because the existing name is imperfect.
- Instead, record the improvement need in a `_domain_maintenance` annotation so merge, split, rename, or scope cleanup can be considered deliberately later in the batch report.
- Only propose a new domain when the existing registry lacks a domain whose boundary cleanly fits the changed work.

**Examples:**
- Good: `batch-refinement`, `evidence-collection`, `vault-schema`, `plugin-runtime`
- Weak: `batch`, `collection`, `schema`, `runtime`, `processing`, `core`

### Step 2: Fetch Existing Vault Entries

For each resolved domain from Step 1:

```bash
<knowledge-gate> query-domain "<domain>"
```

Collect all existing active entries for these domains. These are needed for:
- Avoiding duplicate extraction
- Identifying conflicts with existing entries
- Understanding existing coverage

### Step 2.5: Aggregate Vault Feedback

Collect `vault_refs` from all memento entries in the Evidence Bundle:

1. Build a feedback map: `{ entry_id → [{signal, note, memento_sha}] }`
2. Filter to actionable signals only: `outdated`, `conflicted`, `insufficient`
3. `followed` signals are informational and confirm entry validity — do not include in the feedback map

This map is used in Step 4b to strengthen conflict detection when session evidence contradicts existing vault entries.

If no memento entries have `vault_refs`, or all signals are `followed`, the feedback map is empty — proceed normally.

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
- If vault feedback from Step 2.5 shows `outdated`/`conflicted` signals for an existing entry, AND this candidate covers the same scope → strengthen the conflict signal. Attach a `_vault_feedback` annotation to the candidate with the relevant feedback entries.

**4c. Actionable** — The knowledge can guide future coding decisions.

- "We chose React" → not actionable for daily coding (too broad)
- "Use React Server Components for data-fetching pages" → actionable

**4d. Not directly derivable** — The knowledge adds value beyond what current repo artifacts already convey.

**MUST: Verify Q1 against actual repo artifacts.** Do not guess derivability from the candidate text alone. Find and read the relevant artifacts — check `applies_to.paths`, grep for the class/function/pattern/config mentioned in the claim, or navigate from the evidence PR's changed files. Confirm whether the claim is already visible in the current codebase before deciding Q1. Skipping this step is the primary cause of false-positive extractions.

Apply two questions in sequence:

- **Q1 — Derivability:** Can the claim be directly derived by reading current repo artifacts? **You must read the relevant files to answer this — do not infer from the candidate text.** Any of the following makes Q1=yes:
  - **Code structure** — functions, classes, modules, or control flow express the behavior described in the claim
  - **Comments / docstrings / error messages** — inline text already conveys the intent
  - **Config files** — `.gitignore`, YAML workflows, JSON configs, `package.json` scripts embody the rule
  - **Directive docs** — README, CLAUDE.md, AGENTS.md, SKILL.md, or design docs document the practice
  - **Test assertions** — test cases encode the expected behavior

  If **any single artifact** already communicates what the candidate describes, Q1=yes. The bar is low: even a partial expression counts.

- **Q2 — Residual value:** Does this entry preserve *why*, *boundary*, *exception*, or *failure mode* that a developer **could not infer** from the artifacts themselves?

| Q1 | Q2 | Decision |
|----|-----|----------|
| yes | no | **Skip** — vault adds no value over reading the code |
| yes | yes | **Keep candidate** — artifact shows *what*, entry preserves *why* |
| no | — | **Keep candidate** — knowledge is not visible in artifacts |

> **Q2 strictness — self-evident rationale is NOT residual value:**
> Q2 is only YES when the rationale would **surprise** a competent developer reading the current code. The following do NOT count as residual value:
>
> - **Pattern-inherent rationale:** If the "why" follows directly from the engineering pattern used (input validation → prevents injection; fail-fast → prevents silent failures; catch-all case → prevents silent misuse), the reasoning is inherent in the pattern itself — Q2=no.
> - **Standard engineering practice:** If the rationale restates well-known principles rather than project-specific context (lightweight output → reduces cost; strict access checks → prevents unauthorized use; gitignoring runtime config → prevents secret leaks), Q2=no.
> - **Intent already visible in code:** If error messages, variable names, comments, or doc strings in the implementation already convey the intent, the entry adds no invisible knowledge — Q2=no.
> - **Behavior + obvious purpose:** If the code clearly shows *what* it does and a developer can trivially reconstruct *why* from the behavior alone (e.g., a regex guard in a shell script → shell injection prevention), Q2=no even if the entry adds a "Rejected Alternatives" section.
>
> Q2=yes requires genuinely non-obvious context: a past incident that shaped the design, a deliberate tradeoff between competing valid approaches, a policy constraint from outside the codebase, or a boundary that contradicts what someone might naively expect.

> **Important:** "Traceable via `git log` / `git blame`" is NOT a reject reason. Historical rationale buried in commit history is exactly what the vault should surface — it is not readily visible during normal development.

**Fact-type filter:** A `fact` candidate that merely describes current state ("X uses Y") without rationale is directly derivable — skip it. A `fact` whose rationale is self-evident from the implementation pattern is also directly derivable — skip it. Only extract facts that carry **non-obvious** reasoning ("When touching X, keep Y because Z" where Z is not inferable from X's implementation).

> **"How-it-works" rejection — the most common false positive:**
> Claims shaped as "X uses Y", "X does Y via Z", "X validates using Y", or "X works by doing Y" describe **implementation mechanics**. The code IS the canonical expression of how it works — restating it in the vault is redundant regardless of how well-structured the candidate body is.
>
> - Any how-it-works claim is **Q1=yes by default**. The code already says this.
> - To survive Q2, the candidate must answer: **"Why THIS approach and not an obvious alternative?"** — with genuinely non-obvious context (a past incident, an external policy, a counterintuitive tradeoff). If the answer is "because that's the standard/correct way to do it", Q2=no.
> - A well-written body (Background, Rejected Alternatives, etc.) does NOT rescue a how-it-works claim. The body's rationale itself must be non-obvious.

Examples:
- "The `/curate` workflow checks branch prefix `knowledge/batch-*`" → Q1=yes (YAML file), Q2=no → **skip**
- "`get-many` MUST exit 1 when requested IDs are missing" → Q1=yes (code + error message), Q2=no (fail-fast rationale is self-evident from pattern) → **skip**
- "Query commands MUST reject unknown flags with usage error" → Q1=yes (catch-all in code), Q2=no (standard CLI error handling) → **skip**
- "`.mcp.json` MUST be gitignored" → Q1=yes (already in `.gitignore`), Q2=no (runtime config with potential secrets → standard practice) → **skip**
- "Branch name validation MUST use env var + regex instead of direct interpolation" → Q1=yes (workflow YAML), Q2=no (shell injection prevention via env var is a well-known pattern) → **skip**
- "The batch-refine pipeline sorts results by `mergedAt` ascending before aggregating" → Q1=yes (code in orchestrator), Q2=no (how-it-works — describes implementation mechanics readable from code) → **skip**
- "The curate-report skill classifies feedback into REJECT, UPDATE, KEEP, and UNRESOLVED actions" → Q1=yes (SKILL.md documents the action types), Q2=no (how-it-works — restates what the skill definition already says) → **skip**
- "The `collect-evidence` skill records identifiers only at marking time, not evidence content" → Q1=yes (SKILL.md + code), Q2=no (how-it-works — design directly readable from implementation and docs) → **skip**
- "Archive rejected vault entries instead of deleting to preserve audit history" → Q1=partially (function exists), Q2=yes (audit trail requirement is not self-evident from the archive function alone) → **keep**
- "PR body template enforcement is out of scope for knowledge-distillery" → Q1=no (scope decisions aren't in code), Q2=yes (boundary + rejected alternative) → **keep**
- "Use React Server Components for data-fetching pages because SSR hydration cost was causing 3s delays on the dashboard" → Q1=yes (code uses RSC), Q2=yes (the 3s delay incident and performance threshold are not in the code) → **keep**

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
   - If proposing a new domain, prefer names that remain understandable when shown without description in a compact domain index.

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

11. **`_domain_maintenance`**: Optional structured hints for later domain registry cleanup when reusing or proposing domains reveals naming/scope issues.
    - Use only when the evidence suggests follow-up domain maintenance.
    - Format:

```json
[
  {
    "domain": "existing-or-proposed-domain",
    "issue": "too-broad | too-narrow | ambiguous-name | near-duplicate",
    "suggestion": "split | merge | rename | scope-cleanup",
    "reason": "Why this batch suggests a follow-up review"
  }
]
```
    - Examples:
      - Reused `pipeline` but evidence shows repeated orchestration-vs-worker confusion → `{ "domain": "pipeline", "issue": "too-broad", "suggestion": "split", ... }`
      - Proposed `batch-runtime` looks very close to existing `plugin-runtime` → `{ "domain": "batch-runtime", "issue": "near-duplicate", "suggestion": "merge", ... }`

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
  "_proposed_domain": [{"name": "<new-domain>", "description": "...", "suggested_patterns": ["path/"]}],
  "_domain_maintenance": [{"domain": "<domain>", "issue": "...", "suggestion": "...", "reason": "..."}],
  "_vault_feedback": [{"entry_id": "existing-entry-id", "signal": "outdated|conflicted|insufficient", "note": "from memento", "memento_sha": "a1b2c3d"}]
}
```

Note: `_proposed_domain` is only present when new domains are proposed (see Step 1). Omit when all domains already exist in the vault. `_domain_maintenance` is only present when this batch reveals a follow-up registry improvement need. `_vault_feedback` is only present when vault feedback from Step 2.5 exists for related existing entries — `followed` signals are excluded (no action needed).

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
- MUST NOT call `_pipeline-insert`, `_pipeline-archive`, `_pipeline-update`, or `_changeset-apply` — these mutate vault.db. Candidates are returned in-memory to the orchestrator, which writes the changeset file.
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
9. Does each `fact` candidate preserve **non-obvious** rationale, constraint, or boundary — not just describe current state, self-evident engineering reasoning, or implementation mechanics ("how it works")?
10. If a new domain is proposed, is the name self-explanatory enough to be recognized from the ID alone in `domain-list --ids-only`?
11. If a new domain is proposed, does its `description` define the scope clearly enough to distinguish it from adjacent domains?
12. Before proposing a new domain, did the skill check whether an existing domain could be reused instead?
13. If a reused or proposed domain revealed a naming/scope problem, was that follow-up captured in `_domain_maintenance` rather than left implicit?
