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

# Allow: decision commits (message prefix "decision:") — decision files provide
# their own session context and do not require memento notes (see AGENTS.md)
# Anchors to -m/--message argument to avoid false positives from chained commands;
# supports both single and double quotes around the commit message.
if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+commit([[:space:]][^;&|]*)?([[:space:]]-m[[:space:]]|[[:space:]]--message(=|[[:space:]]))[\"'"'"']decision:'; then
  exit 0
fi

# Block: direct git commit without memento note
cat <<'EOF'
{
  "decision": "block",
  "reason": "Direct git commit is not allowed in this project. Use /knowledge-distillery:memento-commit instead — it generates a commit message, attaches a memento session summary as a git note, and ensures the evidence pipeline receives session context."
}
EOF
