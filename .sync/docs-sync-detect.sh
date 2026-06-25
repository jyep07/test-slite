#!/usr/bin/env bash
# Deterministic repo-side change detector for the GitHub <-> Google Docs sync.
#
# This is the Google Docs analogue of sync-detect.sh (which targets Slite). It
# owns the *repo* side: "which docs changed in git since the last sync?" using
# `git diff` against the recorded lastSyncedGitSha, plus content hashing to drop
# no-op reverts. It calls NO MCP / Drive tools — the Drive side is handled by
# Routine A, which hash-compares every mapped Doc.
#
# Drive-side detection (done by Routine A, not here):
#   For each mapped Doc, export it as markdown (download_file_content with
#   exportMimeType "text/markdown"), write it to a temp file, then run
#   `docs-sync-detect.sh hash <tmp>` and compare to the stored driveHash.
#   `modifiedTime` is a cheap *trigger* hint (Drive bumps it on edits AND on
#   comments), but the hash is the source of truth for "did the body change".
#
# Usage:
#   .sync/docs-sync-detect.sh                  # or: detect -> emits the change-set JSON
#   .sync/docs-sync-detect.sh detect           # same as above
#   .sync/docs-sync-detect.sh hash <file>      # print the normalized content hash of one file
#   .sync/docs-sync-detect.sh normalize <file> # print the canonical (normalized) text
#   .sync/docs-sync-detect.sh selftest         # assert the normalizer ignores formatting, keeps content
#
# NORMALIZATION is identical to sync-detect.sh: formatting-insensitive
# (whitespace runs, blank lines, hard-wrapping, table padding, separator
# dash-count) but markup-preserving (#, **, list markers, >, pipes, links).
# Each side is compared only against its OWN stored hash (repoHash vs driveHash),
# so the repo-markdown vs Docs-markdown-export differences never cross sides.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$SCRIPT_DIR/drive-state.json"
MAP_FILE="$SCRIPT_DIR/drive-map.json"

# The canonical normalizer. Reads a file path (argv[1]) and writes normalized text
# to stdout. Shared by hash / normalize / detect so every caller agrees byte-for-byte.
# MUST stay character-identical to sync-detect.sh's NORM_CODE.
NORM_CODE=$(cat <<'PY'
import sys, re

def is_table_sep(s):
    # a separator row: only pipes, ASCII dashes, colons, spaces — and at least one dash
    return ('|' in s) and ('-' in s) and re.fullmatch(r'[\s|:\-]+', s) is not None

def normalize(text):
    out, buf = [], []
    def flush():
        if buf:
            out.append(' '.join(buf))
            del buf[:]
    for raw in text.split('\n'):
        line = re.sub(r'[ \t]+', ' ', raw.strip())   # trim + collapse internal ws runs
        if line == '':
            continue                                  # blanks: may be mid-paragraph in export
        if line.startswith('#'):                       # heading -> its own line, no reflow
            flush(); out.append(line); continue
        if line.startswith('|'):                       # table row -> its own line
            flush()
            if is_table_sep(line):
                out.append(re.sub(r'-+', '-', line.replace(' ', '')))   # |---|--| -> |-|-|
            else:
                out.append(re.sub(r'\s*\|\s*', '|', line))             # strip cell padding
            continue
        if re.match(r'(?:[-*+]|>|\d+\.)\s', line):     # list item / blockquote starts a block
            flush(); buf.append(line); continue
        buf.append(line)                               # plain text -> reflow into current block
    flush()
    return '\n'.join(out)

sys.stdout.write(normalize(open(sys.argv[1], encoding='utf-8').read()))
PY
)

# normhash <file> : normalized content -> sha256. Empty string for a missing file.
normhash() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  python3 -c "$NORM_CODE" "$f" | sha256sum | cut -d' ' -f1
}

cmd="${1:-detect}"

case "$cmd" in
  hash)
    [ $# -ge 2 ] || { echo "usage: docs-sync-detect.sh hash <file>" >&2; exit 2; }
    normhash "$2"
    exit 0
    ;;
  normalize)
    [ $# -ge 2 ] || { echo "usage: docs-sync-detect.sh normalize <file>" >&2; exit 2; }
    python3 -c "$NORM_CODE" "$2"
    exit 0
    ;;
  selftest)
    # Same formatting-vs-content assertions as sync-detect.sh (markup is content).
    python3 - <<'PY'
import sys, re, hashlib

def is_table_sep(s):
    return ('|' in s) and ('-' in s) and re.fullmatch(r'[\s|:\-]+', s) is not None
