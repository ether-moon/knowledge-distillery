#!/bin/bash
set -euo pipefail

# Installed UserPromptSubmit hook: remind agent to query Knowledge Vault before planning.
# Fires on every user prompt — exits fast when vault is absent.

resolve_cli_path() {
  local repo_root=""
  local candidate
  local candidates=()

  if [ -n "${KNOWLEDGE_GATE_CLI:-}" ]; then
    candidates+=("${KNOWLEDGE_GATE_CLI}")
  fi

  if command -v git >/dev/null 2>&1; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi

  if [ -n "$repo_root" ]; then
    candidates+=(
      "${repo_root}/.agents/skills/knowledge-gate/scripts/knowledge-gate"
      "${repo_root}/.codex/skills/knowledge-gate/scripts/knowledge-gate"
      "${repo_root}/.claude/skills/knowledge-gate/scripts/knowledge-gate"
      "${repo_root}/plugins/knowledge-distillery/skills/knowledge-gate/scripts/knowledge-gate"
    )
  fi

  if [ -n "${PLUGIN_ROOT:-}" ]; then
    candidates+=("${PLUGIN_ROOT}/skills/knowledge-gate/scripts/knowledge-gate")
  fi

  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    candidates+=("${CLAUDE_PLUGIN_ROOT}/skills/knowledge-gate/scripts/knowledge-gate")
  fi

  if [ -n "${CODEX_HOME:-}" ]; then
    candidates+=("${CODEX_HOME}/skills/knowledge-gate/scripts/knowledge-gate")
  fi

  if [ -n "${HOME:-}" ]; then
    candidates+=(
      "${HOME}/.codex/skills/knowledge-gate/scripts/knowledge-gate"
      "${HOME}/.agents/skills/knowledge-gate/scripts/knowledge-gate"
      "${HOME}/.claude/skills/knowledge-gate/scripts/knowledge-gate"
    )
  fi

  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

emit_context() {
  local context="$1"

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg context "$context" \
      '{
        additionalContext: $context,
        hookSpecificOutput: {
          hookEventName: "UserPromptSubmit",
          additionalContext: $context
        }
      }'
  else
    printf '%s\n' "$context"
  fi
}

# Fast exit: no vault → not an adopting project
VAULT_PATH=""
if [ -n "${KNOWLEDGE_VAULT_PATH:-}" ] && [ -f "$KNOWLEDGE_VAULT_PATH" ]; then
  VAULT_PATH="$KNOWLEDGE_VAULT_PATH"
elif command -v git >/dev/null 2>&1; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$ROOT" ] && [ -f "$ROOT/.knowledge/vault.db" ]; then
    VAULT_PATH="$ROOT/.knowledge/vault.db"
  fi
fi

if [ -z "$VAULT_PATH" ]; then
  exit 0
fi

# Fast exit: sqlite3 not available → can't query vault
if ! command -v sqlite3 >/dev/null 2>&1; then
  emit_context "Knowledge Vault found but sqlite3 is not installed. Install sqlite3 to enable vault queries."
  exit 0
fi

# Fast exit: empty vault (no active entries) → nothing to remind about
COUNT=$(sqlite3 "$VAULT_PATH" "SELECT COUNT(*) FROM entries WHERE status = 'active';" 2>/dev/null || echo "0")
if [ "$COUNT" = "0" ]; then
  exit 0
fi

CLI_PATH="$(resolve_cli_path || true)"

if [ -z "$CLI_PATH" ]; then
  emit_context "Knowledge Vault active (${COUNT} entries), but the knowledge-gate CLI could not be resolved. Re-run the Knowledge Distillery Agent Installation Guide so the hook can find the project skill install."
  exit 0
fi

CONTEXT="$(cat <<EOF
Knowledge Vault active (${COUNT} entries). Use this exact CLI path: "${CLI_PATH}".
If this task involves code modifications, query relevant entries before planning. Queries return a lightweight summary index by default; fetch full bodies only for the entry IDs you need.
  - Single file: "${CLI_PATH}" query-paths <filepath>
  - Multiple files: "${CLI_PATH}" domain-resolve-path <filepath> → "${CLI_PATH}" query-domain <domain>
  - Topic search: "${CLI_PATH}" search <keyword>
  - Full details: "${CLI_PATH}" get <id> or "${CLI_PATH}" get-many <id...>
EOF
)"

emit_context "$CONTEXT"
