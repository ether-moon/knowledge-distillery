# Decision: LLM-led selective installation

**Decision**: Make the repository README the LLM-readable installation entry point and install only the Knowledge Distillery skills required by the adopting repository instead of installing every portable skill.

**Context**: The portable Codex instructions currently use `--skill '*'`, which copies pipeline-internal skills into each adopting repository even though GitHub Actions load the complete plugin independently. Installation should let an agent inspect the repository's intended capabilities and select the smallest project-local skill set.

**Rationale**: A README contract can explain dependency groups and let the active LLM adapt installation to the target host without another bootstrap script. Keeping project-local skills minimal reduces agent catalog noise and avoids coupling ordinary repository work to pipeline-only implementation skills.

**Alternatives considered**:
- **Install every portable skill**: Rejected because most adopting repositories need only setup, vault access, and local commit/decision capture; pipeline workflows fetch their own plugin checkout.
