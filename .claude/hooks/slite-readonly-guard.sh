#!/usr/bin/env bash
# PreToolUse guard for the GitHub <-> Slite sync routines.
#
# Purpose: Routine A (sync detect / dry run) must READ Slite but never WRITE to it.
# This hook is enforced by the Claude Code harness, not the model, so it holds even
# in autonomous routine runs where connector tools are otherwise callable freely.
#
# Policy (default-deny):
#   - Slite read tools (allow-list below) are permitted.
#   - Every other mcp__Slite__* tool is treated as a mutation and DENIED,
#     so any future Slite write tool is blocked automatically.
#   - The deny is bypassed only when SYNC_ALLOW_WRITES=1 is set in the environment
#     (Routine B / apply sets this; Routine A does not).
#
# Receives the PreToolUse payload as JSON on stdin; emits a JSON permission decision.

set -euo pipefail

payload="$(cat)"

tool_name="$(printf '%s' "$payload" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_name", ""))' 2>/dev/null || echo "")"

# Only this hook is wired to mcp__Slite__* via the matcher, but re-check defensively.
case "$tool_name" in
  mcp__Slite__*) ;;
  *) exit 0 ;;  # not a Slite tool -> no opinion
esac

# Explicit escape hatch for the apply routine.
if [ "${SYNC_ALLOW_WRITES:-0}" = "1" ]; then
  exit 0
fi

# Slite read / non-mutating tools that Routine A is allowed to call.
read_tools=(
  "mcp__Slite__get-note"
  "mcp__Slite__get-note-children"
  "mcp__Slite__search-notes"
  "mcp__Slite__search-users"
  "mcp__Slite__search-user-groups"
  "mcp__Slite__get-user"
  "mcp__Slite__get-user-group"
  "mcp__Slite__list-channels"
  "mcp__Slite__list-notes-for-knowledge-management"
  "mcp__Slite__list-empty-notes-for-knowledge-management"
  "mcp__Slite__list-inactive-notes-for-knowledge-management"
  "mcp__Slite__list-public-notes-for-knowledge-management"
  "mcp__Slite__list-recently-edited-notes"
  "mcp__Slite__list-recently-visited-notes"
  "mcp__Slite__list-comment-threads"
  "mcp__Slite__get-comment-thread-on-note"
  "mcp__Slite__ask-slite"
)

for t in "${read_tools[@]}"; do
  if [ "$tool_name" = "$t" ]; then
    exit 0  # read tool -> allow
  fi
done

# Anything else under mcp__Slite__ is a write/mutation -> deny.
reason="Blocked by slite-readonly-guard: '${tool_name}' can modify Slite, but this run is read-only (SYNC_ALLOW_WRITES is not set). Record the intended change in .sync/pending-slite-changes.json instead of writing to Slite."

python3 - "$reason" <<'PY'
import json, sys
reason = sys.argv[1]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }
}))
PY
exit 0
