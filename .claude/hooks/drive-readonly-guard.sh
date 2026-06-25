#!/usr/bin/env bash
# PreToolUse guard for the GitHub <-> Google Docs sync routines.
#
# Purpose: Routine A (sync detect / dry run) must READ Google Drive but never
# WRITE to it. This hook is enforced by the Claude Code harness, not the model,
# so it holds even in autonomous routine runs where connector tools are
# otherwise callable freely.
#
# Policy (default-deny):
#   - Drive read tools (allow-list below) are permitted.
#   - Every other mcp__Google_Drive__* tool is treated as a mutation and DENIED,
#     so any future Drive write tool (move/update/delete/...) is blocked too.
#   - The deny is bypassed only when SYNC_ALLOW_WRITES=1 is set in the
#     environment (Routine B / apply sets this; Routine A does not).
#
# Receives the PreToolUse payload as JSON on stdin; emits a JSON permission decision.

set -euo pipefail

payload="$(cat)"

tool_name="$(printf '%s' "$payload" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_name", ""))' 2>/dev/null || echo "")"

# Only this hook is wired to mcp__Google_Drive__* via the matcher, but re-check defensively.
case "$tool_name" in
  mcp__Google_Drive__*) ;;
  *) exit 0 ;;  # not a Drive tool -> no opinion
esac

# Explicit escape hatch for the apply routine.
if [ "${SYNC_ALLOW_WRITES:-0}" = "1" ]; then
  exit 0
fi

# Drive read / non-mutating tools that Routine A is allowed to call.
read_tools=(
  "mcp__Google_Drive__search_files"
  "mcp__Google_Drive__read_file_content"
  "mcp__Google_Drive__download_file_content"
  "mcp__Google_Drive__get_file_metadata"
  "mcp__Google_Drive__get_file_permissions"
  "mcp__Google_Drive__list_recent_files"
)

for t in "${read_tools[@]}"; do
  if [ "$tool_name" = "$t" ]; then
    exit 0  # read tool -> allow
  fi
done

# Anything else under mcp__Google_Drive__ is a write/mutation -> deny.
reason="Blocked by drive-readonly-guard: '${tool_name}' can modify Google Drive, but this run is read-only (SYNC_ALLOW_WRITES is not set). Record the intended change in .sync/pending-docs-changes.json instead of writing to Drive."

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
