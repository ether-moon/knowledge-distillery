#!/bin/bash
set -euo pipefail

# UserPromptSubmit hook: remind agent to query Knowledge Vault before planning.
# Fires on every user prompt — exits fast when vault is absent.

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
  cat <<'EOF'
{
  "additionalContext": "Knowledge Vault found but sqlite3 is not installed. Install sqlite3 to enable vault queries."
}
EOF
  exit 0
fi

# Fast exit: empty vault (no active entries) → nothing to remind about
COUNT=$(sqlite3 "$VAULT_PATH" "SELECT COUNT(*) FROM entries WHERE status = 'active';" 2>/dev/null || echo "0")
if [ "$COUNT" = "0" ]; then
  exit 0
fi

cat <<EOF
{
  "additionalContext": "Knowledge Vault active (${COUNT} entries). If this task involves code modifications, query relevant entries before planning:\n  - Single file: knowledge-gate query-paths <filepath>\n  - Multiple files: knowledge-gate domain-resolve-path <filepath> → knowledge-gate query-domain <domain>\n  - Topic search: knowledge-gate search <keyword>"
}
EOF
