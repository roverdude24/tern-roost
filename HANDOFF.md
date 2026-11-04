# Roost: handoff

## Next action

Ask the user where the repo should live (the request named "this folder", i.e. `/tmp`, which macOS clears on reboot). Then commit and push the Settled-in-dock change (`view.luau`, `window.luau`, `CHANGELOG.md`).

## Where things are

- Source and docs: `~/Developer/tern-roost` (git, remote `origin` = https://github.com/roverdude24/tern-roost, branch `main`).
- Live plugin: linked, so edits reload in Tern at once. `tern plugin list` shows `roost 0.2.0 … ready`.
- User data: `~/Library/Application Support/Tern/plugin-data/roost/kv.json`.
- Overseer contribution: `~/Developer/overseer` (fork of mmnavarr/overseer, branch `remove-project`), PR https://github.com/mmnavarr/overseer/pull/3.

## Reopen and rebuild

```sh
cd ~/Developer/tern-roost
T=/Applications/Tern.app/Contents/MacOS/tern
$T plugin types .            # regenerate tern.d.luau (gitignored)
$T plugin reload roost
```

If the link is gone: `$T plugin link ~/Developer/tern-roost`.

## Reconnect tools

- No MCP server or local service needed. UI checks use OMP `computer` on the Tern window (AX find by tooltip).
- Agent transcripts from the build session: `history://SessionFoldersPlugin` (integrator), `history://GitModule`, `history://HarnessModule`.

## Open questions for the user

- Repo location: keep `~/Developer/tern-roost`, or move elsewhere?
- Fix the shared-column squeeze when Roost and Overseer's panel are both open?
- Delete the old `plugin-data/session-folders` kv?
