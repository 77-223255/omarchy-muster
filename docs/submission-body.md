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
is four QML files plus one JavaScript helper, and it shells out only to
`hyprctl`, `find`, `mkdir`, and — when it is installed — `inotifywait`, plus
`paplay` and `omarchy-notification-send` for alerts.

State comes from records — one small JSON file per session under
`~/.local/state/omarchy/muster/sessions/` — so the plugin never scrapes window
titles or scans processes. The bundled pi bridge (`pi/muster.ts`) is optional
and only affects pi; any other agent can be wired with the one-line
`bin/muster-report` call documented in the README. Removing the plugin leaves
nothing behind except that state directory.

The records are owner-only (`0700`/`0600`), and `bin/muster-report` reads the
prompt and blocked detail from a file descriptor (`--prompt-fd`/`--message-fd`),
not a command-line argument, so user text never reaches a process's argv. It
also refuses a sessions path that is not a real directory owned by the user,
locks that directory read-only rather than a predictable lock file, and stages
each record in an exclusive `mktemp` file written with `O_NOFOLLOW`, so a
same-user writer cannot redirect a write through a planted symlink. Fields are
capped, `--pid` is validated as numeric before it reaches bash arithmetic, and
the shell service applies the same directory check before it creates or watches
the path. The
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
