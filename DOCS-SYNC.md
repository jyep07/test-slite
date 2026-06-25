# Google Docs ↔ GitHub sync (doc-repo model)

This branch (`claude/doc-repo-sync`) syncs this repo's markdown knowledge base
with a set of **Google Docs** in the Drive folder **Space KB**, using an
O(changes) change-detection design (`git diff` on the repo side, a content hash
on the Drive side).

> **Status: detection is fully working; repo→Doc write-back is partial.** The
> Google Drive connector in this environment is **read + create only** (no move,
> update, or delete tool). So Routine B can *create* a Doc for a brand-new repo
> file, but it cannot yet *overwrite* an existing Doc's body. See
> [Write-back limitation](#write-back-limitation).

---

## Why change-detection (vs. a full scan)

A full scan reads every repo file and exports every Doc on every run — O(N).
This model is O(changes):

- **Repo side** is free and deterministic: `git diff <lastSyncedGitSha>..HEAD`
  tells us exactly which files changed, with no API calls.
- **Drive side** uses `modifiedTime` as a cheap trigger and a content hash as the
  source of truth (see below).

---

## The two-hash model

Repo markdown and a Google Doc's markdown *export* never match byte-for-byte
(the export wraps the title as `# **Title**`, adds table alignment rows, uses
`*` bullets, escapes some punctuation, etc.). So each doc stores **two** hashes
in `.sync/drive-state.json`:

```json
"planets/earth.md": {
  "fileId": "1Qhygx...",
  "repoHash":  "<sha256 of normalized repo .md>",
  "driveHash": "<sha256 of normalized Doc markdown export>"
}
```

Each side is compared **only against its own stored hash**:

- repo file changed  ⟺  `normhash(repo .md)` ≠ stored `repoHash`
- Doc changed        ⟺  `normhash(Doc md export)` ≠ stored `driveHash`

The cross-side export differences never cause false positives because the two
hashes are never compared to each other.

### Normalization (what counts as a change)

`docs-sync-detect.sh` holds the canonical normalizer (character-identical to
`sync-detect.sh`). It is **formatting-insensitive but markup-preserving**:

- **Ignored** (never a change): leading/trailing whitespace, collapsed space
  runs, blank lines, hard-wrapping (wrapped lines are reflowed into one logical
  line), table-cell padding, and the dash-count in table separator rows.
- **Preserved** (a real change): the words themselves, and markdown markup —
  heading level (`#`/`##`), emphasis (`**`/`_`), list marker, blockquote (`>`),
  table pipes, links, code.

Run `bash .sync/docs-sync-detect.sh selftest` to see the assertions.

> Caveat: Google Docs markdown export **drops some inline markup** in certain
> cases. Whatever the export emits *is* the baseline, so this is consistent —
> but an edit that only changes markup the export can't represent won't be
> detected. Plain prose, headings, tables, and bold round-trip fine.

---

## Files

| File | Role |
|------|------|
| `.sync/drive-map.json` | repo path ↔ Drive fileId; `root` (Space KB), `folders` (repo doc dirs, used for git-diff filtering), `driveFolders` (repo dir → Drive subfolder ID) |
| `.sync/drive-state.json` | sync baseline: `lastSyncedGitSha`, `lastSyncedAt` (audit-only), and per-doc `{fileId, repoHash, driveHash}` |
| `.sync/docs-sync-detect.sh` | repo-side detector + shared normalizer (`detect` / `hash` / `normalize` / `selftest`) |
| `.sync/pending-docs-changes.json` | queue Routine A writes and Routine B applies: `{scanGitSha, to_docs[], from_docs[]}` |
| `.claude/hooks/drive-readonly-guard.sh` | PreToolUse guard: allows Drive **read** tools, denies create/copy (and any future write) unless `SYNC_ALLOW_WRITES=1` |

Folder location of a Doc in Drive does **not** affect its `fileId` or its
export, so moving docs between folders never invalidates the map or hashes.

---

## Routine A — detect / dry-run (READ-ONLY on Drive)

Enforced read-only by `drive-readonly-guard.sh`. Routine A never writes to Drive;
it records intended changes in `.sync/pending-docs-changes.json`.

1. **Guard check** — confirm no open sync PR is mid-flight.
2. **Repo side** — run `.sync/docs-sync-detect.sh detect`. Its `repoChanged[]`
   lists added/modified/deleted/renamed docs since `lastSyncedGitSha`, already
   de-duped against no-op reverts.
3. **Drive side** — for **every** mapped doc, export it as markdown
   (`download_file_content`, `exportMimeType: text/markdown`), write to a temp
   file, `docs-sync-detect.sh hash` it, and compare to the stored `driveHash`.
   - `modifiedTime` is only a **trigger hint** — it also bumps on comments, so
     it can't tell a body edit from a comment. The hash is the source of truth.
   - To cut cost on a large corpus you *may* pre-filter with
     `modifiedTime > lastSyncedAt` and only hash candidates, but verify with the
     hash before flagging.
4. **Comments (optional advisory)** — for any doc whose `modifiedTime` moved but
   whose `driveHash` did **not**, fetch its comment threads
   (`read_file_content` with `includeComments: true`) and surface *new/open*
   threads in the sync PR body as advisory context. A comment is a human asking
   for a change, never an auto-applied edit.
5. **Write the queue** — set `scanGitSha` to the detector's `headSha`; fill
   `to_docs[]` (repo→Doc) and `from_docs[]` (Doc→repo). Open a sync PR whose
   branch name **contains "sync"** so Routine B picks it up.

## Routine B — apply (WRITES, gated by merge)

Runs with `SYNC_ALLOW_WRITES=1`. The human gate is the sync-PR merge.

1. **Doc→repo** (`from_docs[]`): write the new content into the repo .md files,
   recompute `repoHash` **and** `driveHash`, commit.
2. **Repo→Doc** (`to_docs[]`): apply repo changes to the Docs — *subject to the
   write-back limitation below*.
3. **Advance the baseline**: set `lastSyncedGitSha = scanGitSha` (NOT HEAD, so
   unrelated repo edits made mid-cycle are still caught next run), refresh
   `lastSyncedAt`, and update each touched doc's hashes in `drive-state.json`.

### Write-back limitation

The current Drive connector exposes only `create_file` and `copy_file` for
mutation — there is **no way to replace an existing Doc's body, move, or delete**.
Consequences for `to_docs[]`:

- **New repo file** → Routine B can `create_file` a new Doc (HTML→Doc) in the
  right `driveFolders` folder and add it to the map. ✅
- **Edited repo file** → cannot overwrite the existing Doc body yet. ⛔
  Options when a real write-back API is available: Drive `files.update` with
  media, or Docs `batchUpdate`. Until then, repo→Doc *edits* are reported in the
  PR for a human to paste, or applied as a new Doc + manual swap.
- **Deleted/renamed repo file** → cannot delete/rename the Doc; report only.

The **Doc→repo** direction is fully automated (read + git commit) and is the
primary, reliable flow today.

---

## Conflict handling

If a doc changed on **both** sides since the last sync (repoHash *and* driveHash
both differ from baseline), reconstruct the common base with
`git show <lastSyncedGitSha>:<path>` and present a 3-way diff in the sync PR for a
human to resolve. Never auto-merge a two-sided conflict.

---

## Seeding / re-seeding

The baseline was seeded by `scratchpad/seed_drive.py`: for each doc it decodes
the Doc's markdown export, computes `repoHash` (from the repo .md) and
`driveHash` (from the export) with `docs-sync-detect.sh hash`, and writes
`drive-map.json` + `drive-state.json` at the current HEAD. To re-seed after
intentional drift, re-export every Doc, recompute both hashes, and set
`lastSyncedGitSha` to HEAD and `lastSyncedAt` to now.
