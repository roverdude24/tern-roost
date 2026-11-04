# Roost: agent guide

Tern plugin (Luau, window side only): a left panel of every Tern session grouped by folder. Repo: https://github.com/roverdude24/tern-roost. Read `PROJECT-STATE.md` first, then `HANDOFF.md`.

## Rules

- Work in `/Volumes/VINH MAC/VINH's WORKS/TERN ROOST PLUGIN` (external drive; the user's chosen home for this repo). It is linked into Tern (`tern plugin link`), so every saved file reloads the live plugin in the user's window. If the drive is unplugged, Roost fails to load until it is back.
- Git is optional, never required: non-git folders must behave exactly like v0.1. No Worktrunk, no `gh` dependency (`gh` only adds a PR badge when present).
- Paths can hold spaces, apostrophes, non-ASCII and live on `/Volumes/...`. Test with such a path.
- Never close, rename or switch the user's real sessions while testing. Test sessions are prefixed `rt-test`; delete them and any `/tmp/rt-*` folders afterwards.
- `tern.d.luau` is generated (`tern plugin types .`) and gitignored. It is the API reference; read it before using an API.
- Keep `README.md` (users) and `CHANGELOG.md` (an `Unreleased` section) up to date with every behaviour change.

## Layout

| File | Owns |
|---|---|
| `plugin.toml` | id `roost`, version, `window = "window.luau"`, styles |
| `window.luau` | panel canvas (follows the shown tab, width in kv), events, actions, palette commands, Settled shelf, activity tracking, kv |
| `view.luau` | pure render: `View.render(model)` main list, `View.dock(model)` Settled pinned in the canvas dock |
| `folders.luau` | folder of a session, grouping, path shortening |
| `git.luau` | `Git.inspect/addWorktree/removeWorktree` via plain git, 15 s cache |
| `harness.luau` | which agent runs a session (omp, claude, codex, pi, hermes, gemini, opencode, aider, shell), model name, host name, launch command |
| `badge.luau` | two-letter folder initials and stable colour |
| `styles.css` | `roost.*` roles |

kv keys (plugin-data/roost/kv.json): `activity collapsed panel-open panel-share picker-start pinned settled settled-open`.

## Develop and verify

```sh
T=/Applications/Tern.app/Contents/MacOS/tern
$T plugin reload roost && $T plugin list | grep roost   # must say "ready"
$T plugin types .                                        # refresh tern.d.luau after a Tern update
```

- Show the panel: `⌘⌥⇧L` or palette "Show or hide Roost".
- Verify UI live: OMP `computer` helpers on the Tern window. Canvas buttons are in the AX tree by their tooltip, e.g. `win.find({ title: "Expand Settled" })` then `.press()`. Clicks are refused while the user is typing in Tern; use AX.
- `git.luau` was tested with a throwaway linked plugin against fixture repos under `/tmp/gt/` (not kept). Rebuild such a harness for git changes.

## Release

Bump `plugin.toml` version, move `CHANGELOG.md` Unreleased under it, commit, push `main`. Users install with `tern plugin install github.com/roverdude24/tern-roost`; check it in a throwaway `TERN_CONFIG_DIR` with `TERN_DAEMON_SOCKET` pointing at a missing socket.
