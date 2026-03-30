#!/bin/bash
set -euo pipefail

# PostToolUse hook: detect git commit and remind to attach memento session summary.
# Fires on every Bash tool use — exits fast for non-commit commands.

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Fast exit: only act on git commit commands
if ! echo "$COMMAND" | grep -qE 'git\s+(commit|memento\s+commit)'; then
  exit 0
fi

# Extract commit SHA from tool output
OUTPUT=$(echo "$INPUT" | jq -r '.tool_response.output // ""')
SHA=$(echo "$OUTPUT" | grep -oE '[a-f0-9]{7,40}' | head -1)

if [ -z "$SHA" ]; then
  exit 0
fi

# Check if a memento note already exists for this commit
if git notes --ref=refs/notes/commits show "$SHA" >/dev/null 2>&1; then
  exit 0
fi

# Output reminder for the LLM via additionalContext
cat <<EOF
{
  "additionalContext": "Commit ${SHA} has no memento session summary. Generate a 7-section memento summary (Decisions Made, Problems Encountered, Constraints Identified, Open Questions, Context, Recorded Decisions, Vault Entries Referenced) reflecting this session and attach it:\n\ngit notes --ref=refs/notes/commits add --force --file=- ${SHA} <<'MEMENTO_EOF'\n<summary>\nMEMENTO_EOF\n\nAfter attaching the note and pushing refs/notes/commits, clear vault-refs: rm -f tmp/vault-refs.jsonl 2>/dev/null || true"
}
EOF
