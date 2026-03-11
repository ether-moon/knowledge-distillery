# Extract Candidates — Skill Creation Prompt

## Purpose

Generate a skill file that analyzes an Evidence Bundle and extracts knowledge candidates — the core LLM extraction step. This is Stage B step 2, the most critical prompt in the pipeline. It transforms raw evidence into structured vault entry candidates.

## Pipeline Position

- **Trigger**: Called by `/batch-refine` orchestrator after `/collect-evidence` completes (same subagent)
- **Depends on**: Evidence Bundle from `/collect-evidence`
- **Produces**: Candidate array (may be empty)
- **Consumed by**: `/quality-gate` (Stage B step 3, same subagent)

## Prerequisites

### Runtime Environment
- Claude Code agent context (subagent, continuing from `/collect-evidence`)
- `knowledge-gate` CLI available for vault queries
- Access to vault.db via CLI only (for existing entry comparison)

### Allowed Tools
- `knowledge-gate query-domain` — fetch existing entries for relevant domains
- `knowledge-gate domain-resolve-path` — resolve changed files to domains
- `knowledge-gate search` — keyword search for potential duplicates
- `knowledge-gate get` — full entry details for conflict check
- No direct vault.db reads. No file writes.

## Input Contract

| Field | Source | Format |
|-------|--------|--------|
| Evidence Bundle | In-memory from `/collect-evidence` | JSON (see collect-evidence Output Contract) |
| Existing vault entries | Queried via `knowledge-gate` CLI at runtime | CLI output per cli.md §1 |

## Output Contract

An array of candidate objects. **Zero candidates is a valid and expected result.**

### Candidate Required Schema

Each candidate MUST conform to this schema (derived from design-implementation.md §3.3):

```json
{
  "id": "<kebab-case-identifier>",
  "type": "fact | anti-pattern",
  "title": "<concise descriptive title>",
  "claim": "<MUST or MUST-NOT one-line assertion>",
  "body": "<structured markdown per body template below>",
  "applies_to": {
    "domains": ["<domain1>", "<domain2>"]
  },
  "evidence": [
    { "type": "pr | linear | slack | greptile | memento", "ref": "<reference string>" }
  ],
  "alternative": "<required for anti-pattern, null for fact>",
  "conflict_check": "<existing vault entry ID if potential conflict, null otherwise>",
  "considerations": "<explicit concerns, conditions, or caveats — NEVER empty>"
}
```

### Body Template

The `body` field MUST follow this structure (design-implementation.md §4.3):

```markdown
## Background
[Why this rule exists. Context that led to the decision.]

## Details
[Specific guidance. Implementation notes. Scope boundaries.]

## Rejected Alternatives
[Optional. Approaches that were tried and failed, or considered and dismissed. Required for anti-pattern entries.]

## Open Questions
[Optional. Unresolved aspects. Areas where the rule may evolve.]

## Stop Conditions
[Optional. When this rule should be reconsidered. Trigger for re-evaluation.]
```

### Claim Format

- **Fact**: Starts with a verb in imperative form. E.g., "Use Service Objects for payment transaction orchestration"
- **Anti-Pattern**: Starts with "MUST-NOT" or "Do not". E.g., "MUST-NOT call external APIs from ActiveRecord callbacks"
- Both types: One sentence. Actionable. Specific enough to verify compliance.

## Behavioral Requirements

### Step 1: Derive Target Domains

1. For each file in the Evidence Bundle's root-level `changed_files` array:
   - Run `knowledge-gate domain-resolve-path "<filepath>"`
   - Collect all matched domains
   > **Note:** `domain-resolve-path` 결과에는 전역 도메인(`pattern = '*'`)이 자동 포함된다. 전역 도메인은 도메인 목록에서 제외하지 않으며, 프로젝트 전역 규칙의 적용 범위로 활용한다.
2. If no domains match any file (전역 도메인 외에 매칭이 없는 경우), note this — the candidate's `applies_to.domains` will be proposed as new domains (for the orchestrator to handle via `domain-add`)
3. Deduplicate the domain list

### Step 2: Fetch Existing Vault Entries

1. For each resolved domain, run `knowledge-gate query-domain "<domain>"`
2. Collect all existing active entries for these domains
3. These are needed for:
   - Avoiding duplicate extraction
   - Identifying conflicts
   - Understanding existing coverage

