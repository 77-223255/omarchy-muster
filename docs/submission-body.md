### Repository URL

https://github.com/77-223255/omarchy-muster

### Category

Developer Tools

### Tags

ai, bar, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

No build step, no package manager, and no network access at runtime: the plugin
is four QML files, one JavaScript helper, two shell scripts and one optional
agent plugin. The shell side uses `bash`, `find`, `sort`, `head`, `stat`, `dd`,
`mkdir`, `chmod` and `timeout`, plus `inotifywait` when it is
installed; the
record writer `bin/muster-report` uses `jq`, `flock`, `dd`, `stat`, `mv`,
`chmod`, `tr`, `cut`, `date`, `wc`, `awk`, `cat`, `head`, `od` and `rm`; focusing a session uses
`hyprctl` and, inside herdr, `herdr`; alerts use `paplay` and
`omarchy-notification-send`. All of them are common desktop tools, and the
plugin has no build step and no package of its own.

State comes from records — one small JSON file per session under
`~/.local/state/omarchy/muster/sessions/` — so the plugin never scrapes window
titles or scans processes. The bundled pi bridge (`pi/muster.ts`) is optional
and only affects pi; any other agent can be wired with the one-line
`bin/muster-report` call documented in the README. Removing the plugin leaves
the state directory, the pi bridge symlink (if it was linked) and omarchy's own
notification log behind; the removal steps in the README cover each.

The records are owner-only (`0700`/`0600`), and `bin/muster-report` reads the
prompt, the blocked detail, the session name and the working directory from
file descriptors (`--prompt-fd`, `--message-fd`, `--name-fd`, `--cwd-fd`), not
command-line arguments, so that text never reaches a process's argv; every
option that does reach a command line is limited to digits or a plain id
charset. It refuses a sessions path that is not a real directory owned by the
user, locks that directory read-only rather than through a predictable lock
file, and addresses each record through that locked descriptor. Both bundled
writers publish with an atomic rename from a staging file created exclusively
and unpredictably (`O_EXCL` on a random name for both writers — the script's
`dd conv=excl`, the bridge's `writeFileSync` with the `wx` flag), so a same-user
writer cannot redirect a write through a planted symlink or hardlink. Fields
are capped and the merged record is measured before it is published, and
`--pid` is validated as numeric before it reaches bash arithmetic. The shell
service enters and re-checks each directory component before it creates or
prunes anything; the readers re-check every path they open (regular file, not a
symlink, within the 64 KiB cap). The
completion toast is content-free by default — the agent and a fixed state word,
never the prompt. The version that does show the prompt is kept commented in
`Service.qml` and documented as opt-in, because omarchy's notification path
takes the text as argv and then persists it (upstream `basecamp/omarchy#8209`,
fix `#8259` pending). The content toast returns once that path is private.

The bar marks are omarchy's own agent glyphs, copied from
`setup.default.agent.*` in
`/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc` (eight codepoints in
`/usr/share/fonts/omarchy/omarchy.ttf`, five in the Nerd Font), so the plugin
introduces no third-party assets.

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
