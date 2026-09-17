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
`hyprctl`, `find`, `mkdir` and (for alerts) `paplay` plus
`omarchy-notification-send`.

State comes from records — one small JSON file per session under
`~/.local/state/omarchy/muster/sessions/` — so the plugin never scrapes window
titles or scans processes. The bundled pi bridge (`pi/muster.ts`) is optional
and only affects pi; any other agent can be wired with the one-line
`bin/muster-report` call documented in the README. Removing the plugin leaves
nothing behind except that state directory.

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
