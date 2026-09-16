# Marketplace submission

The exact text for a listing request on
[`omacom/omarchy-plugin-marketplace`](https://github.com/omacom/omarchy-plugin-marketplace),
following its
[CLI and AI submission guide](https://github.com/omacom/omarchy-plugin-marketplace/blob/main/SUBMISSION.md).

Title:

```
[Plugin]: Muster
```

Body (the six headings must stay in this order):

```
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

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
```

Create the issue with:

```bash
gh issue create \
  --repo omacom/omarchy-plugin-marketplace \
  --title "[Plugin]: Muster" \
  --body-file docs/marketplace-submission.md
```

(Strip this paragraph's fences first, or paste the body block into the issue
form at <https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml>.)

## Checklist before submitting

- [x] Public repository at a repository root URL
- [x] One plugin, `manifest.json` in the repository root
- [x] Root README with installation **and** removal instructions
- [x] Root license file (`LICENSE`, MIT) and documented external dependencies
- [x] Plugin id outside the reserved `omarchy.*` namespace and unique in the
      registry (`shienze.muster` — checked against `registry.json`)
- [ ] Root `preview.png` (optional; JPEG, WebP and AVIF also work, up to 50 MB /
      40 megapixels, optimized automatically)
