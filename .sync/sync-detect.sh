#!/usr/bin/env bash
# Deterministic repo-side change detector for the GitHub <-> Slite sync (v2).
#
# v2 replaces v1's O(N) full scan (read every baseline + fetch every Slite note)
# with change detection. This script owns the *repo* side: it answers "which docs
# changed in git since the last sync?" using `git diff` against the recorded
# lastSyncedGitSha, plus content hashing to drop no-op reverts. It calls NO MCP /
# Slite tools — the Slite side is handled by Routine A via get-note-children's
# updatedAt (see SYNC.md).
#
# Usage:
#   .sync/sync-detect.sh                 # or: detect  -> emits the change-set JSON
#   .sync/sync-detect.sh detect          # same as above
#   .sync/sync-detect.sh hash <file>     # print the normalized content hash of one file
#
# The `hash` subcommand exists so the seeding step, Routine A, and Routine B all
# compute repoHash / sliteHash exactly the same way (write a Slite md export to a
# temp file, then `hash` it). Both sides MUST share this normalization or every
# doc reads as "changed".
#
# Hashing is over *normalized* content: trailing whitespace stripped per line and
# trailing blank lines removed, then sha256. Each side is compared only against its
# own stored hash, so cosmetic export differences never cross sides.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$SCRIPT_DIR/state.json"
MAP_FILE="$SCRIPT_DIR/slite-map.json"

# normhash <file> : normalize (strip trailing ws per line, drop trailing blank
# lines) and sha256. Prints empty string for a missing file.
normhash() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  awk '{ sub(/[ \t\r]+$/, ""); buf[NR] = $0 }
       END { last = NR; while (last > 0 && buf[last] == "") last--;
             for (i = 1; i <= last; i++) print buf[i] }' "$f" \
    | sha256sum | cut -d' ' -f1
}

cmd="${1:-detect}"

case "$cmd" in
  hash)
    [ $# -ge 2 ] || { echo "usage: sync-detect.sh hash <file>" >&2; exit 2; }
    normhash "$2"
    exit 0
    ;;
  detect) ;;
  *)
    echo "unknown command: $cmd (expected: detect | hash)" >&2
    exit 2
    ;;
esac

cd "$REPO_ROOT"

[ -f "$STATE_FILE" ] || { echo "missing $STATE_FILE — seed it first (see SYNC.md)" >&2; exit 1; }
[ -f "$MAP_FILE" ]   || { echo "missing $MAP_FILE" >&2; exit 1; }

base="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lastSyncedGitSha"])' "$STATE_FILE")"
head="$(git rev-parse HEAD)"

# Doc directories come from the map's folders, so adding a section stays single-sourced.
read -r -a DOC_DIRS <<<"$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["folders"]))' "$MAP_FILE")"

# Collect the raw git change-set as TSV: status<TAB>path<TAB>newhash<TAB>renamedFrom
# Renames use -M; status is reduced to its first letter (R100 -> R).
tsv="$(mktemp)"
trap 'rm -f "$tsv"' EXIT

if [ "$base" != "$head" ]; then
  while IFS=$'\t' read -r status p1 p2; do
    [ -n "$status" ] || continue
    case "${status:0:1}" in
      R)
        # rename: p1=old, p2=new
        printf '%s\t%s\t%s\t%s\n' "R" "$p2" "$(normhash "$p2")" "$p1" >>"$tsv"
        ;;
      D)
        printf '%s\t%s\t%s\t%s\n' "D" "$p1" "" "" >>"$tsv"
        ;;
      A)
        printf '%s\t%s\t%s\t%s\n' "A" "$p1" "$(normhash "$p1")" "" >>"$tsv"
        ;;
      *)  # M, C, T, etc. -> treat as modified
        printf '%s\t%s\t%s\t%s\n' "M" "$p1" "$(normhash "$p1")" "" >>"$tsv"
        ;;
    esac
  done < <(git diff --name-status -M "$base..$head" -- "${DOC_DIRS[@]}")
fi

# Emit the change-set JSON, dropping no-op reverts (newhash == stored repoHash).
python3 - "$STATE_FILE" "$MAP_FILE" "$base" "$head" "$tsv" <<'PY'
import json, sys

state_file, map_file, base, head, tsv = sys.argv[1:6]
state = json.load(open(state_file))
mp = json.load(open(map_file))
docs = state.get("docs", {})
path2note = dict(mp.get("docs", {}))

status_name = {"M": "modified", "A": "added", "D": "deleted", "R": "renamed"}

changes = []
for line in open(tsv):
    line = line.rstrip("\n")
    if not line:
        continue
    status, path, newhash, renamed_from = (line.split("\t") + ["", "", ""])[:4]
    renamed_from = renamed_from or None
    newhash = newhash or None
    # A rename keeps the same note: resolve id / stored hash from the OLD path.
    lookup = renamed_from if (status == "R" and renamed_from) else path
    stored = docs.get(lookup, {}).get("repoHash") or None
    note_id = path2note.get(lookup) or docs.get(lookup, {}).get("noteId")
    # Drop no-op: file touched in a commit but content (normalized) unchanged.
    if status in ("M", "A") and newhash is not None and newhash == stored:
        continue
    changes.append({
        "path": path,
        "status": status_name.get(status, status),
        "noteId": note_id,
        "storedRepoHash": stored,
        "newRepoHash": newhash,
        "renamedFrom": renamed_from,
    })

out = {
    "lastSyncedGitSha": base,
    "headSha": head,
    "lastSyncedAt": state.get("lastSyncedAt"),
    "repoChanged": changes,
    "note": ("Slite side is detected by Routine A: get-note-children on the SPACE "
             "TEST root, keep notes with updatedAt > lastSyncedAt, then get-note "
             "(md) only those and hash with `sync-detect.sh hash`."),
}
print(json.dumps(out, indent=2))
PY
