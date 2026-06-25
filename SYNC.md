# GitHub ↔ Slite sync routine (v2 — change detection)

A tester setup for keeping this repo's docs and the Slite **SPACE TEST** folder in
sync. **v2 scales with the number of changes, not the size of the repo.** Each side
detects what changed since the last sync instead of re-reading everything; human
approval still happens at a single point: **merging the sync PR**.

```
 Git repo ──┐  sync-detect.sh: git diff <lastSyncedGitSha>..HEAD + hash   ┌─ open sync PR  → human merges
            ├─ Routine A (change detect, read-only on Slite) ─────────────┤
 Slite ─────┘  get-note per mapped note → hash vs sliteHash             └─ Routine B applies + advances state.json (self-merged PR)
```

## What changed from v1 (and why)

v1's Routine A did a **full O(N) scan every run**: it read 48 files (16 docs ×
`repo` + `baseline/` + `baseline-slite/`) and fetched all 16 Slite notes, then
diffed all of it in one context. At 16 docs it was already slow (10+ min) and
sometimes failed; it did not scale.

v2 removes the heavy parts of the scan:

| Per run | v1 | v2 |
|---|---|---|
| Baseline file reads | 32 | **0** — hashes live in `state.json` |
| Slite note fetches | 16 (all) | 16 (all) — fetch + hash, but **store only a hash, no big-context diff** |
| Repo file reads | 16 (all) | **only files in `git diff <sha>..HEAD`** |
| Single-context diff of everything | yes (the bottleneck) | **no** — per-doc hash compare |

The two content baseline trees (`.sync/baseline/`, `.sync/baseline-slite/`) are
**gone**, replaced by a single `.sync/state.json` holding one hash per side per doc.

> **Why the Slite side still fetches every note.** The original v2 plan filtered
> Slite reads by `updatedAt > lastSyncedAt`. Testing showed Slite's edit timestamps
> (`updatedAt`, `lastEditedAt`, and `list-recently-edited-notes`) **do not reliably
> bump on a content edit** — a real edit to a note left all three frozen, so the
> filter silently skipped it. The hash is the only trustworthy signal, so Routine A
> **fetches every mapped note and hash-compares** it to `sliteHash`. The repo side is
> still O(changes) via `git diff`; the Slite side is O(N) *fetches* but still O(1)
> *storage* (one hash per note) and avoids v1's real cost — loading every doc into one
> context to diff. `lastSyncedAt` is kept for audit/logging but is no longer a gate.

## Why two routines (unchanged from v1)

Routines run **autonomously — there is no approval prompt during a run**, and Claude
can write to Slite without asking. So the human gate has to be structural. We use the
**sync PR merge** as that gate:

- **Routine A (`sync-plan`)** detects changes and proposes them, but does **not**
  touch live Slite. **Slite→repo** edits land as real file changes in the PR;
  **repo→Slite** edits are queued in `.sync/pending-slite-changes.json` in the same PR.
- **Routine B (`sync-apply`)** runs *after the sync PR merges*, applies the approved
  Slite edits, advances `state.json`, and **self-merges** its own bookkeeping PR.

### How "Routine A never writes" is enforced (not just instructed)

The connector **is** attached so Routine A can *read* Slite, but writes are blocked at
the harness level by a committed `PreToolUse` hook — it does not rely on the prompt:

```
.claude/settings.json                  registers the hook on mcp__Slite__*
.claude/hooks/slite-readonly-guard.sh  default-deny: allow Slite read tools, deny the rest
```

The hook allows a known list of Slite **read** tools (`get-note`, `get-note-children`,
`search-notes`, `list-*`, `ask-slite`, …) and **denies everything else** under
`mcp__Slite__*` — so create/update/append/modify/remove/move/archive (and any *future*
Slite write tool) are blocked before they run. The block is lifted only when the
environment sets `SYNC_ALLOW_WRITES=1`, which **Routine B** does and **Routine A** does not.

| Routine | Env | Slite reads | Slite writes |
|---------|-----|-------------|--------------|
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
                                 "to_slite":   [ {path, noteId, action, newContent} ],   git→Slite, applied by B
                                 "from_slite": [ {path, noteId} ] }                       Slite→git, already in the PR
                               Routine B uses both lists to advance state.json, then resets it.
.claude/
  settings.json                registers the PreToolUse read-only guard on mcp__Slite__*
  hooks/slite-readonly-guard.sh  blocks Slite writes unless SYNC_ALLOW_WRITES=1
