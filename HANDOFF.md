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
  `update-note` (body). Anchored comments appear inline in the note's sliteml as
  `<comment id="threadId">target text</comment>`.

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

## Open / not yet done

- Live end-to-end demo (drop a real comment, run a Routine A pass) — not run yet.
- `state.json` is the seeded baseline from the prior Slite work; re-seed if it has
  drifted (see "Re-seeding" in `SYNC.md`).
- A separate `claude/doc-repo-sync` branch holds a Google Docs ↔ repo variant
  (Drive connector is read+create only; write-back needs a local session). Independent
  of this branch.
