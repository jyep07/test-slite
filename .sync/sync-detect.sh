#!/usr/bin/env bash
# Deterministic repo-side change detector for the GitHub <-> Slite sync (v2).
#
# v2 replaces v1's O(N) full scan (read every baseline + fetch every Slite note)
# with change detection. This script owns the *repo* side: it answers "which docs
# changed in git since the last sync?" using `git diff` against the recorded
# lastSyncedGitSha, plus content hashing to drop no-op reverts. It calls NO MCP /
# Slite tools — the Slite side is handled by Routine A, which hash-compares every
# mapped note (Slite's edit timestamps are unreliable; see SYNC.md).
#
# Usage:
#   .sync/sync-detect.sh                  # or: detect  -> emits the change-set JSON
#   .sync/sync-detect.sh detect           # same as above
#   .sync/sync-detect.sh hash <file>      # print the normalized content hash of one file
#   .sync/sync-detect.sh normalize <file> # print the canonical (normalized) text — for review
#   .sync/sync-detect.sh selftest         # assert the normalizer ignores formatting, keeps content
#
# The `hash` subcommand exists so the seeding step, Routine A, and Routine B all
# compute repoHash / sliteHash exactly the same way (write a Slite md export to a
# temp file, then `hash` it). Both sides MUST share this normalization or every
# doc reads as "changed".
#
# NORMALIZATION — what counts as a change (formatting-insensitive, markup-preserving):
#   IGNORED (treated as formatting, never a change):
#     - leading / trailing whitespace on a line
#     - runs of spaces/tabs collapsed to one space (e.g. table-column padding)
#     - blank lines (Slite's export injects them mid-paragraph)
#     - hard-wrapping: consecutive text / list-continuation lines are reflowed into
#       one logical line, so "wrapped at 80 cols" == "one long line"
#     - table-cell padding and the dash-count in table separator rows
#   PRESERVED (a real change — still flagged):
#     - the actual words / characters
#     - markdown markup: heading level (#/##), emphasis (**/_), list marker (-/*/+),
#       blockquote (>), table pipes, links, code — these are characters, not whitespace
#   Each side is compared only against its own stored hash, so cosmetic *export*
#   differences (Slite vs repo) never cross sides; this normalization additionally
#   stops a *same-side* reformat (re-wrap / re-pad) from reading as an edit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$SCRIPT_DIR/state.json"
MAP_FILE="$SCRIPT_DIR/slite-map.json"

# The canonical normalizer. Reads a file path (argv[1]) and writes normalized text
# to stdout. Shared by hash / normalize / detect so every caller agrees byte-for-byte.
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
            continue                                  # blanks: may be mid-paragraph in Slite
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
    [ $# -ge 2 ] || { echo "usage: sync-detect.sh hash <file>" >&2; exit 2; }
    normhash "$2"
    exit 0
    ;;
  normalize)
    [ $# -ge 2 ] || { echo "usage: sync-detect.sh normalize <file>" >&2; exit 2; }
    python3 -c "$NORM_CODE" "$2"
    exit 0
    ;;
  selftest)
    # Demonstrate: formatting-only differences hash equal; content/markup differences don't.
    python3 - <<'PY'
import sys, re, hashlib, subprocess, os, tempfile

# inline the same normalizer for a self-contained check
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

# A: compact tables, hard-wrapped paragraph, wrapped bullet
A = """# Mars

Mars is the fourth planet from the Sun, known as the "Red Planet" for the iron
oxide (rust) that covers its surface.

## Quick Facts

| Property | Value |
|----------|-------|
| Diameter | 6,779 km |

## Notable Features

- **Olympus Mons** — the largest volcano in the Solar System, standing about
  22 km tall.
"""
# B: same content, padded table, unwrapped paragraph, blank lines injected, bullet on one line
B = """#   Mars

Mars is the fourth planet from the Sun, known as the "Red Planet" for the iron oxide (rust) that covers its surface.

##  Quick Facts

| Property                  | Value      |
| ------------------------- | ---------- |
| Diameter                  | 6,779 km   |

## Notable Features

- **Olympus Mons** — the largest volcano in the Solar System, standing about 22 km tall.
"""
# C: a real CONTENT edit (6,779 -> 6,780 km)
C = A.replace("6,779", "6,780")
# D: a real MARKUP edit (## -> ###)
D = A.replace("## Quick Facts", "### Quick Facts")
# E: a real MARKUP edit (drop bold on Olympus Mons)
E = A.replace("**Olympus Mons**", "Olympus Mons")

ok = True
def check(name, cond):
    global ok
    print(("PASS" if cond else "FAIL"), name); ok = ok and cond

check("formatting-only (wrap/pad/blank) -> SAME hash", h(A) == h(B))
check("content edit (6,779->6,780)      -> DIFFERENT hash", h(A) != h(C))
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
    "note": ("Slite side is detected by Routine A: get-note (md) for EVERY mapped "
             "note and hash-compare to sliteHash with `sync-detect.sh hash`. Do not "
             "filter by updatedAt — Slite's edit timestamps are unreliable."),
}
print(json.dumps(out, indent=2))
PY