def normalize(text):
    out, buf = [], []
    def flush():
        if buf: out.append(' '.join(buf)); del buf[:]
    for raw in text.split('\n'):
        line = re.sub(r'[ \t]+', ' ', raw.strip())
        if line == '': continue
        if line.startswith('#'): flush(); out.append(line); continue
        if line.startswith('|'):
            flush()
            out.append(re.sub(r'-+','-',line.replace(' ','')) if is_table_sep(line)
                       else re.sub(r'\s*\|\s*','|',line))
            continue
        if re.match(r'(?:[-*+]|>|\d+\.)\s', line): flush(); buf.append(line); continue
        buf.append(line)
    flush()
    return '\n'.join(out)
def h(t): return hashlib.sha256(normalize(t).encode()).hexdigest()

A = """# Earth

Earth is the third planet from the Sun and the only known astronomical object
to harbor life.

## Quick Facts

| Property | Value |
|----------|-------|
| Diameter | 12,742 km |

## Notable Features

- **Plate tectonics** — active crustal plates that continually reshape the
  surface.
"""
# B: same content, padded table, unwrapped lines, blank lines, bullet on one line
B = """#   Earth

Earth is the third planet from the Sun and the only known astronomical object to harbor life.

##  Quick Facts

| Property                  | Value      |
| ------------------------- | ---------- |
| Diameter                  | 12,742 km   |

## Notable Features

- **Plate tectonics** — active crustal plates that continually reshape the surface.
"""
C = A.replace("12,742", "12,743")          # content edit
D = A.replace("## Quick Facts", "### Quick Facts")  # markup edit
E = A.replace("**Plate tectonics**", "Plate tectonics")  # markup edit (drop bold)

ok = True
def check(name, cond):
    global ok
    print(("PASS" if cond else "FAIL"), name); ok = ok and cond

check("formatting-only (wrap/pad/blank) -> SAME hash", h(A) == h(B))
check("content edit (12,742->12,743)    -> DIFFERENT hash", h(A) != h(C))
check("markup edit (## -> ###)          -> DIFFERENT hash", h(A) != h(D))
check("markup edit (drop **bold**)      -> DIFFERENT hash", h(A) != h(E))
sys.exit(0 if ok else 1)
PY
    exit $?
    ;;
  detect) ;;
  *)
    echo "unknown command: $cmd (expected: detect | hash | normalize | selftest)" >&2
    exit 2
    ;;
esac

cd "$REPO_ROOT"

[ -f "$STATE_FILE" ] || { echo "missing $STATE_FILE — seed it first (see DOCS-SYNC.md)" >&2; exit 1; }
[ -f "$MAP_FILE" ]   || { echo "missing $MAP_FILE" >&2; exit 1; }

base="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lastSyncedGitSha"])' "$STATE_FILE")"
head="$(git rev-parse HEAD)"

# Doc directories come from the map's folders, so adding a section stays single-sourced.
read -r -a DOC_DIRS <<<"$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["folders"]))' "$MAP_FILE")"

# Collect the raw git change-set as TSV: status<TAB>path<TAB>newhash<TAB>renamedFrom
tsv="$(mktemp)"
trap 'rm -f "$tsv"' EXIT

if [ "$base" != "$head" ]; then
  while IFS=$'\t' read -r status p1 p2; do
    [ -n "$status" ] || continue
    case "${status:0:1}" in
      R)
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
path2file = dict(mp.get("docs", {}))

status_name = {"M": "modified", "A": "added", "D": "deleted", "R": "renamed"}

changes = []
for line in open(tsv):
    line = line.rstrip("\n")
    if not line:
        continue
    status, path, newhash, renamed_from = (line.split("\t") + ["", "", ""])[:4]
    renamed_from = renamed_from or None
    newhash = newhash or None
    lookup = renamed_from if (status == "R" and renamed_from) else path
    stored = docs.get(lookup, {}).get("repoHash") or None
    file_id = path2file.get(lookup) or docs.get(lookup, {}).get("fileId")
    if status in ("M", "A") and newhash is not None and newhash == stored:
        continue
    changes.append({
        "path": path,
        "status": status_name.get(status, status),
        "fileId": file_id,
        "storedRepoHash": stored,
        "newRepoHash": newhash,
        "renamedFrom": renamed_from,
    })

out = {
    "lastSyncedGitSha": base,
    "headSha": head,
    "lastSyncedAt": state.get("lastSyncedAt"),
    "repoChanged": changes,
    "note": ("Drive side is detected by Routine A: export EVERY mapped Doc as "
             "markdown (download_file_content, exportMimeType text/markdown), write "
             "to a temp file, `docs-sync-detect.sh hash` it, and compare to the "
             "stored driveHash. modifiedTime is only a trigger hint (it also bumps "
             "on comments) — the hash decides whether the body actually changed."),
}
print(json.dumps(out, indent=2))
PY
