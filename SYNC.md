# GitHub ↔ Slite sync (comment-driven) — design + runbook

Single source of truth for the two-way sync between this repo's markdown and the
Slite **SPACE TEST** folder. This is the only doc you need: design, the
`state.json` baseline model, the change rules, the Routine A/B prompts you paste
into the routine form, cost, and how to test. The repo travels between Claude
sessions; conversation memory does not — so everything needed is here.

_Last updated: 2026-06-29. Branch: `claude/slite-comment-sync` (off `main`)._

> **Start here in a fresh session:** check out `claude/slite-comment-sync`, read
> this file, confirm the Slite connector is attached, and do **all** work on this
> branch — never touch `main`.

## The model

Two-way sync that **scales with the number of changes, not the size of the repo.**
Human approval happens at one point: **merging the sync PR.** Two directions, two
different signals:

- **repo → Slite** — detected deterministically with `git diff` (no Slite calls),
  queued in `to_slite`, applied by Routine B (`update-note` / `create-note` /
  `archive-note`).
- **Slite → repo** — driven by **comments**, not body edits. A reviewer leaves a
  **comment** on a note describing the change (they do **not** edit the body).
  Routine A turns each **unresolved** thread into a proposed edit to the repo file
  (in the PR) plus a queued Slite body update + comment resolution
  (`from_comments`); Routine B applies both and resolves the thread.

```
 Git repo ──┐  sync-detect.sh: git diff <lastSyncedGitSha>..HEAD + hash      ┌─ open sync PR → human merges
            ├─ Routine A (read-only on Slite) ───────────────────────────────┤
 Slite ─────┘  list-comment-threads per note → unresolved threads → suggest  └─ Routine B applies git+Slite, resolves comments, advances state
```

## Why comment-driven (and why it replaced body-hash detection)

Earlier the Slite→repo side hash-swept **every** note body each run, because
Slite's edit timestamps (`updatedAt`, `lastEditedAt`, `list-recently-edited-notes`)
**do not reliably bump on a content edit** — so they couldn't be used to find which
notes changed, forcing a full export+hash of all N notes. Comments fix this:

- **Reliable signal.** Each thread carries a `resolved` flag. *Unresolved = pending;
  resolved = done.* No body hashing needed to decide what's outstanding.
- **Cheaper discovery.** `list-comment-threads` returns light metadata, not the
  body. Discovery is **O(N) light list calls**; only the **k** commented notes get a
  full read. (No space-wide "recent comments" feed exists in the Slite MCP, so the N
  light calls are the floor — but far cheaper than exporting+hashing every body.)
- **Explicit intent.** A comment states the change; anchored comments pin the exact
  target text. No diffing a body edit to guess what was meant.
- **Clean bodies.** The note body stays a faithful mirror of the repo — no
  formatting churn, no accidental two-sided drift.

**Complexity:** discovery **O(N)** light calls; processing **O(k)** (k = notes with
unresolved comments). Not literally O(k) end-to-end, but far cheaper than the old
full sweep.

## Why two routines

Routines run **autonomously — no approval prompt during a run**, and Claude can
write to Slite without asking. So the human gate is structural: the **sync PR merge**.

- **Routine A (`sync-plan`)** detects changes and proposes them, but does **not**
  touch live Slite. Comment-driven edits land as real file changes in the PR; the
  Slite-side write + comment resolution are queued in
  `.sync/pending-slite-changes.json` in the same PR.
- **Routine B (`sync-apply`)** runs *after the sync PR merges*, applies the queued
  Slite edits, resolves the comment threads, advances `state.json`, and
  **self-merges** its own bookkeeping ("baseline") PR.

### How "Routine A never writes" is enforced (not just instructed)

The connector **is** attached so Routine A can *read* Slite (including comments),
but writes are blocked at the harness level by a committed `PreToolUse` hook:

```
.claude/settings.json                  registers the hook on mcp__Slite__*
.claude/hooks/slite-readonly-guard.sh  default-deny: allow Slite read tools, deny the rest
```

