# GitHub ↔ Slite sync routine

A tester setup for keeping this repo's docs and the Slite **SPACE TEST** folder in
sync, using a 3-way diff against a committed baseline. Human approval happens at a
single point: **merging the PR**.

```
 Git repo ─┐                          ┌─ open PR (git side)   → human merges
           ├─ Claude routine (3-way) ─┤
 Slite ────┘   reads both + baseline  └─ apply Slite edits    → after merge
                                          ↻ baseline updated on merge
```

## Why two routines

Routines run **autonomously — there is no approval prompt during a run**, and Claude
can write to Slite without asking. So the human gate has to be structural. We use the
**PR merge** as that gate:

- **Routine A (`sync-plan`)** computes the diff and proposes changes, but does **not**
  touch live Slite. Git-side changes land as real file edits in a PR; Slite-side
  changes are written to `.sync/pending-slite-changes.json` in the same PR.
- **Routine B (`sync-apply`)** runs *after the PR merges*, applies the approved Slite
  edits, and rewrites the baseline.

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
  baseline/                    last-synced snapshot of every doc (mirrors the doc tree)
  slite-map.json               repo path  ↔  Slite noteId mapping
  pending-slite-changes.json   written by Routine A (committed into the PR); reset to {} by Routine B
.claude/
  settings.json                registers the PreToolUse read-only guard on mcp__Slite__*
  hooks/slite-readonly-guard.sh  blocks Slite writes unless SYNC_ALLOW_WRITES=1
