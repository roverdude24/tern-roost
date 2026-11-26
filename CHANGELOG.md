# Changelog

## Unreleased

## 0.3.1

- Remote folders are keyed by host (`vinhlam-pc:C:\…`), so the same path on two machines no longer merges into one folder.
- Auto-naming covers sessions on every host. A host that refuses a rename is left alone instead of retried every tick.
- *Restore* of a settled remote session switches to its host and reopens it there (same folder, name and harness).

## 0.3.0

- Sessions from every connected host (`tern remote`) show in the panel, not only this Mac's. With more than one host, each row names its host; click a remote row to switch to it. Remote folders (Windows paths included) group like local ones and offer only *Move*. The panel, shortcut and Find session now work while you view a remote host instead of saying "Local host required".

## 0.2.9

- Reorder folders and sessions: right-click › Move picks one up (dashed outline, a hint at the top), then click the folder or session whose place it should take. Tern panels deliver clicks, not drags, so this stands in for drag and drop. Sessions move within their own folder; worktrees keep name order. New folders and sessions show above the ones you placed.

## 0.2.8

- Fix: Tern's "timer exceeded 50 ms" toast. Each pass read every tab, pane and agent once per session, and built the whole model twice (tick and draw). Now one read serves all sessions, and only the draw builds the model: tick ~30 ms → ~3 ms, draw ~13 ms → ~8 ms.

## 0.2.7

- Fix: sessions stopped regrouping and auto-naming after Tern paused Roost's timer once for running over its 50 ms budget. The next tick is now scheduled before the work, so a pause no longer stops the loop.

## 0.2.6

- Narrow panels: folder names end in `…` instead of spilling off the left edge, and the folder path, then the harness icon give way to session names. Folder buttons and Settled's `↶` take no room until hovered (the right-click menu still has them). Session rows drop the folder badge their folder header already shows.
- Git no longer takes a line under each repository folder: its marks sit in the folder header (`●` uncommitted, `↑2`, `#12`), the branch shows only when it is not `main`/`master`, and the header tooltip lists it all.

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
