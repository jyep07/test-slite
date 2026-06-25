# GitHub ↔ Slite sync routine (v2 — change detection, comment-driven)

A tester setup for keeping this repo's docs and the Slite **SPACE TEST** folder in
sync. **It scales with the number of changes, not the size of the repo.** Human
approval happens at a single point: **merging the sync PR**.

Two directions, two different signals:

- **repo → Slite** — detected deterministically with `git diff` (no Slite calls).
- **Slite → repo** — driven by **comments**, not body edits. Reviewers leave a
  comment on a note describing the change they want; Routine A turns each
  **unresolved** comment thread into a proposed edit to *both* the repo file and
  the Slite note; Routine B applies both and **resolves the comment**.

```
 Git repo ──┐  sync-detect.sh: git diff <lastSyncedGitSha>..HEAD + hash      ┌─ open sync PR → human merges
            ├─ Routine A (read-only on Slite) ───────────────────────────────┤
 Slite ─────┘  list-comment-threads per note → unresolved threads → suggest  └─ Routine B applies git+Slite, resolves comments, advances state
```

## Why comment-driven (and why it replaced body-hash detection)

Earlier the Slite→repo side hash-swept **every** note body each run, because
Slite's edit timestamps (`updatedAt`, `lastEditedAt`, `list-recently-edited-notes`)
**do not reliably bump on a content edit** — so they couldn't be used to find
which notes changed, forcing a full export+hash of all N notes.

Comments fix this at the source:

- **Reliable signal.** Each comment thread carries a `resolved` flag. *Unresolved
  = a pending request; resolved = done.* No hashing of bodies needed to decide
  what's outstanding.
- **Cheaper discovery.** `list-comment-threads` returns thread metadata (small),
  not the full note body. Discovery is **O(N) light list calls**; only the **k**
  notes that actually have unresolved comments get a full read. (There is no
  space-wide "recent comments" feed in the Slite MCP, so the N light calls are the
  floor — but they are far cheaper than exporting+hashing every body.)
