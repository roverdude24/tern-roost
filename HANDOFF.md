# Roost: handoff

## Next action

Push the local commits to GitHub (`git push`), then retake `docs/panel.png` with Settled at the bottom.

## Where things are

- Source and docs: `/Volumes/VINH MAC/VINH's WORKS/TERN ROOST PLUGIN` (git, remote `origin` = https://github.com/roverdude24/tern-roost, branch `main`). Moved here from `~/Developer/tern-roost` on 2026-11-04 at the user's request.
- Live plugin: linked, so edits reload in Tern at once. `tern plugin list` shows `roost 0.2.0 … ready`.
- User data: `~/Library/Application Support/Tern/plugin-data/roost/kv.json`.
- Overseer contribution: `~/Developer/overseer` (fork of mmnavarr/overseer, branch `remove-project`), PR https://github.com/mmnavarr/overseer/pull/3.

## Reopen and rebuild

```sh
cd "/Volumes/VINH MAC/VINH's WORKS/TERN ROOST PLUGIN"
T=/Applications/Tern.app/Contents/MacOS/tern
$T plugin types .            # regenerate tern.d.luau (gitignored)
$T plugin reload roost
```

If the link is gone (or the drive was renamed): `$T plugin link "/Volumes/VINH MAC/VINH's WORKS/TERN ROOST PLUGIN"`.

## Reconnect tools

- No MCP server or local service needed. UI checks use OMP `computer` on the Tern window (AX find by tooltip).
- Agent transcripts from the build session: `history://SessionFoldersPlugin` (integrator), `history://GitModule`, `history://HarnessModule`.

## Open questions for the user

- Fix the shared-column squeeze when Roost and Overseer's panel are both open?
- Delete the old `plugin-data/session-folders` kv?
