# Changelog

## Unreleased

- Narrow panels: folder names end in `…` instead of spilling off the left edge, and the folder path, then the harness icon give way to session names. Folder buttons and Settled's `↶` take no room until hovered (the right-click menu still has them). Session rows drop the folder badge their folder header already shows.

## 0.2.5

### Added

- Sessions still named after their folder take their agent's title (omp's `OMNI: Evaluate repos`, Claude Code's task title), icon stripped, and follow it as it changes. A name you give a session yourself is kept.

### Changed

- *Settled* sits at the bottom of the panel (the canvas dock) instead of after the folder list. When open it shows the newest 8, then "+N older".

## 0.2.0

Renamed from Sessions to **Roost** (plugin id `roost`, canvas title "Roost") so it is never confused with Tern's own Sessions. Existing pinned folders and settings move by copying `plugin-data/session-folders` to `plugin-data/roost`.

### Added

- Two-letter coloured folder badges on headers and rows.
- A harness icon per session (omp, Claude Code, Codex, Pi, Hermes, Gemini, OpenCode, Aider, shell) with a tooltip listing folder, host, harness and model.
- Time since last activity on rows and folder headers; sessions sort by it.
- Git, never required: branch, uncommitted marker, ahead/behind and (with `gh`) the pull request on a repository's header; linked worktrees as sub-groups; *New worktree session* and *Remove worktree* in the folder menu.
- A collapsible *Settled* section with Settle, Restore (`↶`) and Forget.
- Header and folder actions are icon-only buttons with tooltips.

### Changed

- Palette commands: *Show or hide Roost*, *Roost: Find session*, *Roost: New session in folder*, *Roost: Rename current session*.
- Paths are held in their `/tmp` form, so `/private/tmp/...` and `/tmp/...` land in one folder.

## 0.1.0

Folder-grouped session panel forked from Overseer: pinned folders, collapsible groups, status dots, Find / New / Add folder, row menu (Rename, New tab, Lock, Close).