```

## ⭐ Tester v1 — one-way git → Slite (dry run)

Start here. This proves the plumbing with **zero write risk**: it *reads* Slite to show
before/after, but the `PreToolUse` guard makes Slite writes impossible (Routine A's
environment does not set `SYNC_ALLOW_WRITES`). It detects which repo docs changed since
the baseline and writes a plan; you review the plan in a PR. Graduate to the full design
below once it looks right.

**Routine:** one routine, trigger = manual **Run now**.
**Repository:** `jyep07/test-slite`  **Connectors:** Slite (reads only; writes hard-blocked by the hook)  **Branch pushes:** `claude/` prefix.
**Environment:** do **not** set `SYNC_ALLOW_WRITES` (leaving it unset keeps the run read-only).

**Prompt (paste verbatim):**

> You are dry-running a one-way sync from this repo's docs to Slite. This run is
> read-only on Slite: a PreToolUse hook will block any Slite write tool, so only
> propose changes — never apply them.
>
> 1. Read `.sync/slite-map.json` and `.sync/baseline/`.
> 2. For each path in the map's `docs`, compare the current repo file against its
>    `.sync/baseline/<path>` copy.
> 3. For every file that differs (or is missing from the baseline), add an entry to
>    `.sync/pending-slite-changes.json`:
>    `{ "action": "update", "path": "<path>", "noteId": "<id from map>", "newContent": "<full file text>" }`.
>    For a repo file with no map entry, use `"action": "create"` with the target folder
>    noteId and leave `noteId` empty.
> 4. For each changed doc, you MAY read the current Slite note (get-note, markdown) to
>    include a short before/after summary in the PR body. Do not attempt any write — it
>    will be denied by the hook.
> 5. Create a branch `claude/sync-dryrun-<YYYY-MM-DD>`, commit only
>    `.sync/pending-slite-changes.json`, and open a PR titled "Sync dry run". The PR
>    body lists each doc that would change and the direction (git → Slite).
> 6. Do NOT modify `.sync/baseline/`.

**How to test it:**

1. Create the routine with the prompt above (Slite connector attached, `SYNC_ALLOW_WRITES` unset).
2. Edit one doc, e.g. add a line to `planets/mars.md`, and commit to `main`.
3. **Run now** → open the resulting PR. `pending-slite-changes.json` should contain a
   single `update` entry for `planets/mars.md`, and the Slite note is unchanged. ✅
4. (Optional) Confirm the guard fired: the run transcript will show any attempted Slite
   write denied with the `slite-readonly-guard` reason. With a correct prompt there
   should be none.
5. When that's trustworthy, move to **Routine B** below to actually apply, and turn on
   the reverse direction + conflict handling.

---

## 3-way diff rules (per doc) — full design (v2)

Compare **repo vs baseline** and **Slite vs baseline**:

| repo changed | slite changed | action |
|:---:|:---:|---|
| yes | no | git is source → **propose Slite edit** (pending-slite-changes.json) |
| no | yes | slite is source → **edit the repo file** (goes into the PR) |
| yes | yes | **conflict** → record in PR body, change nothing automatically |
| no | no | skip |
| new file | — | **create Slite note** under the right folder; add to slite-map.json |
| — | new note | **create repo file**; add to slite-map.json |

---

## Routine A — `sync-plan`

**Trigger (tester):** manual **Run now** (add a daily schedule once it's proven).
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only  **Branch pushes:** `claude/` prefix is fine.

**Prompt:**

> You are syncing this repo's docs with the Slite "SPACE TEST" folder. Read
> `.sync/slite-map.json` for the path↔noteId mapping and `.sync/baseline/` for the
> last-synced snapshot.
>
> For every doc in the map, fetch the current Slite note (get-note, markdown format)
> and read the current repo file. Do a 3-way comparison against the baseline copy:
> - repo changed only → record a Slite edit in `.sync/pending-slite-changes.json`
>   (noteId, path, new content). Do NOT call any Slite write tool.
> - Slite changed only → edit the repo file to match.
> - both changed → list it under "conflicts"; change nothing.
> - new repo file not in the map → add a pending Slite "create" entry.
> - new Slite note not in the map → create the repo file and note it.
>
> Then: create a branch `claude/sync-<YYYY-MM-DD>`, commit the repo-side edits plus
> the updated `.sync/pending-slite-changes.json`, and open a PR. The PR body must
> summarize, per doc, which direction it synced and list any conflicts. Do NOT modify
> `.sync/baseline/` and do NOT write to Slite — those happen only after merge.

## Routine B — `sync-apply`

**Trigger:** GitHub event → `pull_request.closed`, filters: **is merged = true**,
**head branch contains `sync`**. (Requires the Claude GitHub App installed on the repo.)
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only
**Environment:** set **`SYNC_ALLOW_WRITES=1`** so the read-only guard permits Slite
writes for this routine (use a dedicated environment; do not add this var to Routine A's).
**Permissions:** enable **Allow unrestricted branch pushes** (so it can commit the
updated baseline to the merged branch's target).

**Prompt:**

> A sync PR was just merged. Read `.sync/pending-slite-changes.json` from the repo.
> For each entry, apply the change to Slite: use update-note for edits and create-note
> (under the folder noteId from `.sync/slite-map.json`) for creates, adding any new
> noteIds back into `.sync/slite-map.json`.
>
> After all Slite writes succeed, regenerate `.sync/baseline/` so every baseline copy
> matches the current repo doc, clear `.sync/pending-slite-changes.json` to `{}`, then
> commit `.sync/baseline/` and the updated map to `main`. This snapshot becomes the
> baseline for the next run.

---

## Prerequisites

1. **Add Slite as a claude.ai connector** at claude.ai/customize/connectors — a
   routine can't use a CLI-only MCP server. (Or commit a `.mcp.json`.)
2. **Install the Claude GitHub App** on `jyep07/test-slite` — required for Routine B's
   PR-merge trigger (`/web-setup` alone does not enable webhooks).
3. Default "Trusted" network access is sufficient; Slite traffic routes through
   Anthropic and GitHub is allowed.

## Testing it

1. Create **Routine A** only, trigger = manual.
2. Make one change on one side (edit `planets/mars.md`, or edit the Mars note in Slite).
3. **Run now** → confirm the PR shows the right direction and a sane
   `pending-slite-changes.json`.
4. Once that's solid, add **Routine B** + the merge trigger, merge the PR, and verify
   the Slite note updates and the baseline is rewritten.
