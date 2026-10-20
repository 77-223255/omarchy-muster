# Native emitters — who speaks OSC 7501

Status of the [Program Status Protocol][spec] (OSC 7501) as of **2026-10-19**.
The protocol was published on 2026-10-06 ([Mitchell Hashimoto's write-up][post])
and is at revision 0.4.

Muster is a **bar consumer**, not a terminal. The protocol has **no read API**
— the spec says it outright: "the only bytes a terminal writes back are the
feature detection reply … and there is no way to read records". A terminal keeps
the records; nobody else can ask it what is running. So a bar like Muster still
needs the pty: on this branch `bin/muster-tap` is the only writer — it answers
the probe itself and turns the reports it sees into records. A terminal gaining
OSC 7501 support does not feed Muster.

## Agents that emit the protocol

| Agent | Since | Emission | Evidence |
|---|---|---|---|
| Claude Code | **2.1.295** (2026-10-08) | probe-gated: it waits for the terminal's answer to `OSC 7501;?`, so it stays silent under a terminal that does not reply | changelog: "Added Program Status Protocol (OSC 7501) support" ([anthropics/claude-code](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)); the probe-gating is described in [tmux/tmux#5713](https://github.com/tmux/tmux/issues/5713) |
| pi | **1.1.0** (2026-10-07) | probe-gated; `PI_PROGRAM_STATUS=1` forces it on, `=0` forces it off | [earendil-works/pi#10607](https://github.com/earendil-works/pi/issues/10607), pi docs: *Terminal setup → Program status* |
| Crush | **v0.98.0** (2026-10-08) | release note: "Crush now supports the Program Status Protocol, aka `OSC 7501`" | [charmbracelet/crush#4041](https://github.com/charmbracelet/crush/pull/4041) |
| omp (Oh My Pi) | **v18.8.7** (2026-10-09) | `terminal.programStatus` turns it off; reports `blocked` with `kind=question` / `kind=permission` | [can1357/oh-my-pi#15026](https://github.com/can1357/oh-my-pi/issues/15026), [#15107](https://github.com/can1357/oh-my-pi/issues/15107) |
| Codex | **PR #52725**, merged 2026-10-09, released in **0.163.0** (2026-10-15) | unconditional whenever stdout is a terminal, multiplexed sessions included; `app=codex`, states `idle`/`working`/`blocked` | [openai/codex#52725](https://github.com/openai/codex/pull/52725), [0.163.0 release notes](https://github.com/openai/codex/releases/tag/rust-v0.163.0) |
| Docker Agent | **v1.150.0** (2026-10-09) | "Reports program status via OSC 7501 in both TUI and lean mode" | [docker/docker-agent#4544](https://github.com/docker/docker-agent/pull/4544) |
| Factory Droid | **CLI v0.236.0** (2026-10-08) | changelog: "Terminal activity status — Terminals that support it now show whether Droid is working, waiting on you, or done"; the changelog does not name OSC 7501, so this row is inferred from the timing and wording | [Factory changelog](https://docs.factory.com/changelog/release-notes) |

**Still pending** (requests are open upstream, nothing shipped):

| Agent | Request | State |
|---|---|---|
| opencode | [anomalyco/opencode#54179](https://github.com/anomalyco/opencode/issues/54179) — "Support OSC 7501 Program Status Protocol in the TUI" | issue closed as completed (2026-10-14), but the implementation PRs (#54402 closed, #54560 open) are not merged into a release; treat it as not shipped |
| Gemini CLI | [google-gemini/gemini-cli#29710](https://github.com/google-gemini/gemini-cli/issues/29710) — "Support OSC 7501 program status in the interactive CLI" | open (as of 2026-10-19) |

Every row is taken from a release note, a merged pull request or an open issue
upstream; the one inferred row (Factory Droid) says so explicitly. Agents that
are not listed have no upstream evidence either way — check before assuming.

## Terminals and multiplexers (the receiving side)

| Terminal | State | Evidence |
|---|---|---|
| **Rex** | implements it — the spec lives in its documentation | [superlogical.com/rex](https://www.superlogical.com/rex/docs/build/program-status), [the announcement](https://mitchellh.com/writing/program-status-osc7501) |
| **Kitty** | implemented on **master** (2026-10-13), with the 263-byte id limit and optional base64 padding; **not in a tagged release yet** (the latest is 0.49.2, 2026-10-01; nightlies are built from master, so they pick it up after that date) | [kovidgoyal/kitty#10638](https://github.com/kovidgoyal/kitty/issues/10638) (closed as completed) |
| **Ghostty** | only the **library**: the libghostty-vt parser was merged 2026-10-06 (milestone 1.4.0) and the PR says "The Ghostty app ignores these reports for now". The **1.3.1 application** (the current release, 2026-03-13) predates the parser and simply ignores the sequence; on main the library parses it, but the library keeps no records — the embedder does, and the app does not yet | [ghostty-org/ghostty#14560](https://github.com/ghostty-org/ghostty/pull/14560) |
| **tmux** | **drops it**: the probe is not answered and the sequence is logged as an unknown OSC, so nothing reaches the outer terminal and a probe-gated agent never reports at all | [tmux/tmux#5713](https://github.com/tmux/tmux/issues/5713) (open; "master `input.c` still drops 7501 as unknown") |
| **Herdr** | **drops it**: the pane OSC observer handles OSC 0/2/9 and ignores everything else; the feature request was closed as not planned | [herdrdev/herdr#5069](https://github.com/herdrdev/herdr/issues/5069), [discussion #5073](https://github.com/herdrdev/herdr/discussions/5073) |

## What this means for Muster

- **One writer per session.** On this branch there is exactly one writer:
  `bin/muster-tap`. It turns the reports it sees on the pty into records, and
  nothing else writes a record — no report script, no agent bridge, no hook.
  Two writers for one session would mean two records for one run.
- **The tap is the bridge to the agent.** `bin/muster-tap` answers
  `OSC 7501;?` itself, so an agent that waits for the terminal's answer
  reports even under Ghostty 1.3.1 — or inside tmux or Herdr, where the
  sequence would otherwise be dropped before it reaches the terminal.
- **The terminal's own UI is not Muster's source of truth.** A terminal that
  understands the protocol shows the session in its own way; the bar reads
  records, always.
- **A probe-gated emitter needs the tap.** Under a terminal that does not
  answer, Claude Code and pi report nothing at all — so an agent that is
  missing from the bar is usually a terminal problem, not a Muster problem.
  Run it under the tap and the probe is answered for it.

[spec]: https://www.superlogical.com/rex/docs/build/program-status
[post]: https://mitchellh.com/writing/program-status-osc7501