The hook allows Slite **read** tools — including `list-comment-threads` and
`get-comment-thread-on-note` — and **denies everything else** under `mcp__Slite__*`
(`update-note`, `create-note`, `archive-note`, `resolve-comment-thread`,
`reply-to-comment-thread`, `create-comment-thread`, the block-edit tools, …) before
they run. The block lifts only when the environment sets `SYNC_ALLOW_WRITES=1`,
which **Routine B** does and **Routine A** does not.

| Routine | Env | Slite reads (incl. comments) | Slite writes (body + comment resolve) |
|---------|-----|------------------------------|----------------------------------------|
| A — plan / dry run | (none) | ✅ allowed | ⛔ blocked by hook |
| B — apply (after merge) | `SYNC_ALLOW_WRITES=1` | ✅ allowed | ✅ allowed |

The guard is identical on `main`, so it is active at session start even before a
routine checks out the working branch (see "Setting up the routines").

## Repo layout

```
SYNC.md                              this file — design + runbook + Routine A/B prompts
.sync/
  state.json                   the baseline: "last synced" source of truth (schema below)
  sync-detect.sh               deterministic repo-side detector + shared hash helper (no MCP)
  slite-map.json               repo path ↔ Slite noteId mapping (+ folder IDs, root, channel)
  pending-slite-changes.json   this round's accepted change-set, written by Routine A
                               (committed into the sync PR). Shape:
                               { "scanGitSha": "<sha A diffed against HEAD at>",
                                 "to_slite":      [ {action, path, noteId, newContent} ],  git→Slite, applied by B
                                 "from_comments": [ {noteId, threadId, path, author,
                                                     comment, anchoredText, summary} ] }   comment→both sides, applied+resolved by B
.claude/
  settings.json                registers the PreToolUse read-only guard on mcp__Slite__*
  hooks/slite-readonly-guard.sh  blocks Slite writes unless SYNC_ALLOW_WRITES=1
```

`pending-slite-changes.json` item shapes:
- `to_slite`: `{ action: "update"|"create"|"archive", path, noteId, newContent }`
- `from_comments`: `{ noteId, threadId, path, author, comment, anchoredText, summary }`,
  plus an optional `conflict: { repoDiff, sliteDiff, resolution, alternative }` block on
  items that reconcile a conflict (the merged repo file is still the source of truth for B)

## The baseline — `state.json`

`state.json` is the record of *what's already in sync*, so each run only reasons
about what changed since.

```json
{
  "lastSyncedGitSha": "<sha the repo side was last synced at>",
  "lastSyncedAt": "<ISO-8601 UTC — audit/logging only; NOT a detection gate>",
  "docs": {
    "planets/mars.md": { "noteId": "e_pXodM6RoMqi8", "repoHash": "<sha256>", "sliteHash": "<sha256>" }
  }
}
```

- **`lastSyncedGitSha` is the functional detection anchor** — `git diff
  <lastSyncedGitSha>..HEAD` defines "what's changed on the repo side," and
  `git show <lastSyncedGitSha>:<path>` is the conflict base. Change it and you change
  what the next run detects.
- **`lastSyncedAt` is informational only** — no code reads it to make a decision.
  Time is deliberately not used as a gate (Slite timestamps are unreliable).
- **repo changed** = `hash(current repo file) != docs[path].repoHash` (from `git diff`
  + hash).
- **slite body drifted** = `hash(current Slite md export) != docs[path].sliteHash` —
  **checked only as a conflict guard, only for notes that have an unresolved comment.**
  It is never swept across all notes, never used for discovery, and never compared to
  `repoHash`. A direct body edit on a note with no comment is therefore invisible to
  the system — which is why the convention is "comment, don't edit the body."

**Two hashes per doc**, not one, because repo markdown and Slite's md export differ
even after normalization — Slite rewrites smart quotes to straight, inserts a space
before some punctuation, and escapes `*` as `\*`. Each side is compared **only to its
own stored hash**, so those residual export artifacts never read as edits.

