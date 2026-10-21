# Muster

**English** · [中文](README.zh.md)

> [!WARNING]
> **Protocol-only experiment — not usable as a daily plugin, not released.**
> This branch is one lane and one lane only: an agent that speaks the
> [Program Status Protocol][osc7501] (OSC 7501) itself, run under
> `bin/muster-tap`, which turns its reports into the JSON records the bar
> reads. There is **no report writer, no agent bridge and no hook** here: an
> agent that does not speak the protocol is not a session, and a card shows
> **no prompt**; a session name only appears when the program sends `title`
> (pi's native messages are `msg`, so often there is none).
> The record contract, the writer and the UI are all still in motion, so
> expect breaking changes. Do not install or depend on this branch; `main`
> remains the full plugin. See [`docs/osc7501.md`](docs/osc7501.md) for the
> protocol and [`docs/native-emitters.md`](docs/native-emitters.md) for the
> support matrix.

Live coding-agent sessions in the Omarchy bar, with a completion sound and a
desktop notification — no multiplexer required, and a click jumps to the right
pane when you do use one (tmux or herdr).

- **Bar chip** — one mark per agent that has a session, in the order that needs
  attention (blocked first, then working). Each mark is coloured by its own
  session's state — the urgent colour when that agent is blocked, the theme
  accent while it runs, plain bar text when it is idle — so a mixed bar reads at
  a glance instead of turning one colour. The marks are omarchy's own — the
  ones its menu shows for `omarchy default agent` — so they are brand glyphs
  rather than invented symbols. The window is deliberately short: past five
  marks it clips and scrolls, the way the media widget runs a long track title,
  so a busy bar never pushes the clock around. Always visible; a bell when
  nothing is running, because a chip that disappears is a chip you cannot click.
- **Panel** (click the chip) — one card per session: the agent's mark and the
  folder it is working in, then whatever the state has to say (the protocol's
  `msg` when it is blocked, or when a run has ended). No agent name on the card
  — the mark says who, the folder says where — and no prompt: the protocol does
  not carry one. The card interior is always the same grey; the state lives on
  the rim and in the title: a working card gets a soft theme-coloured rim that
  breathes, a blocked card the urgent colour, idle nothing. No elapsed timers:
  the panel answers "is anything running and does it need me".
- **Alerts** — when a run finishes, a sound and an Omarchy notification.
  Clicking the notification focuses that session's terminal — and, for a session
  inside tmux or herdr, switches the multiplexer to the pane it runs in. In the
  panel, **left-clicking a card** focuses that session's terminal too, and
  **right-clicking** one fires the same alert on demand, with `test` in the
  notification title so it cannot be mistaken for a real completion.

## Screenshots

![The panel](assets/panel.png)

![The bar chip](assets/chip.png)

![The alert (a test alert; a real one names the agent and says "Run finished")](assets/notification.png)

Captures live in [`assets/`](assets/README.md); the marketplace listing card is
one optional root `preview.png`.

## How it gets state

**Reports, never guesses.** Muster speaks the [Program Status Protocol][osc7501]
(OSC 7501), the terminal-native way for a program to report what it is doing —
`idle`, `working`, `done`, `blocked`, `error`, with a `kind`, a `progress` and a
one-line `msg`. The agent writes that protocol sequence to its terminal itself;
`bin/muster-tap` sits in the pty path, answers the feature probe, and turns
every report into one small JSON record, which the plugin watches. The state is
never inferred from a window title or a process list, and there is no rule
engine — nothing that can guess a state wrong or silently stop working. (The
window id *is* looked up from the parent chain when a session starts, but only
to make a click focus the right terminal; it never decides a session's state.)

There is exactly **one writer** in this branch: the tap. It writes the record
itself, in Python, with the standard library only — no shell pipeline, no
`jq`, no lock file, no writer process. A record is staged and renamed
onto its final name, so the reader never sees half a record, and the sessions
directory is opened once and every write goes through that descriptor.

Agents that already speak the protocol — Claude Code 2.1.295+, pi 1.1.0+,
Crush 0.98+, omp 18.8.7+, Codex 0.163.0+ and others — need no per-agent code
at all: run them under `bin/muster-tap` and their reports become records.
[`docs/native-emitters.md`](docs/native-emitters.md) has the matrix, with the
upstream evidence.

[osc7501]: https://www.superlogical.com/rex/docs/build/program-status

## Install

```bash
# 1. the shell plugin
omarchy plugin add https://github.com/77-223255/omarchy-muster.git --enable
omarchy plugin enable shienze.muster left     # placement, if you skipped --enable

# 2. verify every dependency it shells out to
~/.config/omarchy/plugins/shienze.muster/bin/muster-doctor
```

Changing a `.qml` file hot-reloads the widget, but `Model.js` (a cached QML
library) and the IPC target only change on `omarchy restart shell`.

### Working from a checkout

`omarchy plugin add` already leaves a Git checkout at
`~/.config/omarchy/plugins/shienze.muster/`, complete with its `origin` remote,
so edit the files there: the widget hot-reloads on every `.qml` save, and you can
branch, commit, and push from that directory like any other clone.
`omarchy plugin update shienze.muster` brings new upstream commits into it.

If you would rather work in a checkout you keep elsewhere, point the plugin path
at it with a symlink — the shell follows the symlink, and the plugin id still
comes from `manifest.json`:

```bash
ln -sfn ~/Projects/omarchy-muster ~/.config/omarchy/plugins/shienze.muster
omarchy-shell shell rescanPlugins
omarchy plugin enable shienze.muster left
```

## Removal

```bash
# 1. the shell plugin (removes the bar entry and the plugin directory)
omarchy plugin disable shienze.muster
omarchy plugin remove shienze.muster

# 2. the session records it read
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/muster"
```

`omarchy plugin remove` deletes the plugin directory and its entry in
`~/.config/omarchy/shell.json`, and nothing else. Omarchy's notification state
under `~/.local/state/omarchy/notifications/` (`live.json`, `history.json`,
`quiet.json`) is the shell's own; delete it too if you want the toast history
and quiet state gone. If you installed from a
checkout with the symlink above, delete the symlink and your clone instead:

```bash
rm -f ~/.config/omarchy/plugins/shienze.muster
rm -rf ~/Projects/omarchy-muster
```

Nothing outside `~/.config/omarchy/`, the state home and the shell's own log is
written, and no user configuration is overwritten without you doing it from the
panel. The state home is `$XDG_STATE_HOME` (or `~/.local/state`), and the plugin
creates `omarchy/muster/sessions` and `omarchy/muster/marks` under it — plus
`omarchy` itself and `~/.local/state` if they are not there yet. (A record that
cannot be parsed is reported once in the shell log, so the shell journal can
contain that file's name.) Removing the plugin does not remove that state; the
uninstall step above does. (The completion alert also asks omarchy's own
notification service to show a toast, and that service keeps its state under
`~/.local/state/omarchy/notifications/`; the plugin sends it no prompt, no
message and no session name — only the agent's label, a fixed state word, and
the window id the click needs.)

**Privacy.** A record carries the working directory, the protocol's `title` and
`msg`, and the ids of the terminal and the pane the session runs in. That state
never leaves this machine. The `sessions/` directory and its records are
created owner-only (`0700` / `0600`) so another local user cannot read them,
and `muster-doctor` reports the modes if you want to check. A process running
as you can still read, write or delete them: the bar is not an isolation
boundary between same-user programs. There is no prompt
in a record to leak: the protocol does not carry one, and this branch does not
go looking for it.

## Using it

```bash
# run an agent under the tap: it reports, the tap writes the record
bin/muster-tap -- claude
bin/muster-tap -- pi
bin/muster-tap -- codex
bin/muster-tap -- crush
bin/muster-tap -- omp
```

`muster-tap` forwards every byte unchanged, so the agent behaves exactly as it
would without it; the only difference is that its OSC 7501 reports become
records. It answers the protocol's support query itself, so an agent that waits
for the terminal to confirm support reports even under a terminal that never
answers — Ghostty 1.3.1, or tmux and Herdr, which drop the sequence entirely.
It removes a live record when the agent exits (a `done`/`error` record is left
behind).

An agent that does not speak OSC 7501 is **not** a session on this branch.
There is no hook to install and no script to call: that is the point of the
experiment.

| Where | Action |
|-------|--------|
| Bar chip | left click = panel, middle click = test alert |
| Panel card | left click = focus that session's terminal, right click = test alert |
| Panel keys | `j`/`k` move, Enter focuses the selected card, `t` tests it, Esc closes |
| IPC | `omarchy-shell shienze.muster <open\|close\|toggle\|test\|status>` |

```bash
omarchy-shell shienze.muster status | jq '.details[]'
# {"agent":"claude","state":"working","kind":"","progress":-1,"recordId":"build",
#  "terminalId":"tap:4711:9f2c1a04","folder":"omarchy-muster","pid":4711,
#  "window":"0x601dc3f347b0","pane":"","tmux":""}
```

## Settings

Two settings, in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|-----|---------|---------|
| `soundEnabled` | `true` | Chime when a run finishes |
| `notifyEnabled` | `true` | Desktop notification when a run finishes |

Both are the toggles in the panel, and both are declared in the manifest, so
omarchy's own settings screen offers them too.

**The notification is content-free**: it carries the agent's label and a fixed
state word ("Run finished", "Run failed", "Needs your input"), never a prompt
or a message. The text still goes through `omarchy-notification-send`'s argv
(visible from `/proc/<pid>/cmdline`) and the notification engine persists the
summary and body in its history under `~/.local/state/omarchy/notifications/`,
so anything more would be kept on disk. This branch has no setting that changes
that: there is no prompt to show in the first place.

The toast names its sender as `Muster`, so the current Omarchy notification
engine groups Muster's cards, applies Do Not Disturb and per-source snoozes,
and keeps them in history. (The sender's default name, `omarchy-action`, is
reserved for Omarchy's own confirmation toasts: it bypasses quiet and is
dropped when silenced.) The state mark is sent with `--image`; the engine's
`-i` is a themed icon name, not a file path.

Everything else is deliberately internal — a widget whose alerts went quiet
because of a stray setting is worse than one you tune by editing a line. They
live at the top of `Service.qml`:

| Constant | Value | Meaning |
|----------|-------|---------|
| `refreshIntervalSec` | `2` | Fallback rescan cadence; `inotifywait` makes new records appear at once |
| `staleAfterSec` | `120` | Forget a record whose writer stopped |
| `settledAfterSec` | `21600` | Keep a finished (`done`/`error`) record for six hours |
| `debounceMs` | `2000` | One alert per 2s: a completion inside the window is dropped |
| `soundFile` | freedesktop `complete.oga` | |
| `soundPlayer` | `paplay` | `pw-play` / `mpv` work too |

## The record contract

One JSON object per session in
`$XDG_STATE_HOME/omarchy/muster/sessions/` (default
`~/.local/state/...`), named `<agent>~<session>.json`. The tap writes it
atomically (staging file + `rename`) and replaces it whole on every report.

| Field | Notes |
|-------|-------|
| `schemaVersion` | `2` |
| `agent` | required; the protocol's `app`. Any id works, and omarchy's own aliases (`claude-code`, `oh-my-pi`, `cursor`, …) fold into their canonical agent |
| `sessionId` | the tap's name for the session (`tap-<pid>-<token>`, plus a digest for a child id) |
| `name` | the protocol's `title`; a short label |
| `cwd` | where the session runs |
| `project` | the basename of `cwd` |
| `state` | `working` \| `blocked` \| `done` \| `error` \| `idle` \| `unknown` |
| `kind` | `permission` \| `question` \| `auth`, when `blocked`; absent otherwise |
| `progress` | integer `0`–`100`, or `-1` for absent; kept only while `working` or `blocked` |
| `recordId` | the protocol's hierarchical `id` (`build/test`); display only, never a path |
| `message` | the protocol's `msg`; shown when `blocked`, `done` or `error` |
| `pid` | the agent's process; a hint for display/focus, not the record identity |
| `windowAddress` | Hyprland address; makes the notification's click focus that terminal |
| `herdrPane` | herdr pane id (`w1:p6`); a herdr session's pane has no window of its own, so a click switches to it with `herdr agent focus` |
| `tmuxPane` | tmux pane id (`%3`); a click selects the window and pane and moves the attached client to it |
| `tmuxSocket` | tmux server socket (absolute path, from `$TMUX`); empty means the default server |
| `terminalId` | a stable id for the tap that owns the record (`tap:<pid>:<token>`); the bar keeps one card per record file, so one tap can own several records |
| `updatedAt` | ms epoch; drives staleness (`staleAfterSec`, `settledAfterSec`) |

There is no `lastPrompt` and no `completedRuns`: the protocol carries no prompt
and no run counter, so the record has nowhere to put them. A card shows the
agent, the folder, the state and the protocol's own `msg` — nothing more.

**The alert fires on the state edge into `done` or `error`**: the record was
`working` (or `blocked`) and is now settled. There is no counter to compare,
because the protocol does not have one. A run that finished after Muster
started is still announced once if a scan missed the working edge; a record
already settled before Muster started stays silent. A settled record outlives its writer
and ages on the much longer `settledAfterSec` clock, and focusing it
acknowledges it, so the card falls back to `idle`.

**Several records per terminal.** A report with an `id` (`build/test`) is a
record of its own, filed under its own file, with its own card; a report with
no id is the terminal's root record. A record without an `app` inherits the app
of its nearest ancestor. `state=clear` is a command, not a state: it removes
the addressed record **and every record beneath it**, and a clear with no id
removes every record of that terminal.

**Lifetime.** `working` and `blocked` are dropped when the agent exits and when
a new shell prompt appears (OSC 133 `A`); `done` and `error` survive both, so
the user finds the result. Muster adds its own clock on top: a record whose
writer stopped goes stale after `staleAfterSec`, a settled one ages out after
`settledAfterSec`, and the shell prunes anything older than seven days.

## The agents omarchy ships

Every agent `omarchy default agent` accepts (fifteen today) is known by name,
plus the spellings an integration might use for them — `claude-code`,
`oh-my-pi`, `open-code`, `cursor`, `cursor-cli`, `github-copilot`,
`gemini-cli`, `antigravity`, `kimi-code`, `openrouter`, `muse-code`, and a few
that only this plugin folds (`anthropic`, `openai-codex`, `pi-coding-agent`).
A record written under any of them groups with the canonical agent instead of
becoming a second one. Gemini stays a distinct id for older integrations, even
though the current default-agent list no longer offers it. The `also accepts`
column below is the folding, not a claim about `omarchy default agent` itself,
which takes a smaller set.

The bar chip draws each agent with omarchy's own mark, taken from
`setup.default.agent.*` in
`/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc`: nine are brand glyphs
in `/usr/share/fonts/omarchy/omarchy.ttf` (U+E901…U+E90D) and seven are Nerd
Font glyphs (the six current Omarchy agents plus Gemini), exactly as omarchy's
own menu draws them.

| id | shown as | also accepts |
|----|----------|--------------|
| `pi` | Pi | `pi-coding-agent` |
| `omp` | Oh My Pi | `oh-my-pi` |
| `opencode` | OpenCode | `open-code` |
| `claude` | Claude | `claude-code`, `anthropic` |
| `codex` | Codex | `openai-codex` |
| `copilot` | Copilot | `github-copilot` |
| `crush` | Crush | |
| `cursor-agent` | Cursor | `cursor`, `cursor-cli` |
| `gemini` | Gemini | `gemini-cli` |
| `agy` | Antigravity | `antigravity`, `google-antigravity` |
| `grok` | Grok | |
| `hermes` | Hermes | |
| `kimi` | Kimi | `kimi-code` |
| `muse` | Muse | `muse-code`, `musecode` |
| `openclaw` | OpenClaw | |
| `ori` | Ori | `openrouter` |

Anything else works too and is shown under its own id (no mark until one is
given). Adding an agent is one line in the `AGENTS` table at the top of
`Model.js`, carrying omarchy's own codepoint for it — plus one line in
`Service.qml`'s `markScript` if you want the completion toast to carry that
agent's icon too, since the toast icon is a generated SVG named after the id.

## Native emitters

An agent has to speak OSC 7501 itself to be a session on this branch. The
matrix, with the upstream evidence, is in
[`docs/native-emitters.md`](docs/native-emitters.md); the short version:

| Agent | Since | Emission |
|---|---|---|
| Claude Code | 2.1.295 | probe-gated: it waits for the terminal's answer to `OSC 7501;?` |
| pi | 1.1.0 | probe-gated; `PI_PROGRAM_STATUS=1` forces it on |
| Crush | 0.98.0 | unconditional |
| omp | 18.8.7 | reports `blocked` with `kind=question` / `kind=permission` |
| Codex | 0.163.0 | unconditional whenever stdout is a terminal |
| Docker Agent | 1.150.0 | TUI and lean mode |
| Factory Droid | 0.236.0 | inferred from the changelog wording |

Probe-gated emitters stay silent under a terminal that does not answer the
query — Ghostty 1.3.1, or tmux and Herdr, which drop the sequence. That is
what the tap is for: it answers the query on the pane's behalf.

## Security checks

`python3 tests/security.py` runs the adversarial suite distilled from the
[agent-security-playbook](https://github.com/77-223255/agent-security-playbook):
shellcheck, semgrep, gitleaks and qmllint, then hostile umask and permission
repair, symlink/FIFO/oversized records, argv and arithmetic injection, lock
concurrency and timeout, a 10 000-file listing, and the exact QML read, setup
and mark scripts. It uses temporary state homes and never touches the installed
plugin's records.

## Dependencies

No build step, no package manager, no network access. The language of the
writer is Python because it is a per-session pty filter, and Python's `pty` and
`termios` are the shortest honest way to filter a terminal.

| Piece | Language | Depends on |
|-------|----------|-----------|
| `Service.qml`, `BarWidget.qml`, `Panel.qml`, `Record.qml` | QML | omarchy shell (Quickshell, Qt 6), `bash`, `find`, `sort`, `head`, `stat`, `dd`, `mkdir`, `chmod`, `timeout`, `od`, `tr`, `hyprctl`, `inotifywait` (optional), `tmux` / `herdr` (optional; only for a session inside them) |
| `Model.js` | JavaScript (QML engine) | nothing |
| `bin/muster-tap` | Python 3 | `pty`, `termios`, `select`, `fcntl`, `struct`, `json`, `base64`, `hashlib`, `secrets` (all stdlib) |
| alerts | — | `paplay` (or `pw-play`/`mpv`) and `omarchy-notification-send` |

`bin/muster-doctor` checks all of these (`--json` for machines) and exits
non-zero when a required one is missing. It also checks the state directory:
it must be a real, owner-only (`0700`) directory, and the records in it must
be owner-only (`0600`) plain files.

Rust would not help here. It cannot be a Quickshell plugin, so a compiled
component could only be a separate daemon with a socket — which is the heavy
thing this plugin exists to avoid. `bin/muster-tap` is Python on purpose: it is
a per-session wrapper, not a daemon, and the standard library is enough.

## Deliberately out of scope

Detecting agents that publish nothing (window-title scraping, process
sniffing). It was built, it worked, and it was ~700 extra lines plus a rule
engine, because a widget outside the terminal cannot see the pane contents —
and terminals that host several windows in one process (ghostty
single-instance, kitty) make `pid → window` ambiguous, so a title match alone
proves very little. On this branch the answer is narrower still: an agent that
does not speak the protocol is not a session, and there is no hook to install.

## Files

| Path | Purpose |
|------|---------|
| `manifest.json` | plugin manifest (`service` + `bar-widget`) |
| `Service.qml` | singleton: watch records, sort sessions, fire alerts |
| `BarWidget.qml` | bar chip, settings push, IPC |
| `Panel.qml` | session panel and the two toggles |
| `Record.qml` | one watched session record |
| `Model.js` | record normalization, ordering, agent names and marks |
| `bin/muster-tap` | the pty receiver and the only writer: OSC 7501 on the wire → records |
| `bin/muster-doctor` | dependency and state check |
| `tests/security.py` | adversarial security checks from the playbook |
| `docs/osc7501.md` | how Muster speaks the Program Status Protocol |
| `docs/osc7501-plan.md` | what this branch is, and what was taken out of it |
| `docs/native-emitters.md` | who speaks OSC 7501 today, with versions and upstream evidence |
| `docs/submission-body.md` | the exact issue body for a marketplace listing |
| `docs/marketplace-submission.md` | how to file that issue |
| `assets/` | README screenshots |
| `preview.png` | root listing card for the marketplace (optional) |

## Troubleshooting

```bash
omarchy-shell shienze.muster status | jq '.details[]'   # what the widget sees
~/.config/omarchy/plugins/shienze.muster/bin/muster-doctor   # dependencies and state
journalctl --user --since "5 min ago" -o cat SYSLOG_IDENTIFIER=omarchy-shell | grep -i muster
omarchy-shell shienze.muster test                        # prove the alert path
```

- **Chip stays dim**: no record is being written. Run the agent under
  `bin/muster-tap`, and check that the agent speaks OSC 7501 at all — see the
  matrix in `docs/native-emitters.md`.
- **Nothing at all under tmux or Herdr**: those drop the OSC 7501 sequence, so
  the agent has to run under the tap — which answers the probe for it.
- **A session lingers after a crash**: it disappears from the widget
  `staleAfterSec` after the last write, and its record is deleted a week
  later (the shell prunes old records when it starts).
- **No sound**: `command -v paplay`, and check the *Sound* toggle in the panel.
- **IPC function missing after an edit**: `omarchy restart shell`.

## License

MIT — see [LICENSE](LICENSE).
