# Changelog

## [0.2.3] - 2026-04-06

### Improved

- **pipeline**: Parallelize per-PR subagent execution in batch-refine with concurrency cap (10) and deterministic ordering

### Fixed

- **pipeline**: Harden manifest parsing and block direct vault writes on batch branches
- **skill**: Avoid shell-expansion approval prompts in memento-commit and knowledge-gate command guidance

## [0.2.2] - 2026-04-06

### Fixed

- **skill**: Avoid shell-expansion approval prompts in memento-commit and knowledge-gate command guidance

## [0.2.1] - 2026-04-01

### Improved

- **skill**: Decision records support optional `Alternatives considered` and `Supersedes` fields for richer evidence extraction
- **skill**: Core heredoc template separated from optional sections to prevent accidental inclusion

### Fixed

- **workflow**: Apply-changeset saves before rebase to prevent data loss

## [0.2.0] - 2026-03-31

### Added

- **skill**: Unified `/knowledge-distillery:setup` skill — replaces init, handles both initial setup and plugin updates
- **skill**: Inline verification checks in setup skill (vault health, workflow presence, directive sections)
- **cli**: Progressive disclosure with `query-domain`, `query-paths` returning summary indexes; `get`/`get-many` for full details
- **cli**: `domain-report` command for domain health analysis (split/merge candidates, orphans, broad patterns)
- **pipeline**: Vault usage tracking via `tmp/vault-refs.jsonl` and memento 7-section format

### Improved

- **skill**: Setup skill always overwrites workflow templates — plugin updates propagate automatically
- **workflow**: All workflow templates synced to latest (checkout@v6, conditional masking, `--allowedTools`, `show_full_output`)
- **skill**: Eliminated command substitution from all skill Bash templates for Claude Code compatibility
- **pipeline**: Quality-gate R6 uses vault feedback signals for conflict vs duplicate classification

### Fixed

- **workflow**: Apply-changeset date extraction uses BASH_REMATCH for suffixed branch names
- **workflow**: Hardened workflow templates against injection and unauthorized access
- **skill**: Curate-report uses skip output pattern instead of `core.setFailed`

### Removed

- **cli**: `doctor` command — replaced by setup skill's inline verification

## [0.1.4] - 2026-03-30

### Added

- **pipeline**: Vault usage tracking via `tmp/vault-refs.jsonl` — records which vault entries influenced session decisions
- **pipeline**: Memento 7-section format — adds Recorded Decisions and Vault Entries Referenced sections
- **pipeline**: Vault feedback flow through collect-evidence → extract-candidates → quality-gate → batch-refine
- **workflow**: Batch artifact cleanup step in apply-changeset workflow

### Improved

- **cli**: Doctor checks for outdated project configurations (tmp/ gitignore, BASH_REMATCH date extraction, cleanup step)
- **skill**: Quality-gate R6 uses vault feedback signals to inform conflict vs duplicate classification
- **skill**: Init template synced with latest workflow fixes (BASH_REMATCH, cleanup step, tmp/ gitignore)

### Fixed

- **workflow**: Apply-changeset date extraction uses BASH_REMATCH to handle suffixed branch names correctly
- **workflow**: Apply-changeset cleanup push race condition mitigated with git pull --rebase
- **skill**: Hardened workflow templates against injection and unauthorized access

## [0.1.3] - 2026-03-27

### Fixed

- **hook**: Fix plugin hook load error by removing explicit `hooks` manifest reference (convention-based auto-load)

## [0.1.2] - 2026-03-26

### Added

- **test**: Add shell/jq regression harnesses for knowledge-gate, batch-refine, and curate-report
- **workflow**: Add CI workflow for running the local regression harness stack on PRs and pushes to main

### Fixed

- **test**: Harden skill orchestration harness validation for malformed checks and ordered-match failures under strict shell options

## [0.1.1] - 2026-03-24

### Added

- **skill**: Add record-decision skill for auto-capturing project decisions (#11)
- **skill**: Add memento-commit skill and PostToolUse hook for automatic session notes
- **hook**: Add UserPromptSubmit hook for Knowledge Vault query reminder (#14)
- **workflow**: Add Report PR curation via /curate comment command (#10)

### Improved

- **pipeline**: Replace vault.db binary commits with changeset flow (#17)
- **hook**: Replace PostToolUse memento reminder with PreToolUse commit blocker (#15)
- **skill**: Improve all plugin skills: frontmatter, descriptions, and safety fixes (#13)
- **pipeline**: Skip mark-evidence for pipeline-generated batch PRs (#18)

### Fixed

- **workflow**: Fix curate-report workflow to skip instead of fail on guard conditions (#16)
- **workflow**: Fix Node.js 20 deprecation and empty secret mask in workflows (#8)

## [0.1.0] - 2026-03-17

Initial release.