```

### `state.json` schema

```json
{
  "lastSyncedGitSha": "<sha the repo side was last synced at>",
  "lastSyncedAt": "<ISO-8601 UTC — audit/logging only; NOT a detection gate (see note above)>",
  "docs": {
    "planets/mars.md": { "noteId": "e_pXodM6RoMqi8", "repoHash": "<sha256>", "sliteHash": "<sha256>" }
  }
}
```

- **repo changed** = `hash(current repo file) != docs[path].repoHash`
- **slite changed** = `hash(current Slite md export) != docs[path].sliteHash`

Two hashes per doc (not one shared hash) because repo markdown and Slite's md export
still differ even after normalization — Slite rewrites smart quotes to straight,
inserts a space before some punctuation, and escapes `*` as `\*`. Comparing each side
only to its own stored hash means those residual export artifacts never read as edits.
(At seed time ~5 of 16 docs have `repoHash != sliteHash` for exactly these reasons —
expected and harmless.)

**Hashing is normalized and identical on every side** (the single definition of "what
counts as a change" lives in `normhash` inside `sync-detect.sh`). It is
**formatting-insensitive but markup-preserving**:

- **Ignored (formatting, never a change):** leading/trailing whitespace; runs of
  spaces/tabs collapsed to one (table-column padding); blank lines; hard-wrapping
  (consecutive text / list-continuation lines are reflowed into one logical line);
  table-cell padding and the dash-count in separator rows.
- **Preserved (a real change):** the words/characters themselves, and markdown markup —
  heading level (`#`/`##`), emphasis (`**`/`_`), list marker (`-`/`*`/`+`), blockquote
  (`>`), table pipes, links, code. These are characters, not whitespace.

So a pure reformat (re-wrap, re-pad a table) hashes the **same** and is not synced; a
word edit or a markup change hashes **differently** and is. Always hash via
`bash .sync/sync-detect.sh hash <file>` — repo files directly, Slite exports by writing
the fetched md to a temp file first. Never hand-roll the hash, or every doc reads as changed.
Run `bash .sync/sync-detect.sh selftest` to see the rules asserted, or
`bash .sync/sync-detect.sh normalize <file>` to view a doc's canonical form.

## `sync-detect.sh`

```
bash .sync/sync-detect.sh                 # (= detect) emit the repo-side change-set as JSON
bash .sync/sync-detect.sh detect          # same
bash .sync/sync-detect.sh hash FILE       # print the normalized content hash of one file
bash .sync/sync-detect.sh normalize FILE  # print the canonical (normalized) text — for review
bash .sync/sync-detect.sh selftest        # assert: formatting ignored, content/markup preserved
```

