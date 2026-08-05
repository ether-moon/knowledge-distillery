# Decision: README replaces the setup skill

**Decision**: Use the root README as the executable installation contract for an LLM, and install only the four persistent runtime skills into adopting repositories at project scope.

**Context**: The initial selective-installation direction still included `setup` as a project-local skill. The installation agent can instead perform repository initialization directly from a complete README procedure while `npx skills` installs only capabilities needed during normal repository work.

**Rationale**: Setup is a one-time or occasional convergence workflow, not a persistent runtime capability. Keeping its procedure in the root README removes an unnecessary installed skill, makes the installation contract visible before installation, and leaves only `knowledge-gate`, `memento-commit`, `memento-summary`, and `record-decision` in the adopting repository's skill catalog.

**Alternatives considered**:
- **Retain a minimal setup skill**: Rejected because it duplicates the README installation contract and remains installed after its work is complete.

**Supersedes**: `2026-07-31-llm-led-selective-installation`
