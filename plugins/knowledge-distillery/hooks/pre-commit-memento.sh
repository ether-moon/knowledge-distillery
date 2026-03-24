#!/bin/bash
set -euo pipefail

# PreToolUse hook: block direct git commit and redirect to memento-commit skill.
# Fires on every Bash tool use — exits fast for non-commit commands.
#
# Detection logic:
#   - Command contains `git commit` → potential direct commit
#   - Command also contains `git notes` → skill-generated (commit + note in one call)
#   - Direct commit without notes → block and redirect to skill

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Fast exit: not a git commit command
if ! echo "$COMMAND" | grep -qE 'git\s+commit'; then
  exit 0
fi

# Allow: skill-generated commands combine commit + notes in a single call
if echo "$COMMAND" | grep -qE 'git\s+notes'; then
  exit 0
fi

# Block: direct git commit without memento note
cat <<'EOF'
{
  "decision": "block",
  "reason": "Direct git commit is not allowed in this project. Use /knowledge-distillery:memento-commit instead — it generates a commit message, attaches a memento session summary as a git note, and ensures the evidence pipeline receives session context."
}
EOF