`detect` reads `lastSyncedGitSha` from `state.json`, runs
`git diff --name-status -M <lastSyncedGitSha>..HEAD` over the doc folders (taken from
`slite-map.json`'s `folders`), hashes each changed file, and **drops no-op reverts**
(a file touched in a commit but whose normalized content still matches its stored
`repoHash`). Output:

```json
{
  "lastSyncedGitSha": "<sha>",
  "headSha": "<current HEAD>",
  "lastSyncedAt": "<ISO-8601>",
  "repoChanged": [
    { "path": "planets/mars.md", "status": "modified",
      "noteId": "e_pXodM6RoMqi8", "storedRepoHash": "…", "newRepoHash": "…",
      "renamedFrom": null }
  ],
  "note": "…Slite side handled by the routine…"
}
```

`status` is one of `modified | added | deleted | renamed` (with `renamedFrom` set for
renames). The script is pure shell + `git` + `python3` (already required by the hook) —
**no MCP**, so Routine A can run it deterministically before touching Slite.

## 3-way diff rules (per doc)

| repo changed | slite changed | action |
|:---:|:---:|---|
| yes | no | git is source → **propose Slite edit** (`to_slite`) |
| no | yes | slite is source → **edit the repo file** (goes into the PR) + `from_slite` |
| yes | yes | **conflict** → report in PR body, change nothing automatically |
| no | no | skip |
| new repo file | — | **create Slite note** under the right folder; map updated by B |
| — | new note | **create repo file**; map updated by B; `from_slite` |
| repo file deleted | — | **archive the Slite note** (`action: "archive"`); B drops it from map + state |

**Conflict base = git, not a stored baseline.** When both sides changed, reconstruct
the common ancestor with `git show <lastSyncedGitSha>:<path>` and show a 3-way diff
(base→repo and base→slite) in the PR body. Report only; never auto-resolve. No content
baseline storage is needed because git already preserves the repo-side history and the
two sides were equivalent (modulo cosmetics) at the last sync.

---

## Routine A — `sync-plan`

**Trigger (tester):** manual **Run now** (add a daily schedule once proven).
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only  **Branch pushes:** `claude/` prefix is fine.

**Prompt:**

> You are doing a two-way sync between this repo's docs and the Slite "SPACE TEST"
> folder (root note id `l9rKog-CwRTead`). This run is **read-only on Slite**: a
> PreToolUse hook blocks every Slite write tool, so propose changes only — never
> apply them to Slite.
>
> **1. Detect repo-side changes (deterministic, no Slite calls).** Run
> `bash .sync/sync-detect.sh detect`. It prints JSON with `lastSyncedGitSha`,
> `headSha`, `lastSyncedAt`, and `repoChanged[]` (each: `path`, `status` ∈
> modified/added/deleted/renamed, `noteId`, `newRepoHash`, `renamedFrom`). Trust this
> list for the repo side — do **not** re-scan files yourself.
>
> **2. Detect Slite-side changes (hash every mapped note — do NOT trust timestamps).**
> For **every** doc in `.sync/slite-map.json` → `docs`, call `get-note` on its noteId in
> **markdown**, write the content to a temp file, and hash it with
> `bash .sync/sync-detect.sh hash <tmpfile>`. A note is "slite changed" iff that hash ≠
> the doc's `sliteHash` in `.sync/state.json`. **Fetch and hash all of them** — Slite's
> `updatedAt` / `lastEditedAt` do not reliably bump on a content edit, so you must NOT
> filter by timestamp (doing so silently misses edits). The hash is the only authority.
> Then call `get-note-children` on `l9rKog-CwRTead` **once** (page with `nextCursor`
> while `hasNextPage`) only to discover **new** doc notes under a folder that are not yet
> in the map; ignore the four folder notes (ids that are values in `slite-map.json` →
> `folders`).
>
> **3. Apply the 3-way rules**, recording every accepted change in
> `.sync/pending-slite-changes.json`
> (shape `{ "scanGitSha": "<headSha from step 1>", "to_slite": [...], "from_slite": [...] }`):
> - **repo changed only** → append to `to_slite`:
>   `{ "action": "update", "path": "<path>", "noteId": "<id>", "newContent": "<full repo file text>" }`.
> - **slite changed only** → **overwrite the repo file** with the fetched Slite md
>   (lands in the PR as a normal git edit) AND append `{ "path": "<path>", "noteId": "<id>" }`
>   to `from_slite`.
> - **both changed** → do nothing to either side. Reconstruct the base with
>   `git show <lastSyncedGitSha>:<path>` and record the conflict (base→repo and
>   base→slite diffs) for the PR body only — not in either list.
> - **new repo file** (`status: added`, not in the map) → `to_slite` entry with
>   `"action": "create"` (target folder id from `slite-map.json` → `folders`; leave
>   `noteId` empty for B to fill).
> - **new Slite note** (a doc note under a folder, not in `slite-map.json` → `docs`) →
>   create the repo file from its md under the matching folder, append it to
>   `from_slite` (B adds it to the map).
> - **repo file deleted** (`status: deleted`) → `to_slite` entry with
>   `"action": "archive"` and the doc's `noteId` (B archives the note and drops the doc).
> - **renamed** (`status: renamed`, `renamedFrom` set) → keep the same `noteId`; if the
>   content also changed, queue an `"update"`; record the path change for the PR body so
>   B updates the map key `renamedFrom` → `path`.
>
> **4. No-op check — before creating anything.** If `repoChanged` is empty, no note was
> slite-changed, and there are no conflicts, then STOP: do not create a branch, commit,
> or open a PR. End the run.
>
> **5. Stale-cycle guard.** Check open PRs in the repo. If any open PR's head branch
> starts with `claude/sync-` or `claude/baseline-`, STOP — a prior cycle hasn't
> finished, so `state.json` may be stale. End the run; it resumes cleanly once that
> cycle completes.
>
> **6. Open the PR.** Create branch `claude/sync-<YYYY-MM-DD>`, commit the repo-side
> edits (Slite→repo overwrites, new/renamed files) plus the updated
> `.sync/pending-slite-changes.json` (with `scanGitSha` set to step 1's `headSha`), and
> open a PR. The PR body must list, per doc, the sync direction (git→Slite, Slite→git,
> or conflict, with the 3-way diff for conflicts). Do **not** modify `.sync/state.json`
> and do **not** write to Slite — those happen only after merge (Routine B).

## Routine B — `sync-apply`

**Trigger:** GitHub event → `pull_request.closed`, filters: **is merged = true**,
**head branch contains `sync`**. (Requires the Claude GitHub App installed on the repo.)
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only
**Environment:** set **`SYNC_ALLOW_WRITES=1`** so the read-only guard permits Slite
writes for this routine (use a dedicated environment; do not add this var to Routine A's).
**Permissions:** Routine B **merges its own bookkeeping PR via the GitHub API**, so it
does not need the "Allow unrestricted branch pushes" toggle (which won't save under the
org policy anyway). The one human approval per cycle is the **sync PR**; the
`claude/baseline-*` PR is auto-merged.

**Prompt:**

> A sync PR was just merged. Read `.sync/pending-slite-changes.json` — it has
> `scanGitSha`, `to_slite` (git→Slite changes to apply), and `from_slite` (Slite→git
> docs already in the repo), plus `.sync/state.json` and `.sync/slite-map.json`.
>
> 1. **Apply each `to_slite` entry to Slite:** `update-note` for `"update"`;
>    `create-note` (under the folder id from `slite-map.json` → `folders`) for
>    `"create"`, writing the new noteId back into both `slite-map.json` → `docs` and the
>    entry; `archive-note` for `"archive"`, then remove that doc from `slite-map.json`
>    → `docs`. For any rename recorded in the PR body, move the `slite-map.json` → `docs`
>    key from the old path to the new path (same noteId).
> 2. **Advance `state.json`:**
>    - Set `lastSyncedGitSha` = `scanGitSha` from the change-set (the sha Routine A
>      diffed against — **not** the current HEAD). This is what lets the next run still
>      catch any unrelated doc edited between Routine A's scan and this merge: everything
>      after `scanGitSha` is re-examined and filtered by hash.
>    - Set `lastSyncedAt` = now (ISO-8601 UTC) — informational only (audit/logging);
>      the Slite side no longer gates on it.
>    - For each doc in the change-set (the union of `to_slite` and `from_slite`), update
>      `docs[path]`: `repoHash` = `bash .sync/sync-detect.sh hash <repo file>`, and
>      `sliteHash` = re-fetch that note (`get-note`, markdown) → temp file →
>      `bash .sync/sync-detect.sh hash <tmpfile>`. Add new docs (creates / new notes);
>      delete archived docs. Do **not** touch any other doc's entry.
> 3. **Reset** `.sync/pending-slite-changes.json` to
>    `{ "scanGitSha": "", "to_slite": [], "from_slite": [] }`.
> 4. **Commit** the updated `state.json`, `slite-map.json`, and reset change-set to a
>    **new branch `claude/baseline-<YYYY-MM-DD-HHMM>`** (must NOT contain "sync", so the
>    merge doesn't re-trigger this routine). Open a PR titled "Baseline update for
>    <date>", then **merge it yourself via the GitHub API** (`merge_pull_request`). Do
>    not commit to `main` directly. Once merged, `state.json` is live and Routine A
>    resumes normally.
>
> Advancing `lastSyncedGitSha` to `scanGitSha` (not HEAD) and updating only the
> change-set's docs is deliberate: if someone edited an unrelated **repo** doc between
> Routine A and this merge, a blanket advance to HEAD would hide that edit from the next
> `git diff`. Rewinding `lastSyncedGitSha` to the scan point lets the next run still
> diff it (the hash check then drops the docs already converged here). Slite-side
> stragglers need no such care — Routine A hash-sweeps every mapped note each run, so a
> missed Slite edit is always caught on the next run regardless of timing.

---

## Prerequisites

1. **Add Slite as a claude.ai connector** at claude.ai/customize/connectors — a
   routine can't use a CLI-only MCP server. (Or commit a `.mcp.json`.)
2. **Install the Claude GitHub App** on `jyep07/test-slite` — required for Routine B's
   PR-merge trigger and for its API self-merge (`/web-setup` alone does not enable webhooks).
3. Default "Trusted" network access is sufficient; Slite traffic routes through
   Anthropic and GitHub is allowed.

## Testing it

1. Create **Routine A** only, trigger = manual.
2. Make one change on one side (edit `planets/mars.md`, or edit the Mars note in Slite).
3. **Run now** → confirm the PR shows the right direction and a sane
   `pending-slite-changes.json` (with `scanGitSha` set). A quiet run (no changes) must
   open **no** PR.
4. Once that's solid, add **Routine B** + the merge trigger, merge the sync PR, and
   verify: the Slite note updates, `state.json` advanced (`lastSyncedGitSha` =
   `scanGitSha`, hashes updated for the changed docs only), and the baseline PR
   auto-merged.

## Re-seeding `state.json` (if it ever drifts)

`state.json` was seeded by hashing every repo file and every Slite md export with
`sync-detect.sh hash` (so both sides use identical normalization), with
`lastSyncedGitSha` = the seed commit and `lastSyncedAt` = seed time. To re-seed, repeat
that: for each doc in `slite-map.json` → `docs`, `repoHash` = hash of the repo file,
`sliteHash` = hash of the note's current md export.
