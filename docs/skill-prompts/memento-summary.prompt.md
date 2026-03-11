# Memento Summary — Skill Creation Prompt

## Purpose

Generate a skill file compatible with git-memento's `--summary-skill` parameter. When git-memento captures an AI coding session transcript, it runs this skill to produce a structured summary stored in `refs/notes/commits`. The summary is later consumed by `/collect-evidence` as part of the Evidence Bundle.

## Pipeline Position

- **Trigger**: git-memento session end (automatic, via `--summary-skill` configuration)
- **Depends on**: Raw AI session transcript (provided by git-memento)
- **Produces**: Structured summary stored as git note on the commit
- **Consumed by**: `/collect-evidence` (reads memento notes as optional evidence)

## Prerequisites

### Runtime Environment
- git-memento installed and configured
- git repository with `refs/notes/commits` configured
- LLM access (git-memento invokes the skill as an LLM prompt)

### Allowed Tools
- None directly — this skill runs as a prompt within git-memento's LLM invocation
- git-memento handles the `git notes add` operation

## Input Contract

| Field | Source | Format |
|-------|--------|--------|
| Session transcript | git-memento runtime | Full AI coding session text (tool calls, responses, user messages) |
| Commit SHA | git-memento runtime | The commit being annotated |
| Changed files | git-memento runtime (or derivable from commit) | List of files modified in the commit |

The skill receives the transcript as its primary input context.

## Output Contract

A structured markdown summary that git-memento stores as a git note. The summary MUST follow this structure (derived from design-implementation.md §2.5 appendix):

```markdown
## Decisions Made
- [Decision 1]: [Rationale]
- [Decision 2]: [Rationale]

## Problems Encountered
- [Problem 1]: [How it was resolved or current status]
- [Problem 2]: [How it was resolved or current status]

## Constraints Identified
- [Constraint 1]: [Why it matters]
- [Constraint 2]: [Why it matters]

## Open Questions
- [Question 1]: [Context]
- [Question 2]: [Context]

## Context
[Brief paragraph: what was being done and why, key files involved]
```

All sections are required. Empty sections use "None" as the single item.

## Behavioral Requirements

### Step 1: Scan for Decisions

Read the transcript for:
- Explicit choices ("I'll use X instead of Y", "Let's go with approach A")
- Implicit decisions (choosing one implementation over alternatives)
- Architecture/design selections
- Library/tool selections

For each decision, extract:
- What was decided
- Why (rationale from the transcript)

### Step 2: Scan for Problems

Read the transcript for:
- Errors encountered and debugged
- Unexpected behaviors investigated
- Failed approaches before finding a solution
- Performance issues identified

For each problem, extract:
- What the problem was
- How it was resolved (or "Unresolved" if still open)

### Step 3: Scan for Constraints

Read the transcript for:
- Limitations discovered ("we can't do X because Y")
- API/framework restrictions hit
- Performance boundaries identified
- Compatibility requirements discovered

For each constraint, extract:
- What the constraint is
- Why it matters for future work

### Step 4: Scan for Open Questions

Read the transcript for:
- Explicitly deferred decisions ("we'll figure this out later")
- Uncertainties mentioned but not resolved
- TODO items noted
- Areas flagged for review

### Step 5: Compose Context Section

Write a 2-4 sentence paragraph covering:
- What the session was about (high-level goal)
- Key files/modules involved
- Outcome (completed, partial, blocked)

### Step 6: Format and Return

Compose the full markdown summary following the output structure. Each section item is a single bullet point — concise, not exhaustive.

**Density guideline**: Aim for 3-7 items per section for a typical 30-minute session. Longer sessions may have more. Very short sessions may have 1-2 items per section.

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| Transcript is empty or trivially short | Return minimal summary with Context noting "Minimal session — no significant activity captured" |
| No decisions identifiable | "Decisions Made" section contains "None — session focused on exploration/debugging" |
| Transcript appears corrupted | Return summary with Context noting the issue. Do not fail — git-memento expects output. |
| Session was purely conversational (no code changes) | Still summarize — decisions and context from conversations are valuable evidence |

## Example Scenarios

### Scenario 1: Feature Implementation Session

**Input**: 45-minute session implementing payment retry logic

**Output**:
```markdown
## Decisions Made
- Use exponential backoff for payment retries: Prevents thundering herd on payment provider
- Set max retry count to 3: Balances reliability with user experience (>3 retries = likely permanent failure)
- Store retry state in Redis, not DB: Avoids transaction overhead for transient state

## Problems Encountered
- Stripe webhook race condition with retry attempts: Resolved by adding idempotency key check before processing
- Test flakiness with time-dependent retry logic: Resolved by injecting clock dependency

## Constraints Identified
- Stripe API rate limit of 100 req/sec: Must implement client-side throttling for batch retry scenarios
- Payment service timeout set to 30s in production: Retry backoff intervals must fit within overall request timeout

## Open Questions
- Should failed retries trigger an alert?: Deferred to ops team discussion
- Retry behavior for partial refunds: Not covered in this session, needs specification

## Context
Implemented payment retry logic in PaymentService with exponential backoff. Key files: app/services/payment_service.rb, app/jobs/payment_retry_job.rb, spec/services/payment_service_spec.rb. Feature complete with tests passing.
```

### Scenario 2: Debugging Session

**Input**: 20-minute session fixing a production N+1 query

**Output**:
```markdown
## Decisions Made
- Use `includes(:line_items)` instead of `joins`: Avoids duplicate records in result set
- Add database index on orders.user_id: Query plan showed sequential scan

## Problems Encountered
- N+1 query in OrdersController#index causing 200+ queries per page load: Resolved with eager loading
- Initial fix with `joins` caused duplicate orders in pagination: Switched to `includes`

## Constraints Identified
- Cannot use `select` optimization due to downstream serializer requiring full association objects

## Open Questions
- None

## Context
Fixed N+1 query performance issue in orders listing endpoint. Key files: app/controllers/orders_controller.rb, db/migrate/add_user_id_index_to_orders.rb. Performance improved from ~200 queries to 3 queries per page load.
```

### Scenario 3: Minimal/Trivial Session

**Input**: 5-minute session fixing a typo

**Output**:
```markdown
## Decisions Made
- None

## Problems Encountered
- None

## Constraints Identified
- None

## Open Questions
- None

## Context
Fixed typo in README.md documentation. Minimal session with no significant technical decisions.
```

## Reference Specifications

- git-memento summary skill interface: design-implementation.md §2.5
- Summary structure (appendix): design-implementation.md §2.5
- Memento notes as evidence source: design-implementation.md §3.2
- git notes refs: `refs/notes/commits` (summary), `refs/notes/memento-full-audit` (full transcript)

## Constraints

- MUST output valid markdown following the exact section structure
- MUST include all five sections (use "None" for empty sections)
- MUST NOT include raw code blocks from the transcript (summaries only)
- MUST NOT include sensitive information (API keys, credentials, PII)
- MUST keep each bullet point concise (1-2 sentences max)
- MUST always produce output — never fail silently (git-memento expects a response)
- MUST focus on information useful for knowledge distillation (decisions, constraints, problems — not implementation details)

## Validation Checklist

1. Does the output follow the exact 5-section markdown structure?
2. Are all sections present (even if containing "None")?
3. Does each decision include rationale?
4. Does each problem include resolution status?
5. Does each constraint explain why it matters?
6. Is the Context section a brief paragraph (not bullets)?
7. Does the skill handle empty/trivial sessions gracefully?
8. Is the output compatible with git-memento's `--summary-skill` interface?
