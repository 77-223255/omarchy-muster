# Marketplace submission

Listing request for
[`omacom/omarchy-plugin-marketplace`](https://github.com/omacom/omarchy-plugin-marketplace),
following its
[CLI and AI submission guide](https://github.com/omacom/omarchy-plugin-marketplace/blob/main/SUBMISSION.md).

## The issue

Title:

```
[Plugin]: Muster
```

Body: [`docs/submission-body.md`](submission-body.md). That file is *only* the
six headings the validator parses — do not paste this document, it would break
the heading order and the bot would not treat the issue as a submission.

Create it with an authenticated `gh`:

```bash
gh issue create \
  --repo omacom/omarchy-plugin-marketplace \
  --title "[Plugin]: Muster" \
  --body-file docs/submission-body.md
```

Or paste that file's contents into the issue form at
<https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml>.

## Preview assets

The marketplace card comes from one optional root `preview.png` (also
`preview.jpg`, `preview.jpeg`, `preview.webp`, `preview.avif`; up to 50 MB and
40 megapixels, optimized automatically). After screenshots are in place:

- `preview.png` — repository root, the listing card. A wide crop of the open
  panel works; keep the chip visible.
- `assets/panel.png`, `assets/chip.png` — referenced by the READMEs.

## Checklist before submitting

- [x] Public repository at a repository root URL
- [x] One plugin, `manifest.json` in the repository root
- [x] Root README with installation **and** removal instructions
- [x] Root license file (`LICENSE`, MIT) and documented external dependencies
- [x] Plugin id outside the reserved `omarchy.*` namespace and unique in the
      registry (`shienze.muster` — checked against `registry.json`)
- [x] Repository is clean of binaries, downloads, and `/tmp` runtime state, so
      the automated security baseline has nothing to flag
- [ ] Root `preview.png`
- [ ] `assets/panel.png` and `assets/chip.png`

## After the issue opens

The marketplace bot posts one validation comment and one
Automated Security Baseline comment, both updated on retry. A new listing is
published only after a maintainer applies `approved-and-verified` to the exact
validated commit. Fix problems in the repository or the issue itself — do not
open a duplicate submission.
