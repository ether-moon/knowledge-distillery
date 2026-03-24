---
name: memento-summary
description: "Generates a structured session summary for git notes on refs/notes/commits. Extracts decisions, problems, constraints, and open questions from an AI coding session transcript for use as evidence in the Knowledge Distillery refinement pipeline. Use when generating a memento summary for a commit, or when the post-commit hook requests a session summary."
---

# memento-summary

Produce a structured summary of the current AI coding session. This summary is stored as a git note on `refs/notes/commits` (via memento-commit skill or directly) and later consumed by the Knowledge Distillery refinement pipeline as evidence.

## Output Structure

The summary MUST follow this exact 5-section markdown structure. All five sections are required. Use "None" as the single item for any empty section.

```markdown
## Decisions Made
- [Decision]: [Rationale]

## Problems Encountered
- [Problem]: [How it was resolved or current status]

## Constraints Identified
- [Constraint]: [Why it matters]

## Open Questions
- [Question]: [Context]

## Context
[Brief paragraph: what was being done and why, key files involved, outcome]
```

## Extraction Rules

### Decisions Made

Scan for confirmed choices only:

- Explicit selections ("Use X instead of Y", "Go with approach A")
- Implicit decisions (choosing one implementation path over alternatives)
- Architecture and design selections
- Library, tool, or pattern selections

For each decision, capture:
- What was decided
- Why (rationale from the session)
- Evidence if available (code, tests, documentation, conversation references)

**MUST-NOT decisions** (things explicitly rejected) must always include the alternative that was chosen instead.

**Do NOT include** exploration steps, abandoned experiments, or intermediate reasoning that did not result in a confirmed decision.

### Problems Encountered

Scan for issues that were actively worked on:

- Errors encountered and debugged
- Unexpected behaviors investigated
- Failed approaches before finding a solution
- Performance issues identified

For each problem, capture:
- What the problem was
- How it was resolved, or "Unresolved" if still open

### Constraints Identified

Scan for limitations and boundaries discovered:

- Limitations found ("we can't do X because Y")
- API or framework restrictions hit
- Performance boundaries identified
- Compatibility requirements discovered
- User-specified requirements or restrictions

For each constraint, capture:
- What the constraint is
- Why it matters for future work
- Applicability conditions or exceptions, if any

### Open Questions

Scan for unresolved items:

- Explicitly deferred decisions ("we'll figure this out later")
- Uncertainties mentioned but not resolved
- TODO items noted during the session
- Areas flagged for review

### Context

Write a 2-4 sentence paragraph covering:

- What the session was about (high-level goal)
- Key files and modules involved
- Outcome (completed, partial, or blocked)

## Formatting Rules

- Each section item is a single bullet point -- concise, 1-2 sentences max.
- Aim for 3-7 items per section for a typical 30-minute session. Longer sessions may have more. Very short sessions may have 1-2.
- Write in the language primarily used during the session.
- Do NOT include raw code blocks from the session transcript.
- Do NOT include sensitive information (API keys, credentials, PII).
- Focus on information useful for knowledge distillation: decisions, constraints, problems -- not step-by-step implementation details.

## Error Handling

| Situation | Response |
|-----------|----------|
| Transcript is empty or trivially short | Return minimal summary with Context noting "Minimal session -- no significant activity captured" |
| No decisions identifiable | "Decisions Made" section contains "None -- session focused on exploration/debugging" |
| Transcript appears corrupted | Return summary with Context noting the issue. Always produce output. |
| Session was purely conversational (no code changes) | Still summarize -- decisions and context from conversations are valuable evidence |

## Examples

### Feature implementation session

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

### Debugging session

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

### Minimal session

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
