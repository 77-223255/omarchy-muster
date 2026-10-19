# OSC 7501 integration plan

Status: working plan for the `osc7501` branch after merging `main` (2026-10-19).

## Goal

Make Muster the Omarchy bar's OSC 7501 consumer. The terminal may ignore the
protocol; `bin/muster-tap` sits in the pty path, answers the feature probe, and
turns native reports into Muster records. The JSON record stays Muster's
internal contract, so a 0.x spec cannot break the UI.

Non-goals for this pass: a full terminal model (256-record cap, RIS/DECSTR,
alternate screen, arbitrary hierarchy), and replacing hooks for every agent.

## Roles

- **native emitter**: Claude Code (probe-gated), pi (probe-gated or
  `PI_PROGRAM_STATUS=1`), Codex (unconditional on a tty), Crush, omp.
- **tap**: wraps an agent on a pty, answers `OSC 7501;?`, forwards bytes
  unchanged, writes records.
- **hook / `muster-report`**: fallback for agents with no native support and
  for fields OSC does not carry (prompt, session name, window/pane).
- **bar**: reads records; never reads another process's terminal.

Protocol records belong to the terminal and are not readable by a third party
(the spec has no read API). A bar therefore needs tap or a hook; a terminal
gaining OSC 7501 support does not feed Muster.

## Interface contract

Records gain an optional `terminalId` (a stable id for the pty/tap instance):

- CLI: `muster-report --terminal-id <id>`; env `MUSTER_TERMINAL_ID` as fallback.
- Shape: `^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`; empty means absent.
- `bin/muster-tap` uses `tap:<pid>`.
- `Model.normalizeRecord` exposes `terminalId`.
- `Service.rebuild` keys a session by
  `terminalId + recordId` when `terminalId` is present; otherwise it keeps the
  old `pid`/`path` key. This lets one tap own several records without the
  "one session per pid" collapse.
- Record file names stay `agent~session.json`; a tap's `session` is
  `tap-<pid>` for the root record and `tap-<pid>-<safe id>` for a child.
- `recordId` stays the protocol `id` and is display/grouping data only; it never
  names a file or reaches a command line.

## Protocol corrections (from spec rev 0.4)

- A report without `state` is ignored; do not default to `working` when reading
  an `--osc-fd` body.
- A report is discarded **whole** on bad base64, a decoded control character,
  or a limit breach. Do not keep `state` while dropping only `title`/`msg`.
- Unknown `kind` is absent; non-integer/out-of-range `progress` is absent. They
  must not fail the whole report.
- Trim whitespace around keys/values; do not remove whitespace inside a value.
  A pair whose value has a byte outside the wire charset is skipped.
- Limits: whole sequence 4096; key 16; `app` 32; `id` 263 total (8 x 32 + 7),
  32 per segment, 8 levels; `title` 256 encoded / 192 decoded; `msg` 2732
  encoded / 2048 decoded.
- `clear` removes the addressed record and every record beneath it; root clear
  removes every record for that terminal.
- `working`/`blocked` die on process exit and on a new shell prompt (OSC 133 A);
  `done`/`error` survive both. No heartbeat is required by the spec.

## Workstreams

1. `bin/muster-tap` (receiver): probe reply with `states`/`kinds`, per-tap
   record registry, `app` inheritance, root/child clear, all live records
   removed on child exit, OSC 133 A, stable session keys, `terminalId`.
2. `bin/muster-report` (writer): `terminalId`, whole-report validation, unknown
   kind/progress tolerance, `--remove` emits `clear`, spec limits.
3. `Model.js` / `Service.qml` / `Panel.qml` / `BarWidget.qml`: `terminalId` and
   multi-record keys, `recordId` display fallback, `progress`/`kind` gating.
4. `pi/muster.ts` + docs: pi native emission means the bridge must not double
   emit by default; document the tap-vs-bridge matrix and the terminal gap.
5. Tests: fixtures from real Claude/pi sequences and Kitty/Ghostty parser tests.

## File ownership (parallel work)

- A: `bin/muster-tap`, `tests/test_tap.py`.
- B: `bin/muster-report`, `bin/muster-doctor`, `tests/test_report.py`.
- C: `Model.js`, `Service.qml`, `Panel.qml`, `BarWidget.qml`,
  `tests/test_model.js`.
- D: `pi/muster.ts`, `README.md`, `README.zh.md`, `docs/osc7501.md`,
  `manifest.json`, `tests/test_pi.md` (or none).

No worker commits or checks out; the chef reviews and commits.

## Verification

- `bash -n`, `shellcheck`, `python3 -m py_compile`, `node --check`.
- `tests/test_*` under a temp `XDG_STATE_HOME`.
- `qmllint` for syntax (warnings may be pre-existing).
- One end-to-end synthetic tap: working -> blocked(kind) -> done, a second id,
  then `clear`; assert one record per id and correct lifetimes.
- A real pi run under tap (native), and a real Claude Code run where possible.
