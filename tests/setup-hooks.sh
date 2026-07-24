#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="${ROOT}/plugins/knowledge-distillery/skills/setup/scripts/install-hooks"

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

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$expected" != "$actual" ]; then
    fail "${message}: expected '${expected}', got '${actual}'"
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

assert_file "${INSTALLER}" "setup skill should bundle the hook installer"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_DIR="${TMP_DIR}/repo"
mkdir -p "${REPO_DIR}/.codex" "${REPO_DIR}/.claude"
git -C "${TMP_DIR}" init -q repo

cat > "${REPO_DIR}/.codex/hooks.json" <<'JSON'
{
  "description": "Keep this existing Codex hook config.",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo existing-codex-hook"
          }
        ]
      }
    ]
  }
}
JSON

cat > "${REPO_DIR}/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(existing:*)"
    ]
  }
}
JSON

"${INSTALLER}" codex "${REPO_DIR}"
"${INSTALLER}" codex "${REPO_DIR}"

assert_file "${REPO_DIR}/.codex/hooks/pre-prompt-knowledge-gate.sh" "Codex prompt hook should be installed"
assert_file "${REPO_DIR}/.codex/hooks/pre-commit-memento.sh" "Codex pre-commit hook should be installed"
assert_file "${REPO_DIR}/.codex/hooks/post-commit-memento.sh" "Codex post-commit hook should be installed"
assert_eq "Keep this existing Codex hook config." \
  "$(jq -r '.description' "${REPO_DIR}/.codex/hooks.json")" \
  "Codex hook installation should preserve existing config"
assert_eq "1" \
  "$(jq '[.hooks.Stop[].hooks[] | select(.command == "echo existing-codex-hook")] | length' "${REPO_DIR}/.codex/hooks.json")" \
  "Codex hook installation should preserve existing hooks"
assert_eq "1" \
  "$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("pre-prompt-knowledge-gate.sh"))] | length' "${REPO_DIR}/.codex/hooks.json")" \
  "Codex prompt hook installation should be idempotent"
assert_eq "1" \
  "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | contains("pre-commit-memento.sh"))] | length' "${REPO_DIR}/.codex/hooks.json")" \
  "Codex pre-tool hook installation should be idempotent"
assert_eq "1" \
  "$(jq '[.hooks.PostToolUse[].hooks[] | select(.command | contains("post-commit-memento.sh"))] | length' "${REPO_DIR}/.codex/hooks.json")" \
  "Codex post-tool hook installation should be idempotent"

"${INSTALLER}" claude-code "${REPO_DIR}"
"${INSTALLER}" claude-code "${REPO_DIR}"

assert_file "${REPO_DIR}/.claude/hooks/pre-prompt-knowledge-gate.sh" "Claude Code prompt hook should be installed"
assert_file "${REPO_DIR}/.claude/hooks/pre-commit-memento.sh" "Claude Code pre-commit hook should be installed"
assert_file "${REPO_DIR}/.claude/hooks/post-commit-memento.sh" "Claude Code post-commit hook should be installed"
assert_eq "Bash(existing:*)" \
  "$(jq -r '.permissions.allow[0]' "${REPO_DIR}/.claude/settings.json")" \
  "Claude Code hook installation should preserve existing settings"
assert_eq "1" \
  "$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("pre-prompt-knowledge-gate.sh"))] | length' "${REPO_DIR}/.claude/settings.json")" \
  "Claude Code prompt hook installation should be idempotent"
assert_eq "1" \
  "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | contains("pre-commit-memento.sh"))] | length' "${REPO_DIR}/.claude/settings.json")" \
  "Claude Code pre-tool hook installation should be idempotent"
assert_eq "1" \
  "$(jq '[.hooks.PostToolUse[].hooks[] | select(.command | contains("post-commit-memento.sh"))] | length' "${REPO_DIR}/.claude/settings.json")" \
  "Claude Code post-tool hook installation should be idempotent"

mkdir -p "${REPO_DIR}/.agents/skills"
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
  --claim "Use the exact CLI path supplied by the hook." \
  --body "## Background\nStandalone skill installs have no plugin root.\n\n## Details\nThe hook resolves the installed skill path." \
  --domain global \
  --considerations "Re-resolve after moving the installation." \
  --evidence "pr:#40" >/dev/null
unset KNOWLEDGE_VAULT_PATH

mkdir -p "${REPO_DIR}/src"
hook_output="$(
  cd "${REPO_DIR}/src"
  printf '%s\n' '{"hook_event_name":"UserPromptSubmit","cwd":"'"${REPO_DIR}"'/src"}' \
    | bash "${REPO_DIR}/.codex/hooks/pre-prompt-knowledge-gate.sh"
)"

assert_contains "${hook_output}" "${PROJECT_GATE}" \
  "prompt hook should supply the exact project-installed CLI path"
assert_contains "${hook_output}" '"hookSpecificOutput"' \
  "prompt hook should emit Codex-compatible additional context"

CACHE_REPO="${TMP_DIR}/cache-repo"
CODEX_CACHE="${TMP_DIR}/codex-home"
git -C "${TMP_DIR}" init -q cache-repo
mkdir -p "${CODEX_CACHE}/skills"
cp -R \
  "${ROOT}/plugins/knowledge-distillery/skills/knowledge-gate" \
  "${CODEX_CACHE}/skills/knowledge-gate"

"${INSTALLER}" codex "${CACHE_REPO}" >/dev/null

CACHE_GATE="${CODEX_CACHE}/skills/knowledge-gate/scripts/knowledge-gate"
export KNOWLEDGE_VAULT_PATH="${CACHE_REPO}/.knowledge/vault.db"
"${CACHE_GATE}" init-db >/dev/null
"${CACHE_GATE}" domain-add global "Global rules" >/dev/null
"${CACHE_GATE}" domain-paths-set global "*" >/dev/null
"${CACHE_GATE}" add \
  --type fact \
  --title "Cache Path Rule" \
  --claim "Resolve the CLI from CODEX_HOME when no project skill exists." \
  --body "## Background\nGlobal Codex installs live outside the repository.\n\n## Details\nThe hook checks the configured Codex home." \
  --domain global \
  --considerations "Prefer a project install when both exist." \
  --evidence "pr:#40" >/dev/null
unset KNOWLEDGE_VAULT_PATH

cache_hook_output="$(
  cd "${CACHE_REPO}"
  printf '%s\n' '{"hook_event_name":"UserPromptSubmit","cwd":"'"${CACHE_REPO}"'"}' \
    | CODEX_HOME="${CODEX_CACHE}" bash "${CACHE_REPO}/.codex/hooks/pre-prompt-knowledge-gate.sh"
)"

assert_contains "${cache_hook_output}" "${CACHE_GATE}" \
  "prompt hook should resolve a global CLI from CODEX_HOME"

echo "setup hook installation tests passed"
