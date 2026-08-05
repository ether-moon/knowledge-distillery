# Decision: Link the agent installation contract

**Decision**: Keep the executable LLM installation contract in a dedicated repository document and expose it through a short link and prompt in the root README.

**Context**: The root README draft contained the complete installation procedure after the setup skill was removed. Users need both entry paths: they may give an agent the repository README, or provide the installation document URL directly.

**Rationale**: A dedicated document keeps the README concise while preserving a single complete source of truth for project-scoped skill installation, repository configuration, and verification. Both entry paths resolve to the same instructions, so they cannot drift into different setup behavior.

**Alternatives considered**:
- **Inline the full contract in README**: Rejected because the operational detail dominates the project overview and makes the installation procedure harder to reference directly.

**Supersedes**: `2026-07-31-readme-replaces-setup-skill`
