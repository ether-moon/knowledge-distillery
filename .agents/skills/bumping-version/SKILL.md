---
name: bumping-version
description: Inspects, previews, prepares, and direct-pushes approved semantic-version Git commits with consistent manifests and policy-driven changelog updates. Use when the user asks to bump a version, choose patch/minor/major, prepare a release commit, reconcile a release operation, or push an approved version commit to a base branch. Do not use for package-registry publishing, deployment, or tagging an already-versioned commit.
---

# Bumping Version

Resolve `scripts/release-workflow` relative to the directory containing this `SKILL.md` and invoke that absolute path directly for all inspection and mutation. Do not depend on a host-specific plugin-root environment variable or a shell variable persisting across tool calls. The examples use `<release-runner>` as a non-executable placeholder; replace it with the resolved absolute path in every invocation. The runner reads one immutable base snapshot, isolates preparation from the user's checkout, binds preparation to an accepted preview, and requires separate approval before publication.

## Dependencies and policy

The runner preflights Bash 3.2 or newer, `git`, `gh`, and `jq`. Report `MISSING_DEPENDENCY` and stop.

It reads the committed `## Versioning` policy from `AGENTS.md` in the base snapshot:

- `Base branch`
- `Commit message`, with a `{version}` placeholder
- `Extra version files`, as comma-separated repository-relative paths
- `Changelog categories`, defaulting to `Added, Improved, Fixed`

Supported manifests include Claude plugin and package JSON, `pyproject.toml`, `Cargo.toml`, Python `__version__`, gemspecs, Ruby `VERSION`, root `VERSION` and `version.txt`, plus configured extra files.

## Workflow

### 1. Inspect the immutable base

Run:

```bash
<release-runner> inspect --repo .
```

Pass `--base BRANCH` only when the user selected a base. With `origin`, the runner resolves and fetches its latest exact base SHA. Without `origin`, it uses the committed local base. Dirty files and other local branches never supply release input.

Report `base`, `base_sha`, manifests, mismatches, changelog status, policy, and `recent_commits`. Stop on mismatch, unsupported versions, missing manifests, or missing `CHANGELOG.md`; never choose a source of truth silently.

### 2. Preview

Recommend a semantic-version level from the inspected commits and ask the user to choose `patch`, `minor`, or `major`. A generic release request is not approval.

Run the selected dry preview:

```bash
<release-runner> prepare --repo . --level patch --dry-run
```

Preserve an explicit `--base`. For a user-provided changelog entry or commit message, add `--changelog-file PATH` or `--message-file PATH` to both preview and prepare. Relative paths are resolved from the caller directory; the runner owns immutable copies during preparation.

Show `base_sha`, `version`, `changed_paths`, `changelog_entry`, `changelog_categories`, and `commit_message`. Retain `base_sha` and `input_digest` exactly; together they identify the accepted preview.

### 3. Prepare with compare-and-swap

After the user accepts the preview, run the same arguments without `--dry-run` and add both preview values:

```bash
<release-runner> prepare --repo . --level patch \
  --expected-base-sha BASE_SHA \
  --expected-input-digest INPUT_DIGEST
```

The runner stops before creating a worktree if the remote base, policy, manifests, date, or managed input changed. Otherwise it creates an external temporary worktree and local `release-workflow/release-v...` branch, updates every discovered manifest plus `CHANGELOG.md`, stages only those paths, commits once, and verifies the final commit scope after hooks.

Present `base`, `base_sha`, `version`, `commit_sha`, `changed_paths`, and the complete `diff`. Preserve `state_file` and `commit_sha` as publication inputs.

### 4. Ask for publication approval

Ask one explicit question in the user's language:

```text
Push prepared commit COMMIT_SHA directly to origin/BASE now?
```

If declined, keep the commit and branch but remove the worktree:

```bash
<release-runner> cleanup --state-file STATE_FILE --mode declined
```

### 5. Publish and clean up

Only after an affirmative answer, run:

```bash
<release-runner> publish --state-file STATE_FILE \
  --expected-commit COMMIT_SHA --approve
```

The runner verifies state, origin identity, and remote base SHA before a normal direct push. It never force-pushes or creates a pull request fallback.

On success:

```bash
<release-runner> cleanup --state-file STATE_FILE --mode success
```

On authentication, protection, or base-race failure, preserve both recovery artifacts:

```bash
<release-runner> cleanup --state-file STATE_FILE --mode failure
```

If publication or cleanup completed externally but state persistence failed, retry the same command. The runner reconciles an exact remote commit and already-removed exact worktree or branch idempotently.

If the user later requests a pull request, treat that as a new pull-request workflow; do not initiate it here or require another plugin.

## Errors

Failures are JSON on stderr with `error.code`, `error.message`, and `error.recovery`.

- `BASE_RACE`, `INPUT_CHANGED`: discard the old preview and run a new dry preview.
- `VERSION_MISMATCH`, `CHANGELOG_MISSING`: resolve repository content before retrying.
- `APPROVAL_REQUIRED`: ask the user; never add approval yourself.
- `COMMIT_SCOPE_MISMATCH`, `POST_COMMIT_WORKTREE_DIRTY`: preserve and inspect the isolated branch and worktree.
- `PUSH_AUTH_FAILED`, `PUSH_PROTECTED`, `PUSH_FAILED`: report recovery paths and stop.
- `STATE_WRITE_FAILED`: restore state-directory writes, then retry the exact publish or cleanup command.

Use the user's language for recommendations, approval prompts, errors, and reports. Keep arguments, paths, branch names, and JSON fields unchanged.
