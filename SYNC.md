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

## Repo layout

```
.sync/
  baseline/                    last-synced snapshot of every doc (mirrors the doc tree)
  slite-map.json               repo path  ↔  Slite noteId mapping
  pending-slite-changes.json   written by Routine A (committed into the PR); reset to {} by Routine B
```

## 3-way diff rules (per doc)

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