### Step 3: Analyze Evidence for Extractable Knowledge

Read through the Evidence Bundle holistically. Look for:

| Signal | What to extract |
|--------|-----------------|
| Explicit architectural decisions in PR body/comments | Fact |
| "We agreed to..." / "Going forward..." in Linear discussions | Fact |
| Failed approaches documented in PR description | Anti-Pattern |
| Reviewer corrections with agreement ("good catch, fixed") | Fact or Anti-Pattern |
| Post-incident changes with root cause analysis | Anti-Pattern |
| Pattern establishment ("introducing Service Object pattern for...") | Fact |
| Constraint discoveries ("we can't do X because Y") | Fact or Anti-Pattern |

### Step 4: Apply Extraction Criteria

For each potential candidate, verify:

1. **Confirmed decision**: The evidence shows **explicit** team agreement, not just one person's opinion. If no explicit agreement is visible in code review comments, Linear discussions, or PR descriptions, do NOT extract as Fact — regardless of how reasonable the approach appears.
   - PR approved with relevant comments → agreement signal
   - Linear issue with multiple participants reaching conclusion → agreement signal
   - Single developer's commit with no review → weak signal, skip unless post-incident fix
   - Implicit consensus (e.g., "no one objected") → NOT sufficient. Require explicit agreement.

   > **설계 근거 — 보수적 추출 원칙:** "명시적 텍스트 합의만 인정"은 의도적으로 좁은 기준이다. False positive(잘못된 지식이 금고에 진입)의 비용이 false negative(유효한 지식을 놓침)의 비용보다 구조적으로 크기 때문이다. 잘못 진입한 항목은 에이전트의 행동을 잘못된 방향으로 유도하고 발견이 어렵지만, 놓친 지식은 다음 정제 사이클에서 재추출할 수 있다. "놓칠 수 있다"는 FOMO보다 "잘못 넣는다"는 리스크가 이 시스템에서 항상 더 크다.

2. **Not already known**: Compare against existing vault entries from Step 2
   - If semantically identical entry exists → skip (not a candidate)
   - If related but different entry exists → set `conflict_check` to that entry's ID
3. **Actionable**: The knowledge can guide future coding decisions
   - "We chose React" → not actionable for daily coding (too broad)
   - "Use React Server Components for data-fetching pages" → actionable
4. **Not self-evident**: An experienced developer in this codebase couldn't trivially derive it
   - "JavaScript files use .js extension" → self-evident, skip
   - "Payments service must use idempotency keys for all mutations" → not self-evident

### Step 5: Compose Candidates

For each validated extraction:

1. Generate a kebab-case `id` (descriptive, 3-5 words)
2. Set `type` to `fact` or `anti-pattern`
3. Write `claim` as a single imperative sentence
4. Write `body` following the template:
   - **Background**: 2-4 sentences of context from the evidence
   - **Details**: Specific implementation guidance
   - **Rejected Alternatives**: Required for anti-patterns. Cite the failed approach from evidence.
   - **Open Questions**: Only if genuinely unresolved aspects exist in the evidence
   - **Stop Conditions**: Only if the evidence suggests when to revisit
5. Set `applies_to.domains` from Step 1
6. Build `evidence` array citing specific sources:
   - `{ "type": "pr", "ref": "#1234" }`
   - `{ "type": "linear", "ref": "LIN-456" }`
   - `{ "type": "memento", "ref": "a1b2c3d" }` — memento 노트가 없는 것은 정상이다 (git-memento는 optional 의존성). memento 부재 시 다른 증거 타입으로 충분하다.
7. For anti-patterns: write `alternative` describing what to do instead
8. Write `considerations` — the caveats, edge cases, or conditions. NEVER leave empty.
   - Even if no obvious caveats: "None identified from current evidence. Re-evaluate if [condition]."

### Step 6: Return Candidate Array

Return the array of candidates (may be empty). Do not filter — that's the quality gate's job.

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| `knowledge-gate` CLI unavailable | Cannot check existing entries. Proceed without conflict_check (set all to null). Log warning. |
| No domains resolved for any file | Propose domain names based on file paths. Set `applies_to.domains` to proposed names. |
| Evidence Bundle has `insufficient` verdict | Should not reach this step (orchestrator handles). If it does, return empty array. |
| LLM cannot determine confidence in extraction | Do NOT extract. "When in doubt, leave it out." |

