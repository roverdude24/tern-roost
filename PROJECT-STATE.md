# Roost: project state

Updated 2026-11-04.

## Status

- Roost 0.2.0 is published (https://github.com/roverdude24/tern-roost). Tern runs it live from `~/Developer/tern-roost` (original linked path, kept at the user's request); this folder, `/Volumes/VINH MAC/VINH's WORKS/TERN ROOST PLUGIN`, is the development repo. The live copy pulls from here (`git -C ~/Developer/tern-roost pull dev main`).
- Pushed to GitHub `main` (8a3d4b4, 2026-11-04), unreleased on top of 0.2.0: Settled moved into the canvas dock so it stays pinned to the panel's bottom edge (user request "have settled as the bottom"), shows the newest 8, then "+N older" (toggle checked live via AX); project docs; two-folder setup.
- Upstream: Overseer PR https://github.com/mmnavarr/overseer/pull/3 (Remove project) open, awaiting the owner. Fork clone: `~/Developer/overseer`, branch `remove-project`. The fixed Overseer is installed in the user's Tern; backup of the previous copy in `/tmp/overseer-backup-*` (lost on reboot).

## Locked decisions

- Name `Roost`, id `roost`, so it is never confused with Tern's built-in Sessions.
- Forked from mmnavarr/overseer (MIT); LICENSE and attribution kept.
- No git requirement. Git features are optional and use plain git; no Worktrunk.
- Shortcut `⌘⌥⇧L` (Tern already binds `⌘⌥⇧S`; Overseer uses `⌘⌥⇧P`).
- Settled = sessions the user settles or that close; never auto-settled for being idle.
- Header and folder actions are icon-only buttons with tooltips.

## Open decisions

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
| `~/Developer/tern-roost` | CURRENT live plugin copy (clone of this repo; remotes `dev`, `origin`) |
| `~/Library/Application Support/Tern/plugins/roost.path` | link to `~/Developer/tern-roost` |

## Toolchain

- Tern 0.9.11, CLI `/Applications/Tern.app/Contents/MacOS/tern`.
- `gh` signed in as `roverdude24`.
- Optional at runtime: `git`, `gh`.

## Next steps

1. Refresh `docs/panel.png` showing Settled at the bottom.
2. Untested paths to exercise: restore a settled omp/claude session, PR badge on a repo with a GitHub remote, ages of days, Add folder after 0.2.
3. Watch Overseer PR #3; delete `plugin-data/session-folders` once the user agrees.
