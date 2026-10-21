### Repository URL

https://github.com/77-223255/omarchy-muster

### Category

Developer Tools

### Tags

ai, bar, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

**This listing is for the protocol-only branch, and it is a deliberately narrow
plugin.** Muster shows live coding-agent sessions in the Omarchy bar, with a
completion sound and a desktop notification. The state comes from the
[Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status)
(OSC 7501) — the terminal-native way for a program to report
`idle`/`working`/`done`/`blocked`/`error` — and this branch has exactly one
writer: `bin/muster-tap` runs an agent on a pty, forwards every byte unchanged,
answers the protocol's feature probe itself, and writes the JSON record the bar
reads. There is no report script, no agent bridge and no hook: an agent that
does not speak the protocol is not a session here, and a card carries no prompt
and a session name only when the program sends `title` (pi's native messages are
`msg`, so often there is none). The record contract,
the writer and the UI are still in motion on this branch.

No build step, no package manager, and no network access at runtime. The
dependencies are:

- the bar side is QML (four QML files and one JavaScript helper) and runs
  inside the omarchy shell (Quickshell, Qt 6). It shells out to `bash`,
  `find`, `sort`, `head`, `stat`, `dd`, `mkdir`, `chmod`, `timeout`, `od` and
  `tr`, plus `inotifywait` when it is installed (optional — it only makes a
  new record appear at once instead of on the next scan);
- `bin/muster-tap` is Python 3, standard library only (`pty`, `termios`,
  `select`, `fcntl`, `struct`, `json`, `base64`, `hashlib`, `secrets`). It
  writes the records itself: a staging file, an `fsync` and an atomic rename,
  through a directory descriptor that is opened once with `O_NOFOLLOW`. There is
  no `jq`, no `flock`, no lock file, no shell pipeline and no writer process
  anywhere in the plugin;
- focusing a session uses `hyprctl`, and inside a multiplexer, `herdr` or
  `tmux`;
- alerts use `paplay` and `omarchy-notification-send`.

All of them are common desktop tools, and the plugin has no build step and no
package of its own. `bin/muster-doctor` checks every one of them and the state
directory, and exits non-zero when a required one is missing.

The records are owner-only (`0700`/`0600`), the sessions directory is refused
when it is a symlink, is not a directory or is not owned by the user, and the
writer publishes each record through a directory descriptor it holds, so a
same-user process that renames the directory or plants a symlink cannot
redirect a write. The reader treats a record as untrusted: it refuses a
symlink, a special file and anything over 64 KiB. The completion toast is
content-free — the agent's label and a fixed state word, never a prompt or a
message — because the text still goes through `omarchy-notification-send`'s
argv and the notification engine persists the summary and body in its history,
so anything more would be kept on disk. The toast names its sender as `Muster`,
so the current engine groups it, applies Do Not Disturb and snoozes, and keeps
it in history; its state mark uses the standard `image-path` hint (`--image`),
because the engine's `-i` is a themed icon name, not a file path.

The bar marks are omarchy's own agent glyphs, copied from
`setup.default.agent.*` in
`/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc` (eight codepoints in
`/usr/share/fonts/omarchy/omarchy.ttf`, five in the Nerd Font), so the plugin
introduces no third-party assets.

Removing the plugin leaves the state directory and omarchy's own notification
state (`live.json`, `history.json`, `quiet.json`) behind; the removal steps in
the README cover each. The plugin does not
overwrite user configuration: the only settings are a completion sound and a
completion notification, both toggled in the panel.

The listing name "Muster" was used by two earlier submissions that were both
closed and never listed (`fernandomenolli/omarchy-muster`, `botmarchy-muster`).
This repository is unrelated to either; the plugin id `shienze.muster` is not
present in `registry.json` and reuses no code from them.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
