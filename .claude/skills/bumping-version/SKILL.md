---
name: bumping-version
description: Bump the knowledge-distillery plugin version with changelog update. Use when user asks to bump, version up, or release.
---

# Bumping Version

Bump the knowledge-distillery plugin version: analyze changes, suggest semver level, get user confirmation, update files, commit, and push.

## Files

- **Version**: `plugins/knowledge-distillery/.claude-plugin/plugin.json` → `"version"` field
- **Changelog**: `CHANGELOG.md` → prepend new entry at top (after header)

## Workflow

### 1. Analyze changes since last bump

```bash
# Find the last bump commit
LAST_BUMP=$(git log --oneline --grep="bump version" -1 --format="%H")
# Show commits since then
git log --oneline "$LAST_BUMP"..HEAD
```

### 2. Suggest semver level

Based on the commits, suggest one of:
- **patch**: Bug fixes, refactors, agent/skill improvements
- **minor**: New skills, new commands, new features
- **major**: Breaking changes to existing skill interfaces

Present the suggestion with rationale, then ask the user to choose:

```
[In user's language]

Changes since last bump:
- [commit summary 1]
- [commit summary 2]

Suggested: patch (reason)

Which level?
- [1] patch
- [2] minor
- [3] major
```

### 3. Update files

**Read current version** from `plugins/knowledge-distillery/.claude-plugin/plugin.json`.

**Increment** the chosen semver component (reset lower components to 0 for minor/major).

**Update plugin.json**: Change `"version"` value.

**Update CHANGELOG.md**: Add new entry after the header block, before the first existing version entry. Follow the existing format:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added/Improved/Fixed

- **component**: Description of change
```

Use the appropriate changelog category:
- `Added` for new features/skills
- `Improved` for enhancements/refactors
- `Fixed` for bug fixes

### 4. Commit and push

```bash
git add CHANGELOG.md plugins/knowledge-distillery/.claude-plugin/plugin.json
git commit -m "chore: bump version to X.Y.Z"
git push origin HEAD:main
```

## Rules

- Always create a **separate commit** for the bump (no mixing with feature commits)
- Push directly to `origin/main`
- Use today's date for the changelog entry
- Keep changelog entries concise (one line per change)
