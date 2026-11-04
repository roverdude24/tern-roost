# Roost: project state

Updated 2026-11-04.

## Status

- Roost 0.2.0 is published (https://github.com/roverdude24/tern-roost) and linked live in the user's Tern 0.9.11 from this folder.
- Unreleased in the working tree: Settled moved into the canvas dock so it stays pinned to the panel's bottom edge (user request "have settled as the bottom"); shows the newest 8, then "+N older". Toggle checked live via AX.
- Upstream: Overseer PR https://github.com/mmnavarr/overseer/pull/3 (Remove project) open, awaiting the owner. Fork clone: `~/Developer/overseer`, branch `remove-project`. The fixed Overseer is installed in the user's Tern; backup of the previous copy in `/tmp/overseer-backup-*` (lost on reboot).

## Locked decisions

- Name `Roost`, id `roost`, so it is never confused with Tern's built-in Sessions.
- Forked from mmnavarr/overseer (MIT); LICENSE and attribution kept.
- No git requirement. Git features are optional and use plain git; no Worktrunk.
- Shortcut `⌘⌥⇧L` (Tern already binds `⌘⌥⇧S`; Overseer uses `⌘⌥⇧P`).
- Settled = sessions the user settles or that close; never auto-settled for being idle.
- Header and folder actions are icon-only buttons with tooltips.

## Open decisions

- Where the user wants the repo for future development: asked "set the repo to be in this folder"; the session's folder is `/tmp`, which macOS clears. Repo kept at `~/Developer/tern-roost` until the user confirms.
- Roost and Overseer's Projects panel open together share one narrow left column. Fix, or leave "show one at a time"?
- Settled list paging beyond 8 rows in the dock.

## Assets map

| Path | State |
|---|---|
| `*.luau`, `styles.css`, `plugin.toml` | CURRENT plugin source (see `AGENTS.md` layout) |
| `docs/panel.png` | CURRENT README screenshot (0.2.0, before the dock change) |
| `README.md`, `CHANGELOG.md`, `LICENSE` | CURRENT |
| `AGENTS.md`, `PROJECT-STATE.md`, `HANDOFF.md` | CURRENT project docs |
| `tern.d.luau` | generated, gitignored |
| `~/Library/Application Support/Tern/plugin-data/session-folders` | SUPERSEDED kv from 0.1 (copied to `plugin-data/roost`) |
| `~/Library/Application Support/Tern/plugins/roost.path` | link to this folder |

## Toolchain

- Tern 0.9.11, CLI `/Applications/Tern.app/Contents/MacOS/tern`.
- `gh` signed in as `roverdude24`.
- Optional at runtime: `git`, `gh`.

## Next steps

1. Confirm the repo location with the user (see Open decisions).
2. Commit and push the dock change; refresh `docs/panel.png` showing Settled at the bottom.
3. Untested paths to exercise: restore a settled omp/claude session, PR badge on a repo with a GitHub remote, ages of days, Add folder after 0.2.
4. Watch Overseer PR #3; delete `plugin-data/session-folders` once the user agrees.