**How the baseline advances (the "baseline" PR).** Only Routine B moves it, after a
sync PR merges: set `lastSyncedGitSha = scanGitSha` (the sha Routine A diffed against,
**not** HEAD — so an unrelated edit made between scan and merge isn't hidden);
recompute `repoHash` + `sliteHash` for **only** the docs touched this cycle (add
creates, drop archives); commit to `claude/baseline-<date-time>` and self-merge. Each
cycle thus has two PRs: the **sync PR** (content, you review + merge) and the
**baseline PR** (bookkeeping, Routine B merges itself).

Mental model: *the baseline is "everything matches here." Detection = diff against the
baseline. A cycle = propose the diff (sync PR) → apply it → advance the baseline
(baseline PR).*

## Hashing & `sync-detect.sh`

Hashing is **normalized and identical on every side** (the single definition of "what
counts as a change" lives in `normhash` inside `sync-detect.sh`). It is
**formatting-insensitive but markup-preserving**:

- **Ignored (never a change):** leading/trailing whitespace; runs of spaces/tabs
  collapsed to one; blank lines; hard-wrapping (consecutive text / list-continuation
  lines reflowed into one logical line); table-cell padding and the dash-count in
  separator rows.
- **Preserved (a real change):** the words/characters themselves, and markdown markup
  — heading level, emphasis, list marker, blockquote, table pipes, links, code.

```
bash .sync/sync-detect.sh                 # (= detect) emit the repo-side change-set as JSON
bash .sync/sync-detect.sh detect          # same
bash .sync/sync-detect.sh hash FILE       # print the normalized content hash of one file
bash .sync/sync-detect.sh normalize FILE  # print the canonical (normalized) text — for review
bash .sync/sync-detect.sh selftest        # assert: formatting ignored, content/markup preserved
```

Always hash via `sync-detect.sh hash` — repo files directly, Slite exports by writing
the fetched md to a temp file first. `detect` reads `lastSyncedGitSha`, runs
`git diff --name-status -M <lastSyncedGitSha>..HEAD` over the doc folders (from
`slite-map.json`'s `folders`), hashes each changed file, and **drops no-op reverts**
(touched but normalized content still matches stored `repoHash`). Output is
`{ lastSyncedGitSha, headSha, lastSyncedAt, repoChanged[], note }`, each
`repoChanged[]` item `{ path, status (modified|added|deleted|renamed), noteId,
storedRepoHash, newRepoHash, renamedFrom }`. Pure shell + `git` + `python3`, **no MCP**.

## Change rules (per doc)

| repo (git diff) | unresolved comment on note | action |
|:---:|:---:|---|
| yes | no | git is source → **propose Slite body edit** (`to_slite`) |
| no | yes | comment is the request → **edit the repo file** (into the PR) **and** queue the Slite body edit + comment resolution (`from_comments`) |
| yes | yes | **conflict** → **propose a reconciliation**: apply a best-effort merged edit to the repo file (in the PR) + queue it, flagged for careful review |
| no | no | skip |
| new repo file | — | **create Slite note** under the right folder (`to_slite`, `action: "create"`); map updated by B |
| repo file deleted | — | **archive the Slite note** (`to_slite`, `action: "archive"`); B drops it from map + state |

**Direct body-edit guard (conflict base = git).** Before applying a comment-driven
edit, re-fetch the note body and hash it. If it ≠ the stored `sliteHash`, the body was
edited directly (against the convention) — treat it as a **conflict** and handle it
with the proposed-reconciliation rule below.

**Conflicts propose a fix, they don't just report.** On any conflict, Routine A
reconstructs the baseline (`git show <lastSyncedGitSha>:<path>`), builds a best-effort
**merged version of the repo file** (combine the git change and the comment's request;
on an overlapping span default to the comment's value and record the repo-side value as
an `alternative`), and **applies that merged version to the repo file** so it lands in
the PR diff. Agreeing then = merge the PR; disagreeing = edit the file on the branch
first. Routine A is still read-only on Slite — the proposal is a *git* edit, never a
Slite write. Only fall back to "needs clarification" (no file edit) when the two sides
are truly contradictory and no defensible merge exists.

## Conventions & gotchas

- **Comments = change requests; do not edit Slite bodies directly.** A direct body
  edit (body hash ≠ stored `sliteHash`) is a **conflict** — Routine A proposes a merged
  resolution as a concrete repo-file edit in the PR (accept = merge, or tweak first),
  never a silent Slite write.
- Human gate = sync-PR merge. Routine A read-only (enforced by the guard); Routine B
  writes with `SYNC_ALLOW_WRITES=1`.
- Routine B advances `lastSyncedGitSha = scanGitSha` (NOT HEAD); updates only the
  changed docs' hashes.
- Each side compared only to its own stored hash (`repoHash` vs `sliteHash`).
- Branch naming: Routine A → `claude/sync-<date>` (contains "sync" → triggers B on
  merge); Routine B → `claude/baseline-<date-time>` (must NOT contain "sync").

### Slite comment tools

- Reads (Routine A, allowed by guard): `list-comment-threads(noteId)` → threads +
  `resolved` flag; `get-comment-thread-on-note(noteId, threadId)`.
- Writes (Routine B, `SYNC_ALLOW_WRITES=1`): `resolve-comment-thread`,
  `reply-to-comment-thread`, `create-comment-thread`, targeted block edits
  (`modify-block` / `modify-range` / `remove-blocks`), `update-note`. Anchored
  comments appear inline in the note's sliteml as
  `<comment id="threadId">target text</comment>`.

### Gotcha: orphaned comments + full-body overwrites (learned the hard way)

- A full-body `update-note(noteId, <whole markdown>)` **regenerates every block and
  drops all `<comment>` anchors** on the note — orphaning even threads on text you
  didn't touch. Routine B therefore syncs bodies with **targeted** edits
  (`modify-block` / `modify-range` / `remove-blocks`), preserving `<comment id="…">`
  spans; full-body `update-note` only when the note has no threads.
- When the edit **deletes the exact text an anchored thread points at**, that thread
  becomes **orphaned**: Slite keeps it via the API (`resolved: true`, `archivedAt:
  null`, comments intact) but hides it from **both** the active and resolved sidebar
  views — it has no text to attach to. Unavoidable for delete-the-anchor requests;
  resolve order doesn't matter.
- So Routine B also leaves a **note-level (unanchored) confirmation comment**
  (`create-comment-thread` with no `blockId`/`sliteml`) quoting the request — it stays
  visible in the UI regardless. Git (the sync PR + commit) is the canonical audit trail.

---

## Routine A — `sync-plan`

**Trigger (tester):** manual **Run now** (add a daily schedule once proven).
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only  **Branch pushes:** `claude/` prefix is fine.
**Model:** Sonnet 4.6 recommended (see Cost & model selection).

**Prompt:**

> You are doing a two-way sync between this repo's docs and the Slite "SPACE TEST"
> folder (root note id `l9rKog-CwRTead`). This run is **read-only on Slite**: a
> PreToolUse hook blocks every Slite write tool (including comment resolves), so
> propose changes only — never apply them to Slite.
>
> **0. Check out the working branch first.** Routines clone `main`, but the
> comment-driven sync lives on `claude/slite-comment-sync` (`main` still carries the
> older body-hash version of `SYNC.md`/`sync-detect.sh`). Before doing anything else,
> run `git fetch origin claude/slite-comment-sync && git checkout claude/slite-comment-sync`.
> Do all work on this branch and never commit to `main`. (The read-only guard in
> `.claude/settings.json` is identical on `main`, so it is already active at session
> start — the checkout just swaps in the correct comment-driven tooling and state.)
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
> - **conflict — both repo changed AND an unresolved comment on the same doc** →
>   **propose a reconciliation; do not report-only.** Reconstruct the baseline with
>   `git show <lastSyncedGitSha>:<path>`. Build a **proposed merged version of the repo
>   file** that takes the git change and the comment's requested change together: apply
>   both where they touch different text; where they touch the **same** span, default
>   the file to the **comment's** value (it's an explicit human request) and keep the
>   repo-side value as `alternative` so the reviewer can swap it back in one edit.
>   **Apply that merged version to the repo file** (it lands in the PR diff). Then append
>   to `from_comments`, adding a `conflict` block:
>   `{ "noteId", "threadId", "path", "author", "comment": "<verbatim>",
>      "anchoredText": "<target snippet or null>", "summary": "<the merge in one line>",
>      "conflict": { "repoDiff": "<base→repo unified diff>",
>                    "sliteDiff": "<base→body diff, or the comment's intent>",
>                    "resolution": "<one line: how you merged>",
>                    "alternative": "<repo-side value for any overlapping span, or null>" } }`.
>   Only fall back to "needs clarification" (leave the file untouched) if the two sides
>   are truly contradictory and no defensible merge exists — say why in the PR body.
> - **direct body-edit guard** → for each note with an unresolved comment, hash its
>   current md export (`get-note` md → temp file → `bash .sync/sync-detect.sh hash`).
>   If it ≠ `sliteHash` in `state.json`, the body was edited directly → treat it as a
>   **conflict** and handle it with the proposed-reconciliation rule above: `sliteDiff`
>   is the base→body diff, the merged file you propose will overwrite the direct body
>   edit on the Slite side once merged, so fold anything worth keeping from base→body
>   into the proposed file. (Routine A still writes nothing to Slite — only the repo
>   file in the PR.)
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
> **6. Open the PR.** Create branch `claude/sync-<YYYY-MM-DD>` **off
> `claude/slite-comment-sync`**, commit the repo-side edits (comment-driven file edits,
> **conflict-reconciliation file edits**, new/deleted files) plus the updated
> `.sync/pending-slite-changes.json` (`scanGitSha` = step 1's `headSha`), and open a PR
> **with base branch `claude/slite-comment-sync` (NOT `main`)**. The PR body must list,
> per doc, the direction (git→Slite, comment→both, or conflict). For each comment-driven
> item quote the comment + author + threadId. For each **conflict**, add a clearly-headed
> **"⚠ Proposed conflict resolution — review carefully"** block showing: the `repoDiff`
> (base→repo), the comment (author + threadId), the `sliteDiff` (base→body) when a direct
> edit was involved, the **proposed merged result now in the file**, and a one-line note
> on how to tweak it (edit the file on this branch before merging, or swap in the
> `alternative` value). Make clear the proposal is a real file edit, so **agree = merge;
> disagree = edit then merge** — and that merging it lets Routine B overwrite the Slite
> body to match. Do **not** modify `.sync/state.json` and do **not** write to Slite —
> those happen only after merge (Routine B).

## Routine B — `sync-apply`

**Trigger:** GitHub event → `pull_request.closed`, filters: **is merged = true**,
**head branch contains `sync`**.
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only
**Environment:** set **`SYNC_ALLOW_WRITES=1`** so the read-only guard permits Slite
writes (body + comment resolves) for this routine. Use a dedicated environment; do
not add this var to Routine A's.
**Permissions:** Routine B **merges its own bookkeeping PR via the GitHub API**.
**Model:** Opus 4.8 recommended (see Cost & model selection).

**Prompt:**

> A sync PR was just merged.
>
> **0. Check out the working branch first.** Routines clone `main`, but the merged
> sync content and the comment-driven tooling live on `claude/slite-comment-sync`
> (the sync PR merged *into* that branch, not `main`). Run
> `git fetch origin claude/slite-comment-sync && git checkout claude/slite-comment-sync`
> before anything else, and do all work there — never commit to `main`.
>
> Then read `.sync/pending-slite-changes.json` — it has `scanGitSha`, `to_slite`
> (git→Slite changes), and `from_comments` (comment-driven edits already applied to
> the repo files in this PR), plus `.sync/state.json` and `.sync/slite-map.json`.
>
> 1. **Apply each `to_slite` entry to Slite:** for `"update"`, sync the body with a
>    **targeted block edit** — `get-note(noteId, sliteml)`, then `modify-block` /
>    `modify-range` / `remove-blocks` on only the blocks that differ from the merged
>    repo file, preserving every `<comment id="…">` anchor. Fall back to a full-body
>    `update-note` only when the note has **no** comment threads (a full-body overwrite
>    regenerates all blocks and drops every comment anchor — see step 2's note).
>    `create-note` (under the folder id from `slite-map.json` → `folders`) for
>    `"create"`, writing the new noteId back into `slite-map.json` → `docs` and the
>    entry; `archive-note` for `"archive"`, then remove that doc from
>    `slite-map.json` → `docs`.
> 2. **Apply each `from_comments` entry (targeted body edit → durable confirmation → resolve):**
>    - **Sync the body with a targeted block edit, not a full-document overwrite.**
>      `get-note(noteId, sliteml)`, find the block(s) that differ from the now-merged
>      repo file at `path`, and apply only those with `modify-block` / `modify-range`
>      (or `remove-blocks` for a pure deletion), preserving every `<comment id="…">`
>      span on blocks you rewrite. Do **not** `update-note` the whole body: it
>      regenerates all blocks and drops every comment anchor, orphaning even threads on
>      text you didn't touch. (Full-body `update-note` is acceptable only if the note
>      has no comment threads at all.)
>    - `reply-to-comment-thread(threadId, "Applied in the sync PR — see <path>.")` on the
>      original thread, then `resolve-comment-thread(threadId)` so the request is closed
>      and never reprocessed. (For any "needs clarification" item from the PR body,
>      instead `reply-to-comment-thread` asking for specifics, leave it unresolved, and
>      skip the body edit + confirmation for that doc.)
>
>    > **Why the unanchored confirmation:** when the edit *deletes* the text an anchored
>    > thread points at, the thread becomes **orphaned** — Slite keeps it via the API
>    > (`resolved: true`, not archived) but drops it from *both* the active and resolved
>    > sidebar views, since it has no text to attach to (resolving earlier or later
>    > doesn't change this). The global confirmation thread stays visible regardless;
>    > git (the sync PR + commit) remains the canonical audit trail.
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
>    **new branch `claude/baseline-<YYYY-MM-DD-HHMM>`** (must NOT contain "sync") cut
>    **off `claude/slite-comment-sync`**, open a PR "Baseline update for <date>"
>    **with base branch `claude/slite-comment-sync` (NOT `main`)**, then **merge it
>    yourself via the GitHub API** (`merge_pull_request`). Never commit to or target
>    `main`.
>
> Advancing `lastSyncedGitSha` to `scanGitSha` (not HEAD) is deliberate: a blanket
> advance to HEAD would hide an unrelated repo edit made between Routine A's scan and
> this merge. Comment-side stragglers need no such care — an unresolved thread is
> simply picked up on the next run.

---

## Setting up the routines

**Prerequisites**
1. **Add Slite as a claude.ai connector** at claude.ai/customize/connectors — a
   routine can't use a CLI-only MCP server.
2. **Install the Claude GitHub App** on `jyep07/test-slite` — required for Routine B's
   PR-merge trigger and its API self-merge.
3. Default "Trusted" network access is sufficient; Slite traffic routes through Anthropic.

**No branch picker — select the branch in the prompt.** The routine form has no
branch field; routines always clone the repo's **default branch (`main`)** and Claude
makes `claude/`-prefixed branches. That's why both prompts above start with **step 0**:
`git fetch origin claude/slite-comment-sync && git checkout claude/slite-comment-sync`.
The read-only guard is identical on `main`, so it's active from the first tool call;
the checkout just swaps in the correct comment-driven tooling and state. Every branch
in play (`claude/slite-comment-sync`, `claude/sync-*`, `claude/baseline-*`) is
`claude/`-prefixed, so the default "claude/ only" push restriction is sufficient — you
do **not** need "Allow unrestricted branch pushes." Keep the sync PR base and baseline
PR base at `claude/slite-comment-sync` so nothing ever targets `main`.

## Cost & model selection

**Recommended split:** Routine A on **Sonnet 4.6** (it only proposes a PR you review,
so a mistake is caught at the gate), Routine B on **Opus 4.8** (it writes to live Slite
and does the fiddly targeted-sliteml edits — keep it on the strongest model; the
anchor-preserving logic depends on getting block edits right). Avoid **Haiku** on
Routine B specifically — it's materially more likely to drop a `<comment>` anchor or
emit invalid sliteml, and it can't use the `effort` knob. Haiku is defensible for
Routine A only (gated, read-only) if cost is critical.

**Token cost** (per cycle, Sonnet-A / Opus-B, caching applied; ±2-3× estimates). 0
changes = no PR, so Routine B never fires:

| Changes | Routine A (Sonnet) | Routine B (Opus) | Combined |
|---|---|---|---|
| 0  | ~$0.15 | $0 | **~$0.15** |
| 5  | ~$0.65 | ~$1.20 | **~$1.5–3** |
| 20 | ~$2.5 | ~$5 | **~$6–12** |
| 50 | ~$7 | ~$15 | **~$18–30** |

Cost is superlinear in change count (each change lengthens the transcript every later
turn re-sends) and scales with **N (mapped docs)** for the O(N) comment sweep. Levers:
run Routine A less often (it pays the baseline + O(N) sweep every fire — even a quiet
run consumes a daily-cap slot), **batch** large change sets into smaller daily passes,
and lower `effort` / model tier where safe.

**Seat cost.** Routines are a claude.ai subscription feature and belong to the
individual account — **one** Claude Code–enabled seat covers **both** routines (no
per-routine charge). Qualifying seats: **Pro ($20/mo)** — cheapest, fine for light
volume; **Max ($100 / $200 mo)** — for usage headroom on heavy 20–50-change cycles;
**Team Premium ($100–125/seat, min 5)** — note Team **Standard** excludes Claude Code;
**Enterprise** — premium or Chat + Claude Code seats. Under a seat there's no per-token
charge until you hit the plan's usage limit or the daily routine-run cap; past that,
runs are rejected (or spill to metered token overage at the rates above if usage
credits are on). _Seat prices as of 2026-06; confirm at claude.ai/upgrade._

## Testing it / supervised first run

For the first run, drive it by hand and gate Routine B:

1. Create **Routine A** only, trigger = manual.
2. **Leave a comment** on one Slite note (e.g. on the Saturn note: anchor a comment to
   a value and write the correction). Optionally also edit a repo file to exercise the
   git→Slite direction.
3. **Run now.** Before applying anything, have the run report which note + comment it
   found, the intended edit, and the repo file it maps to. Confirm the PR: the
   comment-driven doc shows a repo edit + a `from_comments` entry quoting the comment;
   a git-only change shows a `to_slite` entry. A quiet run (no repo changes, no
   unresolved comments) must open **no** PR. **Do not run Routine B yet** — review the PR.
4. Add **Routine B** + the merge trigger, merge the sync PR, and verify: the Slite note
   body updated, **the comment thread is resolved** (and replied to) with a note-level
   confirmation comment present, `state.json` advanced (`lastSyncedGitSha` =
   `scanGitSha`, hashes updated for the changed docs only), and the baseline PR
   auto-merged.

## Re-seeding `state.json` (if it drifts)

When the recorded hashes no longer reflect reality (e.g. both sides were edited
out-of-band), re-seed without running a full cycle: for each affected doc in
`slite-map.json` → `docs`, set `repoHash` = hash of the repo file and `sliteHash` =
hash of the note's current md export (both via `sync-detect.sh hash`). A full re-seed
does this for every doc, with `lastSyncedGitSha` = the seed commit and `lastSyncedAt` =
seed time.

## Open / not yet done

- Live end-to-end demo run through Routine B (apply + resolve) — a Routine A dry run
  has been exercised (Saturn "can delete." → PR); the full B apply on a fresh comment
  is still the next validation.
- A separate `claude/doc-repo-sync` branch holds a Google Docs ↔ repo variant (Drive
  connector is read+create only; write-back needs a local session). Independent of this
  branch.
