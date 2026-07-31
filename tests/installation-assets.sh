#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_ROOT="${ROOT}/plugins/knowledge-distillery/install"
HOOK_ROOT="${INSTALL_ROOT}/hooks"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_file() {
  local path="$1"
  local message="$2"
  if [ ! -f "$path" ]; then
    fail "${message}: missing ${path}"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${message}: missing '${needle}'"
  fi
}

for hook_name in \
  pre-prompt-knowledge-gate.sh \
  pre-commit-memento.sh \
  post-commit-memento.sh
do
  assert_file "${HOOK_ROOT}/${hook_name}" "installation should publish ${hook_name}"
  bash -n "${HOOK_ROOT}/${hook_name}"
done

assert_file "${HOOK_ROOT}/codex-hooks.json" "installation should publish the Codex hook fragment"
assert_file "${HOOK_ROOT}/claude-settings.json" "installation should publish the Claude Code settings fragment"
jq -e '(.hooks.UserPromptSubmit | length == 1) and (.hooks.PreToolUse | length == 1) and (.hooks.PostToolUse | length == 1)' \
  "${HOOK_ROOT}/codex-hooks.json" >/dev/null
jq -e '(.hooks.UserPromptSubmit | length == 1) and (.hooks.PreToolUse | length == 1) and (.hooks.PostToolUse | length == 1)' \
  "${HOOK_ROOT}/claude-settings.json" >/dev/null
jq -e '.permissions.allow | index("Bash(*/knowledge-gate:*)") and index("Bash(sqlite3 .knowledge/vault.db:*)")' \
  "${HOOK_ROOT}/claude-settings.json" >/dev/null

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_DIR="${TMP_DIR}/repo"
git -C "${TMP_DIR}" init -q repo
mkdir -p "${REPO_DIR}/.codex/hooks" "${REPO_DIR}/.agents/skills"
cp "${HOOK_ROOT}/pre-prompt-knowledge-gate.sh" "${REPO_DIR}/.codex/hooks/"
cp -R \
  "${ROOT}/plugins/knowledge-distillery/skills/knowledge-gate" \
  "${REPO_DIR}/.agents/skills/knowledge-gate"

PROJECT_GATE="${REPO_DIR}/.agents/skills/knowledge-gate/scripts/knowledge-gate"
export KNOWLEDGE_VAULT_PATH="${REPO_DIR}/.knowledge/vault.db"
"${PROJECT_GATE}" init-db >/dev/null
"${PROJECT_GATE}" domain-add global "Global rules" >/dev/null
"${PROJECT_GATE}" domain-paths-set global "*" >/dev/null
"${PROJECT_GATE}" add \
  --type fact \
  --title "Hook Path Rule" \
  --claim "Use the exact project-local CLI path supplied by the hook." \
  --body "## Background\nThe README installs runtime skills at project scope.\n\n## Details\nThe hook resolves the installed project skill path." \
  --domain global \
  --considerations "Re-run the Agent Installation Guide after moving the installation." \
  --evidence "pr:#40" >/dev/null
unset KNOWLEDGE_VAULT_PATH

hook_output="$(
  cd "${REPO_DIR}"
  printf '%s\n' '{"hook_event_name":"UserPromptSubmit"}' \
    | bash "${REPO_DIR}/.codex/hooks/pre-prompt-knowledge-gate.sh"
)"

assert_contains "${hook_output}" "${PROJECT_GATE}" \
  "prompt hook should supply the exact project-installed CLI path"
assert_contains "${hook_output}" '"hookSpecificOutput"' \
  "prompt hook should emit Codex-compatible additional context"

commit_guard_output="$(
  printf '%s\n' '{"tool_input":{"command":"git commit -m test"}}' \
    | bash "${HOOK_ROOT}/pre-commit-memento.sh"
)"
assert_contains "${commit_guard_output}" 'installed memento-commit skill' \
  "commit guard should redirect portable installations without a plugin namespace"

echo "installation asset tests passed"
