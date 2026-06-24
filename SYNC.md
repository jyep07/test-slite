# GitHub ↔ Slite sync routine

A tester setup for keeping this repo's docs and the Slite **SPACE TEST** folder in
sync, using a 3-way diff against committed baselines (one per side). Human approval
happens at a single point: **merging the PR**.

```
 Git repo ─┐                          ┌─ open PR (git side)   → human merges
           ├─ Claude routine (3-way) ─┤
 Slite ────┘   reads both + baseline  └─ apply Slite edits    → after merge
                                          ↻ changed docs' baselines updated on merge
```

## Why two routines

Routines run **autonomously — there is no approval prompt during a run**, and Claude
can write to Slite without asking. So the human gate has to be structural. We use the
**PR merge** as that gate:

- **Routine A (`sync-plan`)** computes the two-way diff and proposes changes, but does
  **not** touch live Slite. **Slite→repo** edits land as real file changes in the PR;
  **repo→Slite** edits are queued in `.sync/pending-slite-changes.json` in the same PR.
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
  baseline/                    last-synced snapshot of the REPO side (repo-authored markdown)
  baseline-slite/              last-synced snapshot of the SLITE side (Slite's md export)
  slite-map.json               repo path  ↔  Slite noteId mapping
  pending-slite-changes.json   this round's accepted change-set, written by Routine A
                               (committed into the PR). Shape:
                               { "to_slite":   [ {path, noteId, action, newContent} ],   git→Slite, applied by B
                                 "from_slite": [ {path, noteId} ] }                       Slite→git, already in the PR
                               Routine B uses BOTH lists to update baselines, then resets it.
.claude/
  settings.json                registers the PreToolUse read-only guard on mcp__Slite__*
  hooks/slite-readonly-guard.sh  blocks Slite writes unless SYNC_ALLOW_WRITES=1
```

---

## 3-way diff rules (per doc) — full design

Each side is compared against **its own** baseline. This is the key to avoiding false
positives: repo markdown and Slite's markdown export never match byte-for-byte (table
padding, escaping, spacing), so a single shared baseline would flag every doc as
"changed". Two baselines fix that:

- **repo changed** = current repo file `≠` `.sync/baseline/<path>`
- **slite changed** = current Slite md export `≠` `.sync/baseline-slite/<path>`

| repo changed | slite changed | action |
|:---:|:---:|---|
| yes | no | git is source → **propose Slite edit** (pending-slite-changes.json) |
| no | yes | slite is source → **edit the repo file** (goes into the PR) |
| yes | yes | **conflict** → record in PR body, change nothing automatically |
| no | no | skip |
| new file | — | **create Slite note** under the right folder; add to slite-map.json |
| — | new note | **create repo file**; add to slite-map.json |

> Compare with a tolerant match (trim trailing whitespace per line + trailing blank
> lines) so cosmetic export differences don't read as edits. When Slite is the source,
> write the fetched Slite md export verbatim into the repo file.

---

## Routine A — `sync-plan`

**Trigger (tester):** manual **Run now** (add a daily schedule once it's proven).
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only  **Branch pushes:** `claude/` prefix is fine.

**Prompt:**

> You are doing a two-way sync between this repo's docs and the Slite "SPACE TEST"
> folder. This run is read-only on Slite: a PreToolUse hook blocks every Slite write
> tool, so propose changes only — never apply them to Slite.
>
> Read `.sync/slite-map.json` (path↔noteId). For every doc in the map's `docs`:
> 1. Read the current repo file, `.sync/baseline/<path>` (repo baseline), and
>    `.sync/baseline-slite/<path>` (Slite baseline).
> 2. Fetch the current Slite note with get-note in **markdown** format.
> 3. Decide what changed (use a tolerant compare — ignore trailing whitespace and
>    trailing blank lines):
>    - **repo changed** = repo file ≠ `.sync/baseline/<path>`
>    - **slite changed** = fetched Slite md ≠ `.sync/baseline-slite/<path>`
> 4. Apply the rules, recording every accepted change in
>    `.sync/pending-slite-changes.json` (shape `{ "to_slite": [...], "from_slite": [...] }`):
>    - repo changed only → append to `to_slite`:
>      `{ "action": "update", "path": "<path>", "noteId": "<id>", "newContent": "<full repo file text>" }`.
>    - Slite changed only → **overwrite the repo file** with the fetched Slite md (lands
>      in the PR as a normal git edit) AND append `{ "path": "<path>", "noteId": "<id>" }`
>      to `from_slite`.
>    - both changed → do nothing to either side; record it under "conflicts" (PR body only,
>      not in either list).
>    - neither → skip.
> 5. Handle new docs: a repo file not in the map → `to_slite` entry with
>    `"action": "create"` (target folder noteId from the map, leave noteId empty). A new
>    Slite note under a folder but not in the map → create the repo file from its md, add
>    it to the map, and append it to `from_slite`.
>
> 6. If there are no changes to either the repo or slite (i.e. everything matches the baseline), DO NOT create a new PR.
>
> Then create a branch `claude/sync-<YYYY-MM-DD>`, commit the repo-side edits (including
> any Slite→repo overwrites) plus the updated `.sync/pending-slite-changes.json`, and
> open a PR. The PR body must list, per doc, the direction it synced (git→Slite,
> Slite→git, or conflict). Do NOT modify either baseline and do NOT write to Slite —
> those happen only after merge (Routine B).

## Routine B — `sync-apply`

**Trigger:** GitHub event → `pull_request.closed`, filters: **is merged = true**,
**head branch contains `sync`**. (Requires the Claude GitHub App installed on the repo.)
**Repository:** `jyep07/test-slite`  **Connectors:** Slite only
**Environment:** set **`SYNC_ALLOW_WRITES=1`** so the read-only guard permits Slite
writes for this routine (use a dedicated environment; do not add this var to Routine A's).
**Permissions:** enable **Allow unrestricted branch pushes** (so it can commit the
updated baseline to the merged branch's target).

**Prompt:**

> A sync PR was just merged. Read `.sync/pending-slite-changes.json` — it has two lists:
> `to_slite` (git→Slite changes to apply) and `from_slite` (Slite→git docs already in the
> repo).
>
> 1. Apply each `to_slite` entry to Slite: update-note for `"update"`, create-note (under
>    the folder noteId from `.sync/slite-map.json`) for `"create"`, adding any new noteIds
>    back into `.sync/slite-map.json` and into the entry.
> 2. Update baselines **only for the docs in this change-set** (the union of `to_slite`
>    and `from_slite`) — do NOT touch any other doc's baseline. For each such doc, update
>    *both* sides to the now-converged content, each from its own source:
>    - `.sync/baseline/<path>` ← the current repo file.
>    - `.sync/baseline-slite/<path>` ← re-fetch that note (get-note, markdown) and save it.
> 3. Reset `.sync/pending-slite-changes.json` to `{ "to_slite": [], "from_slite": [] }`,
>    then commit the updated baselines and map to `main`.
>
> Leaving untouched docs' baselines alone is deliberate: if someone edited an unrelated
> doc between Routine A and this merge, a blanket rebuild would absorb that edit into the
> baseline and it would never sync. Scoping to the accepted change-set lets the next run
> still detect it.

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
