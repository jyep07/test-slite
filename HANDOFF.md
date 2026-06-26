# Handoff — GitHub ↔ Slite sync (comment-driven)

Context for continuing in a fresh Claude session. The repo travels between
sessions; this conversation's memory does not — so everything needed is here.

_Last updated: 2026-06-25. Branch: `claude/slite-comment-sync` (off `main`)._

## The model (what this branch implements)

Two-way sync between this repo's markdown and the Slite **SPACE TEST** folder,
scaling with the number of **changes**, not repo size. Human gate = **merging the
sync PR**. Full spec in `SYNC.md`.

- **repo → Slite**: detected with `git diff <lastSyncedGitSha>..HEAD` (no Slite
  calls), queued in `to_slite`, applied by Routine B (`update-note`/`create-note`/
  `archive-note`).
- **Slite → repo**: **comment-driven**. Reviewers leave a **comment** on a note
  (don't edit the body). Routine A reads **unresolved** threads, turns each into a
  proposed edit to the repo file (in the PR) + a queued Slite body update +
  comment resolution (`from_comments`). Routine B applies both and
  `resolve-comment-thread`.

## Why comment-driven (the key rationale)

Slite's edit timestamps (`updatedAt`, `lastEditedAt`, `list-recently-edited-notes`)
**do not reliably bump on a content edit**, so body-edit detection required
hash-sweeping every note (expensive) and still missed edits. Comments fix this:
- the `resolved` flag is a **reliable** pending/done signal (no body hashing),
- `list-comment-threads` returns light metadata → discovery is **O(N) light list
  calls**, full reads only for the **k** commented notes,
- intent is explicit and (if anchored) pinned to exact text.

## Complexity (precise)

- Discovery: **O(N)** light `list-comment-threads` calls (no space-wide comment
  feed exists, so N is the floor — but each call is cheap).
- Processing: **O(k)** where k = notes with unresolved comments.
- Not literally O(k) end-to-end, but far cheaper than the old full body sweep.

## Files (on this branch, off `main`)

```
SYNC.md                              full design + Routine A/B prompts (comment-driven)
.sync/
  sync-detect.sh                     repo-side detector + shared normalizer (detect/hash/normalize/selftest) — no MCP
  state.json                         baseline: lastSyncedGitSha, lastSyncedAt, per-doc {noteId, repoHash, sliteHash}
  slite-map.json                     repo path ↔ Slite noteId (+ folders, root, channel)
  pending-slite-changes.json         { scanGitSha, to_slite[], from_comments[] }
.claude/
  settings.json                      registers the PreToolUse guard on mcp__Slite__*
  hooks/slite-readonly-guard.sh      allow Slite reads (incl. comment reads); deny writes unless SYNC_ALLOW_WRITES=1
```

`pending-slite-changes.json` item shapes:
- `to_slite`: `{ action: "update"|"create"|"archive", path, noteId, newContent }`
- `from_comments`: `{ noteId, threadId, path, author, comment, anchoredText, summary }`

## Slite comment tools (confirmed available)

- Reads (Routine A, allowed by guard): `list-comment-threads(noteId)` →
  threads + `resolved` flag; `get-comment-thread-on-note(noteId, threadId)`.
- Writes (Routine B, `SYNC_ALLOW_WRITES=1`): `resolve-comment-thread(threadId)`,
  `reply-to-comment-thread(threadId, content)`, `create-comment-thread`,
  targeted block edits (`modify-block`/`modify-range`/`remove-blocks`), `update-note`
  (body). Anchored comments appear inline in the note's sliteml as
  `<comment id="threadId">target text</comment>`.

### Gotcha: orphaned comments + full-body overwrites (learned the hard way)

- A full-body `update-note(noteId, <whole markdown>)` **regenerates every block and
  drops all `<comment>` anchors** on the note — orphaning even threads on text you
  didn't touch. Routine B therefore syncs bodies with **targeted** edits
  (`modify-block`/`modify-range`/`remove-blocks`) and preserves `<comment id="…">`
  spans; full-body `update-note` only when the note has no threads.
- When the edit **deletes the exact text an anchored thread points at**, that thread
  becomes **orphaned**: Slite keeps it via the API (`resolved: true`, `archivedAt:
  null`, comments intact) but hides it from **both** the active and resolved sidebar
  views — it has no text to attach to. This is unavoidable for delete-the-anchor
  requests; resolve order doesn't matter.
- So Routine B also leaves a **note-level (unanchored) confirmation comment**
  (`create-comment-thread` with no `blockId`/`sliteml`) quoting the request — it stays
  visible in the UI regardless. Git (the sync PR + commit) is the canonical audit trail.

## Conventions to preserve

- **Comments = change requests; do not edit Slite bodies directly.** A direct body
  edit (body hash ≠ stored `sliteHash`) is treated as a **conflict**, reported in
  the PR, never auto-applied.
- Human gate = sync-PR merge. Routine A read-only (enforced by the guard);
  Routine B writes with `SYNC_ALLOW_WRITES=1`.
- Routine B advances `lastSyncedGitSha = scanGitSha` (NOT HEAD) so mid-cycle repo
  edits aren't hidden; updates only the changed docs' hashes.
- Each side compared only to its own stored hash (`repoHash` vs `sliteHash`).
- Conflict base = git: `git show <lastSyncedGitSha>:<path>`.
- Branch naming: Routine A → `claude/sync-<date>` (contains "sync" → triggers B on
  merge); Routine B → `claude/baseline-<date-time>` (must NOT contain "sync").

## How to demo / test

1. Routine A only, manual trigger.
2. Leave a comment on a Slite note (e.g. anchor a correction on the Saturn note);
   optionally also edit a repo file for the git→Slite direction.
3. Run A → PR should show the comment-driven repo edit + a `from_comments` entry
   quoting the comment, and any git→Slite change as `to_slite`. No changes → no PR.
4. Add Routine B + merge trigger; merge the sync PR; verify the note body updated,
   **the comment thread is resolved/replied**, `state.json` advanced, baseline PR
   auto-merged.

## Kickoff prompts for a fresh session

### Routine A — `sync-plan` (read-only dry run → opens the sync PR)

```
Test the comment-driven GitHub↔Slite sync in repo jyep07/test-slite.

START HERE: check out branch `claude/slite-comment-sync` and read HANDOFF.md
then SYNC.md before doing anything. Do all work on that branch — never touch
`main`. Make sure the Slite connector is attached.

SETUP (I'll do this, or confirm it's done): I've left a comment on one Slite
note in the SPACE TEST folder — e.g. on the "Saturn" note, anchored to a value,
requesting a correction. Treat that unresolved comment as the change request.

YOUR TASK — run a Routine A (`sync-plan`) dry run, exactly as specified in
SYNC.md. Specifically:
1. Run `bash .sync/sync-detect.sh detect` for the repo side.
2. For every doc in .sync/slite-map.json → docs, call `list-comment-threads` on
   its noteId and keep only UNRESOLVED threads. Only `get-note` the notes that
   have unresolved comments.
3. Apply the change rules: turn each unresolved comment into a concrete edit to
   the repo file, and queue a from_comments entry {noteId, threadId, path,
   author, comment, anchoredText, summary}. Run the direct-body-edit conflict
   guard (compare the note's md hash to sliteHash in state.json).
4. This run is READ-ONLY on Slite — the PreToolUse hook blocks every Slite write
   (including resolve/reply). Do NOT apply anything to Slite; only propose.
5. Open a sync PR on branch `claude/sync-<date>` containing the repo edit + the
   updated .sync/pending-slite-changes.json, with a PR body that quotes the
   comment (author + threadId) next to the suggested edit. If there are no repo
   changes and no unresolved comments, open NO PR.

Before you start, tell me: which Slite note + comment you found, what edit you
intend to make, and which repo file it maps to. Then proceed.

DO NOT run Routine B (the apply/resolve step) yet — I want to review the PR first.
```

### Routine B — `sync-apply` (after you merge the sync PR → writes + resolves)

```
The sync PR for the comment-driven GitHub↔Slite sync (repo jyep07/test-slite,
branch family `claude/sync-*`) is merged. Run Routine B (`sync-apply`) exactly as
specified in SYNC.md, with the Slite connector attached and SYNC_ALLOW_WRITES=1
set so the read-only guard permits Slite writes (body + comment resolves) for
this run only.

Steps (per SYNC.md):
1. Read .sync/pending-slite-changes.json (scanGitSha, to_slite, from_comments),
   plus state.json and slite-map.json.
2. Apply each to_slite entry to Slite: update-note / create-note (under the
   folder id from slite-map.json → folders, write the new noteId back) /
   archive-note (then drop the doc from slite-map.json → docs).
3. Apply each from_comments entry: read the now-merged repo file at `path` and
   `update-note(noteId, <that content>)` so the body matches the repo;
   `reply-to-comment-thread(threadId, "Applied in the sync PR — see <path>.")`;
   then `resolve-comment-thread(threadId)`. For any "needs clarification" item,
   reply asking for specifics and leave it unresolved.
4. Advance state.json: lastSyncedGitSha = scanGitSha (NOT HEAD); lastSyncedAt =
   now; for each doc in the union of to_slite + from_comments, set repoHash =
   `bash .sync/sync-detect.sh hash <repo file>` and sliteHash = re-fetch the note
   (get-note md → temp file → `sync-detect.sh hash`). Add creates, drop archives.
5. Reset .sync/pending-slite-changes.json to
   { "scanGitSha": "", "to_slite": [], "from_comments": [] }.
6. Commit state.json + slite-map.json + the reset queue to a NEW branch
   `claude/baseline-<YYYY-MM-DD-HHMM>` (must NOT contain "sync"), open a PR
   "Baseline update for <date>", and merge it yourself via the GitHub API.
   Do not commit to `main` directly.

Then report: which notes were updated, which comment threads were resolved, and
the new lastSyncedGitSha.
```

## Open / not yet done

- Live end-to-end demo (drop a real comment, run a Routine A pass) — not run yet.
- `state.json` is the seeded baseline from the prior Slite work; re-seed if it has
  drifted (see "Re-seeding" in `SYNC.md`).
- A separate `claude/doc-repo-sync` branch holds a Google Docs ↔ repo variant
  (Drive connector is read+create only; write-back needs a local session). Independent
  of this branch.
