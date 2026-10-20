# OSC 7501 — the protocol-only branch

Status: a short note on what this branch **is**, and on what was taken out of
it. The plan that produced the branch is over; this is the shape that survived
it.

## The state lane

There is exactly one path from an agent to the bar:

```
agent ──OSC 7501 on its pty──▶ bin/muster-tap ──one JSON record──▶ sessions/ ──▶ the bar
```

- the **agent** is a native emitter — it writes the protocol sequence to its
  terminal itself (Claude Code, pi, Codex, Crush, omp; see
  [`native-emitters.md`](native-emitters.md));
- the **tap** is a pty filter: it runs the agent on a pseudo-terminal, answers
  the protocol's feature probe so a probe-gated agent reports even under a
  terminal that does not answer, and writes one JSON record per report;
- the **record** is the bar's input: one small file per session under
  `$XDG_STATE_HOME/omarchy/muster/sessions/`, read by the omarchy service;
- the **bar** shows it and fires the alert on the state edge into `done` or
  `error`.

Nothing else touches the state. The bar never reads a terminal, never talks
to an agent, and never guesses.

## What was taken out

The branch used to have three writers and an enrichment lane. All of it is
gone:

| Removed | Why |
|---|---|
| `bin/muster-report` (a Bash writer driven by `jq` and `flock`) | a second writer for the same record; the tap writes the record itself, in Python, with the standard library only |
| `pi/muster.ts` (a pi extension that wrote a record and could emit OSC) | a third writer, and a second way for the same session to appear twice |
| hooks (`--prompt-fd`, `--state`, `--remove`, …) | the enrichment lane; see below |
| the record's `lastPrompt`, `completedRuns`, `seq` | the protocol carries no prompt and no run counter, so these were guesses dressed as fields |
| the `notifyContent` setting | a toast with a prompt in it would put the prompt on a command line and in a log file |
| `--emit-osc` (writing the sequence back to the terminal) | with one writer there is nothing to mirror |

The alert trigger moved with them: there is no counter to compare any more, so
a finished run is the **state edge** into `done`/`error`.

## Why

This branch is an exploration of one question: *what does the bar look like
when the state comes from the protocol alone?* The answer is a much smaller
plugin:

- **one writer** — one file that owns the record contract, in one language,
  with no shell pipeline and no lock file to audit;
- **no enrichment** — nothing in the record that the protocol did not
  actually say. A card that shows the agent, the folder, the state and the
  protocol's own `msg` is honest; a card that also shows a prompt the
  protocol never carried is a guess;
- **fewer surfaces** — no hook to install, no extension to link, no
  `MUSTER_*` switches to remember. You run an agent under `muster-tap`, and
  that is the whole contract.

The cost is the obvious one: an agent that does not speak OSC 7501 is not a
session here, and a card has no prompt; a name appears only if the program
sends `title`. That is the trade
this branch makes on purpose.

## If the prompt or the name comes back

The protocol is not the only possible source of a prompt or a session name —
an agent's own hook, its API or its transcript has them. If that is ever
wanted again, it should come back as a **separate lane** that writes into the
same record, and it must not become a second protocol writer:

- the lane would be opt-in per agent, and the tap's `MUSTER_TAP=1` flag would
  let it stand down for a session the tap already owns;
- the record would gain back exactly the fields the lane can justify
  (`lastPrompt`, maybe a `name`), and nothing else;
- the alert trigger would stay the state edge, so a lane that misses a run
  cannot double it;
- the notification would stay content-free, because omarchy's notification path
  takes the text as argv and persists it.

In other words: the enrichment lane returns as an *addition* to the record
contract, never as a second writer and never as a second way to be "the
writer".
