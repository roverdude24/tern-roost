# Sessions

A Tern plugin: a left panel listing every session, grouped by working folder, with quick actions to open and manage them. It works on any folder: nothing is read from, or needed in, a repository.

Forked from [mmnavarr/overseer](https://github.com/mmnavarr/overseer) (MIT, see `LICENSE`); the panel mechanics are Overseer's, the folder model is new.

## Install

Needs the [Tern](https://docs.stencil.so/tern/) desktop app on macOS. Nothing else.

```sh
/Applications/Tern.app/Contents/MacOS/tern plugin install github.com/roverdude24/tern-session-folders
```

Or clone it and `tern plugin link "$PWD"` to run it from source (it reloads when files change).

It sits fine beside Overseer: different panel, different shortcut (Overseer is `⌘⌥⇧P`).

## Use

- **Show or hide**: `⌘⌥⇧L`, or the palette command *Show or hide Sessions*, or the status-line segment. The panel follows the shown tab and remembers its width.
- **Groups**: a session's folder is the working directory of its first tab (falling through to the next tab when the first has none). Unknown directories go under *Other*. Pinned folders always show, first, in the order pinned; a session inside a pinned folder is listed under the deepest one holding it. The rest follow by session count, then name. Headers collapse; the state is kept.
- **Rows**: name, tab count, and a dot: grey idle, green pulsing while an agent works, blue while one waits for you. The current session is highlighted. Click to switch.

| Where | Action |
| --- | --- |
| Header | **Find** (pick by `name — folder`), **New** (pick a pinned or in-use folder, or browse), **Add folder** (pin), ↻ |
| Folder | `+` new session there, `omp` new session whose first tab runs `omp`, ↗ reveal in Finder, 📌 pin or unpin (also right-click the header) |
| Session (right-click) | Rename, New tab here, Lock or Unlock, Close (asks first; locked sessions are refused) |
| Palette | Show or hide Sessions, Find session, New session in folder, Rename current session |

New tabs follow Settings › New tabs and splits open (shell or agent), like ⌘T.

Pinned folders, collapsed state, panel width and open state live in the plugin's key-value store.