## Example Scenarios

### Scenario 1: Service Object Introduction PR

**Evidence**:
- PR #1234 "Introduce PaymentService for transaction orchestration"
- PR body: "Extracted payment logic from controller to service object per team discussion in LIN-456"
- Linear LIN-456: Thread showing team agreement on Service Object pattern
- Review comment: "Great, this matches what we agreed on"
- Changed files: `app/services/payments/charge.rb`, `spec/services/payments/charge_spec.rb`

**Output**: 1 candidate

```json
[{
  "id": "payment-service-object-pattern",
  "type": "fact",
  "title": "Payment transactions use Service Object pattern",
  "claim": "Use Service Objects for payment transaction orchestration, not controller-level logic",
  "body": "## Background\nTeam agreed in LIN-456 to extract payment orchestration into dedicated Service Objects...\n\n## Details\nPayment services live in `app/services/payments/`. Each service handles one transaction type...\n\n## Stop Conditions\nReconsider if payment logic becomes simple enough for inline controller handling.",
  "applies_to": { "domains": ["payment"] },
  "evidence": [
    { "type": "pr", "ref": "#1234" },
    { "type": "linear", "ref": "LIN-456" }
  ],
  "alternative": null,
  "conflict_check": null,
  "considerations": "Applies to payment transaction orchestration. Simple payment queries may not need a Service Object."
}]
```

### Scenario 2: AR Callback Incident Fix

**Evidence**:
- PR #1201 "Fix: Remove Stripe API call from AR callback"
- PR body: "Root cause: ActiveRecord callback called Stripe API, causing cascading timeouts. Moved to async job."
- Memento notes: Session showing debugging of N+1 timeout cascade
- Changed files: `app/models/order.rb`, `app/jobs/stripe_sync_job.rb`

**Output**: 1 candidate

```json
[{
  "id": "no-external-api-in-ar-callbacks",
  "type": "anti-pattern",
  "title": "No external API calls in ActiveRecord callbacks",
  "claim": "MUST-NOT call external APIs from ActiveRecord callbacks",
  "body": "## Background\nProduction incident caused by Stripe API call in Order after_save callback...\n\n## Details\nAR callbacks run within the database transaction scope. External API calls introduce unpredictable latency...\n\n## Rejected Alternatives\nAttempted timeout wrapper around Stripe call — still caused transaction lock contention under load.\n\n## Stop Conditions\nReconsider if Rails introduces native async callback support with transaction isolation.",
  "applies_to": { "domains": ["activerecord", "payment"] },
  "evidence": [
    { "type": "pr", "ref": "#1201" },
    { "type": "memento", "ref": "f8a9b1c" }
  ],
  "alternative": "Move external API calls to async jobs (ActiveJob/Sidekiq) triggered after transaction commit",
  "conflict_check": null,
  "considerations": "Internal service calls within the same database may be acceptable if latency is bounded and idempotent."
}]
```

### Scenario 3: No Extractable Knowledge

**Evidence**:
- PR #789 "Update logging format"
- Simple string format change, no team discussion
- No Linear issues, no memento notes
- Changed files: `lib/logger.rb`

**Output**: Empty array `[]`

This is normal. Not every PR produces knowledge.

## Reference Specifications

- Candidate schema: design-implementation.md §3.3
- Body template: design-implementation.md §4.3
- Guardrails: design-implementation.md §4.4
- Domain derivation: cli.md §6
- CLI commands: cli.md §1-2
- Extraction principle ("don't force lessons"): tool-evaluation.md (claude-memory-extractor reference)

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

## Validation Checklist

1. Does each candidate have a kebab-case `id`?
2. Does each `claim` follow the imperative/MUST-NOT format?
3. Does each `body` follow the template structure?
4. Does every anti-pattern have a non-null `alternative`?
5. Is `considerations` non-empty for every candidate?
6. Does every candidate cite at least one `evidence` source?
7. Are domains derived via `domain-resolve-path`, not hardcoded?
8. Does the skill return `[]` gracefully when no candidates are found?