- **Explicit intent.** A comment states the change ("NASA lists 6,792 km — please
  update"); no need to diff a body edit to guess what was meant. Anchored comments
  even pin the exact target text.
- **Clean bodies.** The note body stays a faithful mirror of the repo — no
  formatting churn, no accidental two-sided drift.

> **Convention:** reviewers **comment** to request a change; they do **not** edit
> note bodies directly. Routine A applies the change to both sides, so the body
> ends up matching the repo automatically once the cycle completes. (Routine A
> still guards against a stray direct body edit — see the conflict rules.)

## Why two routines

Routines run **autonomously — no approval prompt during a run**, and Claude can
write to Slite without asking. So the human gate is structural: the **sync PR merge**.

- **Routine A (`sync-plan`)** detects changes and proposes them, but does **not**
  touch live Slite. **Slite→repo** edits (from comments) land as real file changes
  in the PR; the Slite-side write + comment-resolution are queued in
  `.sync/pending-slite-changes.json` in the same PR.
- **Routine B (`sync-apply`)** runs *after the sync PR merges*, applies the queued
  Slite edits, **resolves the comment threads**, advances `state.json`, and
  **self-merges** its own bookkeeping PR.

### How "Routine A never writes" is enforced (not just instructed)

The connector **is** attached so Routine A can *read* Slite (including comments),
but writes are blocked at the harness level by a committed `PreToolUse` hook:

```
.claude/settings.json                  registers the hook on mcp__Slite__*
.claude/hooks/slite-readonly-guard.sh  default-deny: allow Slite read tools, deny the rest
```

The hook allows Slite **read** tools — including **`list-comment-threads`** and
**`get-comment-thread-on-note`** — and **denies everything else** under
`mcp__Slite__*`, so `update-note`, `create-note`, `archive-note`, and the comment
*write* tools (`resolve-comment-thread`, `reply-to-comment-thread`,
`create-comment-thread`, …) are blocked before they run. The block is lifted only
when the environment sets `SYNC_ALLOW_WRITES=1`, which **Routine B** does and
**Routine A** does not.

| Routine | Env | Slite reads (incl. comments) | Slite writes (body + comment resolve) |
|---------|-----|------------------------------|----------------------------------------|
| A — plan / dry run | (none) | ✅ allowed | ⛔ blocked by hook |
| B — apply (after merge) | `SYNC_ALLOW_WRITES=1` | ✅ allowed | ✅ allowed |

## Repo layout

```
.sync/
  state.json                   the single source of truth for "last synced" (see schema below)
  sync-detect.sh               deterministic repo-side detector + shared hash helper (no MCP)
  slite-map.json               repo path ↔ Slite noteId mapping (+ folder IDs, root, channel)
  pending-slite-changes.json   this round's accepted change-set, written by Routine A
                               (committed into the sync PR). Shape:
                               { "scanGitSha": "<sha A diffed against HEAD at>",
                                 "to_slite":      [ {action, path, noteId, newContent} ],  git→Slite, applied by B
                                 "from_comments": [ {noteId, threadId, path, author,
                                                     comment, anchoredText, summary} ] }   comment→both sides, applied+resolved by B
                               Routine B uses both lists to write Slite, resolve threads, advance state.json, then resets it.
.claude/
  settings.json                registers the PreToolUse read-only guard on mcp__Slite__*
  hooks/slite-readonly-guard.sh  blocks Slite writes (incl. comment resolves) unless SYNC_ALLOW_WRITES=1
```

### `state.json` schema

```json
{
  "lastSyncedGitSha": "<sha the repo side was last synced at>",
  "lastSyncedAt": "<ISO-8601 UTC — audit/logging only; NOT a detection gate>",
  "docs": {
    "planets/mars.md": { "noteId": "e_pXodM6RoMqi8", "repoHash": "<sha256>", "sliteHash": "<sha256>" }
  }
}
```

- **repo changed** = `hash(current repo file) != docs[path].repoHash`  (from `git diff` + hash)
- **slite body drifted** = `hash(current Slite md export) != docs[path].sliteHash`  (only checked for
  notes that have an unresolved comment, as a conflict guard — *not* swept across all notes)

Two hashes per doc (not one shared) because repo markdown and Slite's md export
still differ even after normalization — Slite rewrites smart quotes to straight,
inserts a space before some punctuation, and escapes `*` as `\*`. Comparing each
side only to its own stored hash means those residual export artifacts never read
as edits.

**Hashing is normalized and identical on every side** (the single definition of
"what counts as a change" lives in `normhash` inside `sync-detect.sh`). It is
**formatting-insensitive but markup-preserving**:

- **Ignored (formatting, never a change):** leading/trailing whitespace; runs of
  spaces/tabs collapsed to one; blank lines; hard-wrapping (consecutive text /
  list-continuation lines reflowed into one logical line); table-cell padding and
  the dash-count in separator rows.
- **Preserved (a real change):** the words/characters themselves, and markdown
  markup — heading level, emphasis, list marker, blockquote, table pipes, links, code.

Always hash via `bash .sync/sync-detect.sh hash <file>` — repo files directly,
Slite exports by writing the fetched md to a temp file first. Run
`bash .sync/sync-detect.sh selftest` to see the rules asserted.

## `sync-detect.sh`

```
bash .sync/sync-detect.sh                 # (= detect) emit the repo-side change-set as JSON
bash .sync/sync-detect.sh detect          # same
bash .sync/sync-detect.sh hash FILE       # print the normalized content hash of one file
bash .sync/sync-detect.sh normalize FILE  # print the canonical (normalized) text — for review
bash .sync/sync-detect.sh selftest        # assert: formatting ignored, content/markup preserved
```

`detect` reads `lastSyncedGitSha` from `state.json`, runs
`git diff --name-status -M <lastSyncedGitSha>..HEAD` over the doc folders (from
`slite-map.json`'s `folders`), hashes each changed file, and **drops no-op reverts**
(a file touched in a commit but whose normalized content still matches its stored
`repoHash`). Output is `{ lastSyncedGitSha, headSha, lastSyncedAt, repoChanged[], note }`,
where each `repoChanged[]` item is `{ path, status (modified|added|deleted|renamed),
noteId, storedRepoHash, newRepoHash, renamedFrom }`. Pure shell + `git` + `python3`,
**no MCP**, so Routine A can run it deterministically before touching Slite.

## Change rules (per doc)

| repo (git diff) | unresolved comment on note | action |
|:---:|:---:|---|
| yes | no | git is source → **propose Slite body edit** (`to_slite`) |
| no | yes | comment is the request → **edit the repo file** (into the PR) **and** queue the Slite body edit + comment resolution (`from_comments`) |
| yes | yes | **conflict** → report in PR body, change nothing automatically |
| no | no | skip |
| new repo file | — | **create Slite note** under the right folder (`to_slite`, `action: "create"`); map updated by B |
| repo file deleted | — | **archive the Slite note** (`to_slite`, `action: "archive"`); B drops it from map + state |

**Direct body-edit guard (conflict base = git).** Before applying a comment-driven
edit, re-fetch the note body and hash it. If it ≠ the stored `sliteHash`, someone
edited the body directly (against the convention) — treat it as a **conflict**:
reconstruct the base with `git show <lastSyncedGitSha>:<path>` and report the
base→repo and base→body diffs in the PR; do not auto-apply. Report only.

---

## Routine A — `sync-plan`

**Trigger (tester):** manual **Run now** (add a daily schedule once proven).
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only  **Branch pushes:** `claude/` prefix is fine.

**Prompt:**

> You are doing a two-way sync between this repo's docs and the Slite "SPACE TEST"
> folder (root note id `l9rKog-CwRTead`). This run is **read-only on Slite**: a
> PreToolUse hook blocks every Slite write tool (including comment resolves), so
> propose changes only — never apply them to Slite.
>
> **1. Detect repo-side changes (deterministic, no Slite calls).** Run
> `bash .sync/sync-detect.sh detect`. Trust its `repoChanged[]` for the repo side —
> do **not** re-scan files yourself.
>
> **2. Collect Slite comments (the Slite→repo signal).** For **every** doc in
> `.sync/slite-map.json` → `docs`, call `list-comment-threads` on its noteId. Keep
> only threads where `resolved` is false. (This is O(N) light list calls; skip the
> bodies.) For each unresolved thread, note its `threadId`, the comment text(s), the
> author, and — if the thread is anchored — the target snippet (the thread
> `highlight`, or the `<comment id="…">target text</comment>` span you'll see when
> you `get-note` the note in sliteml). Only `get-note` the **k** notes that have
> unresolved threads; do not fetch the rest.
>
> **3. Apply the change rules**, recording every accepted change in
> `.sync/pending-slite-changes.json`
> (shape `{ "scanGitSha": "<headSha from step 1>", "to_slite": [...], "from_comments": [...] }`):
> - **repo changed only** → append to `to_slite`:
>   `{ "action": "update", "path": "<path>", "noteId": "<id>", "newContent": "<full repo file text>" }`.
> - **unresolved comment, repo NOT changed** → interpret the comment into a concrete
>   edit. **Apply it to the repo file** (this lands in the PR as a normal git edit).
>   Then append to `from_comments`:
>   `{ "noteId", "threadId", "path", "author", "comment": "<verbatim>",
>      "anchoredText": "<target snippet or null>", "summary": "<the change in one line>" }`.
>   If the comment is too vague to act on safely, do **not** edit anything — record
>   it in the PR body as "needs clarification" (Routine B can reply asking for
>   specifics) and leave the thread for next time.
> - **both repo changed AND an unresolved comment on the same doc** → conflict: change
>   nothing; reconstruct the base with `git show <lastSyncedGitSha>:<path>` and record
>   the conflict in the PR body only.
> - **direct body-edit guard** → for each note with an unresolved comment, hash its
>   current md export (`get-note` md → temp file → `bash .sync/sync-detect.sh hash`).
>   If it ≠ `sliteHash` in `state.json`, the body was edited directly → conflict;
>   report, don't apply.
> - **new repo file** (`status: added`, not in the map) → `to_slite` with
>   `"action": "create"` (target folder id from `slite-map.json` → `folders`; leave
>   `noteId` empty for B).
> - **repo file deleted** (`status: deleted`) → `to_slite` with `"action": "archive"`
>   and the doc's `noteId`.
>
> **4. No-op check.** If `repoChanged` is empty, there are no unresolved comments, and
> no conflicts, STOP: do not create a branch, commit, or open a PR. End the run.
>
> **5. Stale-cycle guard.** Check open PRs. If any open PR's head branch starts with
> `claude/sync-` or `claude/baseline-`, STOP — a prior cycle hasn't finished. End the run.
>
> **6. Open the PR.** Create branch `claude/sync-<YYYY-MM-DD>`, commit the repo-side
> edits (comment-driven file edits, new/deleted files) plus the updated
> `.sync/pending-slite-changes.json` (`scanGitSha` = step 1's `headSha`), and open a PR.
> The PR body must list, per doc, the direction (git→Slite, comment→both, or conflict),
> and for each comment-driven item quote the comment + author + threadId so the reviewer
> can sanity-check the suggestion. Do **not** modify `.sync/state.json` and do **not**
> write to Slite — those happen only after merge (Routine B).

## Routine B — `sync-apply`

**Trigger:** GitHub event → `pull_request.closed`, filters: **is merged = true**,
**head branch contains `sync`**.
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only
**Environment:** set **`SYNC_ALLOW_WRITES=1`** so the read-only guard permits Slite
writes (body + comment resolves) for this routine. Use a dedicated environment; do
not add this var to Routine A's.
**Permissions:** Routine B **merges its own bookkeeping PR via the GitHub API**.

**Prompt:**

> A sync PR was just merged. Read `.sync/pending-slite-changes.json` — it has
> `scanGitSha`, `to_slite` (git→Slite changes), and `from_comments` (comment-driven
> edits already applied to the repo files in this PR), plus `.sync/state.json` and
> `.sync/slite-map.json`.
>
> 1. **Apply each `to_slite` entry to Slite:** `update-note` for `"update"`;
>    `create-note` (under the folder id from `slite-map.json` → `folders`) for
>    `"create"`, writing the new noteId back into `slite-map.json` → `docs` and the
>    entry; `archive-note` for `"archive"`, then remove that doc from
>    `slite-map.json` → `docs`.
> 2. **Apply each `from_comments` entry (both sides + resolve):**
>    - Read the now-merged repo file at `path` and `update-note(noteId, <that content>)`
>      so the Slite body matches the repo.
>    - `reply-to-comment-thread(threadId, "Applied in the sync PR — see <path>.")`
>      (optional but recommended for an audit trail).
>    - `resolve-comment-thread(threadId)` so the request is closed and never
>      reprocessed. (For any "needs clarification" item from the PR body, instead
>      `reply-to-comment-thread` asking for specifics and leave it unresolved.)
> 3. **Advance `state.json`:**
>    - Set `lastSyncedGitSha` = `scanGitSha` (the sha Routine A diffed against — **not**
>      HEAD), so any unrelated repo doc edited between the scan and this merge is still
>      caught next run (then filtered by hash).
>    - Set `lastSyncedAt` = now (ISO-8601 UTC) — informational only.
>    - For each doc in the union of `to_slite` and `from_comments`, update `docs[path]`:
>      `repoHash` = `bash .sync/sync-detect.sh hash <repo file>`, and `sliteHash` =
>      re-fetch the note (`get-note`, markdown) → temp file →
>      `bash .sync/sync-detect.sh hash`. Add new docs (creates); delete archived docs.
>      Do **not** touch any other doc's entry.
> 4. **Reset** `.sync/pending-slite-changes.json` to
>    `{ "scanGitSha": "", "to_slite": [], "from_comments": [] }`.
> 5. **Commit** the updated `state.json`, `slite-map.json`, and reset change-set to a
>    **new branch `claude/baseline-<YYYY-MM-DD-HHMM>`** (must NOT contain "sync"),
>    open a PR "Baseline update for <date>", then **merge it yourself via the GitHub
>    API** (`merge_pull_request`). Do not commit to `main` directly.
>
> Advancing `lastSyncedGitSha` to `scanGitSha` (not HEAD) is deliberate: a blanket
> advance to HEAD would hide an unrelated repo edit made between Routine A's scan and
> this merge. Comment-side stragglers need no such care — an unresolved thread is
> simply picked up on the next run.

---

## Prerequisites

1. **Add Slite as a claude.ai connector** at claude.ai/customize/connectors — a
   routine can't use a CLI-only MCP server.
2. **Install the Claude GitHub App** on `jyep07/test-slite` — required for Routine B's
   PR-merge trigger and its API self-merge.
3. Default "Trusted" network access is sufficient; Slite traffic routes through Anthropic.

## Testing it

1. Create **Routine A** only, trigger = manual.
2. **Leave a comment** on one Slite note (e.g. on the Saturn note: anchor a comment to
   a value and write the correction). Optionally also edit a repo file to exercise the
   git→Slite direction.
3. **Run now** → confirm the PR: the comment-driven doc shows a repo edit + a
   `from_comments` entry quoting the comment; a git-only change shows a `to_slite`
   entry. A quiet run (no repo changes, no unresolved comments) must open **no** PR.
4. Add **Routine B** + the merge trigger, merge the sync PR, and verify: the Slite note
   body updated, **the comment thread is resolved** (and replied to), `state.json`
   advanced (`lastSyncedGitSha` = `scanGitSha`, hashes updated for the changed docs
   only), and the baseline PR auto-merged.

## Re-seeding `state.json` (if it ever drifts)

For each doc in `slite-map.json` → `docs`, `repoHash` = hash of the repo file,
`sliteHash` = hash of the note's current md export (both via `sync-detect.sh hash`),
with `lastSyncedGitSha` = the seed commit and `lastSyncedAt` = seed time.
