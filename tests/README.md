# Tests

`scenarios.sh` seeds a matrix of agents, states and edge cases through
`bin/muster-report`, then checks the record contract and the three surfaces it
feeds:

- **bar chip** — one mark per agent, coloured by that agent's session state
- **panel** — one card per session, sorted blocked → working → unknown → idle
- **toast** — `test · ` / `alert · `, the agent mark, and the state colour

```bash
tests/scenarios.sh                 # data checks + screenshots
tests/scenarios.sh --no-visual     # data checks only
tests/scenarios.sh --keep          # leave the seeded session records in place
MUSTER_SHOTS=/tmp/foo tests/scenarios.sh
```

Data checks (session data, generated marks, `Model.js` helpers) assert and set
the exit status. Visual checks only write screenshots for a human to look at —
pixel diffs would break on every theme:

```
$MUSTER_SHOTS/bar-*.png        bar chip over ~10s, so the scroll is visible
$MUSTER_SHOTS/panel-top.png    the panel with a session per agent
$MUSTER_SHOTS/toast-test.png   the test alert a test · <title>
$MUSTER_SHOTS/toast-alert.png  a real completion alert, alert · <title>
```

The run seeds sessions whose file names end in `-scn-<id>.json` and removes
exactly those on exit. Your own agent sessions are never touched.
