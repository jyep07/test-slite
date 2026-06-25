# Handoff — GitHub ↔ knowledge-base sync experiments

Context note for continuing this work in a fresh Claude session. The repo
travels between sessions; this conversation's memory does not — so everything
needed to pick up is captured here.

_Last updated: 2026-06-25._

## Branches

| Branch | State |
|--------|-------|
| `main` | Original **Slite** sync (v1 + v2 change-detection): `SYNC.md`, `V2_PLAN.md`, `.sync/sync-detect.sh`, `.sync/state.json`, `.sync/slite-map.json`, `.sync/pending-slite-changes.json`, `.claude/hooks/slite-readonly-guard.sh`. **Untouched — leave intact.** |
| `claude/doc-repo-sync` | **Google Docs ↔ repo** model. All Slite files removed; only the Docs machinery remains. This is the active experiment. Latest commit `b66c1c4`. |

## What's built on `claude/doc-repo-sync`

A change-detection sync (O(changes), not O(N)) between the repo's markdown and
Google Docs in the Drive folder **Space KB**.

- `.sync/docs-sync-detect.sh` — repo-side detector + canonical normalizer
  (`detect` / `hash` / `normalize` / `selftest`). Formatting-insensitive,
  markup-preserving. Selftest passes; `detect` runs clean.
- `.sync/drive-map.json` — repo path ↔ Drive fileId; Space KB folder id +
  `planets`/`space-exploration` subfolder ids.
- `.sync/drive-state.json` — two-hash baseline (`repoHash` vs `driveHash`) for
  all 10 docs, seeded at the time of writing.
- `.sync/pending-docs-changes.json` — `{scanGitSha, to_docs[], from_docs[]}`.
- `.claude/hooks/drive-readonly-guard.sh` + `.claude/settings.json` — PreToolUse
  guard: Routine A read-only on Drive; writes denied unless `SYNC_ALLOW_WRITES=1`.
- `DOCS-SYNC.md` — full design, routines, and the write-back limitation.

### Repo content on this branch (10 docs)
`planets/` (mercury, venus, earth, mars, jupiter, saturn) and
`space-exploration/` (voyager-program, apollo-program, james-webb-telescope,
the-iss). `moons/` and `stars-and-galaxies/` were deleted on this branch.
Note: `planets/mars.md` line 3 has leftover cruft (`#4 planet from the Sun`) —
faithfully mirrored to its Doc; clean up the repo source if desired.

### Google Drive (external — not in git)
- Space KB folder: `1X2QfTPHVrw4WrHcS-0Fh1Swoq1MUC_cY`
- Subfolders: planets `1vd2PTi--f-f0sQQIy0fEsAOnpDvjuxzF`,
  space-exploration `12OeshfBKitqIFxXEPxp3npJMyI1pPPUW`
- 10 Google Docs created from the repo (HTML→Doc), fileIds in `drive-map.json`.
- **Pending manual step:** drag the 10 docs into the matching subfolders in the
  Drive UI. Moving does NOT change fileId or export, so the seed stays valid —
  no reseed needed.
- Seed script (for re-seeding): `scratchpad/seed_drive.py` (ephemeral, not committed).

## Key constraints discovered (important)

1. **The Drive MCP connector here is read + create only.** It exposes
   search/read/download/metadata + `create_file`/`copy_file`. **No
   `files.update`, no Docs `batchUpdate`, no Changes feed
   (`changes.list`/`getStartPageToken`), no move/delete.**
   - Consequence: **Doc→repo** sync is fully automatable; **repo→Doc** can only
     *create* new Docs, not overwrite an edited Doc's body.
2. **Built-in connector scopes/tools are fixed** (Anthropic-managed). Reconnecting
   won't add write scope. Connectors are managed at **claude.ai/customize/connectors**.
3. **Claude Code on the *web* does not reliably load custom/`.mcp.json` MCP
   servers** (only first-party connectors) — see github.com/anthropics/claude-code/issues/54441.
   So to get write tools (`files.update`, `batchUpdate`, Changes feed), use a
   **local Claude Code session** with a custom remote MCP server (write scope
   `drive.file`), then allow-list that tool in `drive-readonly-guard.sh` under
   the `SYNC_ALLOW_WRITES=1` branch.
4. **Slite (on `main`) CAN write** — both note bodies (`update-note`) and
   comments. So for full two-way sync in *this* web environment, Slite is more
   capable than the current Drive connector.

## Open directions (not yet built)

- **`modifiedTime` incremental detection (works today, web).** Replace the Drive
  full hash-sweep with `search_files` `modifiedTime > lastSyncedAt` scoped to the
  Space KB folders; still hash candidates to confirm body vs comment. (True
  Changes feed needs a write-capable connector → local session.)
- **Repo→Doc write-back.** Needs `files.update` (media, HTML) keeping fileId —
  local session / custom MCP. Flow + guard slot documented in `DOCS-SYNC.md`.
- **Comment-driven Slite→repo (strong candidate).** Instead of editing Slite
  bodies, humans leave **comments**; Routine A reads **unresolved**
  `list-comment-threads` (read-only, per note), turns each into a proposed repo
  edit in a PR; Routine B applies + `resolve-comment-thread` after merge.
  Advantages: sidesteps Slite's unreliable `updatedAt` (uses the `resolved`
  flag instead of body hashing), explicit intent, anchored to exact text via
  `<comment id="...">` spans, keeps the note body clean. Slite supports both
  comment reads (A) and comment/body writes (B).

## Conventions to preserve
- Human gate = sync-PR merge. Routine A read-only (enforced by the guard);
  Routine B writes with `SYNC_ALLOW_WRITES=1`.
- Routine B advances `lastSyncedGitSha = scanGitSha` (NOT HEAD) so mid-cycle
  repo edits aren't hidden.
- Each side compared only against its own stored hash (repoHash vs driveHash) —
  the two are never compared to each other.
- Commits: branch off the right base, never push to `main`; `main` keeps Slite.
