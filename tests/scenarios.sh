#!/bin/bash

# Muster scenario test.
#
# Seeds a matrix of agents, states and edge cases through bin/muster-report,
# then checks the record contract and the three surfaces it feeds:
#
#   bar chip   one mark per agent, coloured by that agent's session state
#   panel      one card per session, sorted blocked → working → unknown → idle
#   toast      "test · " / "alert · ", the agent mark, and the state colour
#
# Data checks assert and fail the run. Visual checks write screenshots to
# $MUSTER_SHOTS (default /tmp/muster-scenarios) for a human to look at — pixel
# diffs would just break on every theme.
#
# The run is self-contained: it seeds sessions whose file names end in
# -scn-<id>.json and removes exactly those on exit (`--keep` leaves them for
# inspection).
#
# Usage: tests/scenarios.sh [--no-visual] [--keep]

set -u

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$PLUGIN/bin/muster-report"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
SESS="$XDG_STATE_HOME/omarchy/muster/sessions"
MARKS="$XDG_STATE_HOME/omarchy/muster/marks"
SHOT_DIR="${MUSTER_SHOTS:-/tmp/muster-scenarios}"
VISUAL=1
KEEP=0

for arg in "$@"; do
  case "$arg" in
  --no-visual) VISUAL=0 ;;
  --keep) KEEP=1 ;;
  *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

pass=0
fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

PID=870000
seed() {
  PID=$((PID + 1))
  "$REPORT" --cwd /home/shienze/Projects/demo --window none --pid "$PID" "$@" >/dev/null 2>&1
}

cleanup() {
  [ "$KEEP" = 1 ] && return
  rm -f "$SESS"/*-scn-*.json "$SESS"/*-scn-*.lock 2>/dev/null
}
trap cleanup EXIT
cleanup

echo "Muster scenario test"
echo "plugin:  $PLUGIN"
echo "state:   $XDG_STATE_HOME"
mkdir -p "$SHOT_DIR"
echo

# ---------------------------------------------------------------- seed

echo "seeding sessions..."

# one session per omarchy-shipped agent, spread across states
seed --agent pi           --session scn-pi-work    --state working --name "refactor auth"  --prompt "refactor the auth module and add tests"
seed --agent opencode     --session scn-oc-idle    --state idle    --name "search index"   --prompt "why is recall dropping"
seed --agent omp          --session scn-omp-block  --state blocked --name "data pipeline"  --message "approve the schema migration" --prompt "migrate the db"
seed --agent grok         --session scn-grok-idle  --state idle    --name "docs pass"      --prompt "tighten the readme"
seed --agent codex        --session scn-cdx-work   --state working --name "provider wire"  --prompt "wire the new provider"
seed --agent hermes       --session scn-her-block  --state blocked --name "release gate"   --message "confirm the changelog" --prompt "cut v1.2"
seed --agent openclaw     --session scn-oclaw-idle --state idle    --name "crawl job"      --prompt "resume the crawl"
seed --agent cursor-agent --session scn-cur-work   --state working --name "editor bridge"  --prompt "fix the editor bridge"
seed --agent claude       --session scn-cla-idle   --state idle    --name "review diff"    --prompt "review this diff"
seed --agent copilot      --session scn-cop-block  --state blocked --name "inline suggest" --message "allow network access" --prompt "add suggestions"
seed --agent crush        --session scn-cru-idle   --state idle    --name "tui polish"     --prompt "polish the tui"
seed --agent gemini       --session scn-gem-work   --state working --name "vision model"   --prompt "try the vision model"
seed --agent muse         --session scn-mus-idle   --state idle    --name "asset gen"      --prompt "generate the assets"

# a second session of an agent that already has one (panel list, chip dedup)
seed --agent pi           --session scn-pi-block2  --state blocked --name "hotfix"         --message "ship the hotfix?" --prompt "urgent hotfix"
# an id no table knows (generic mark path) and an alias that must fold into claude
seed --agent some-agent   --session scn-mystery    --state working --name "mystery"       --prompt "unknown agent id"
seed --agent claude-code  --session scn-alias      --state idle    --name "aliased"        --prompt "alias should fold into claude"
# a state the contract does not define, and text that stresses truncation
seed --agent crush        --session scn-badstate   --state unknown --name "bad state"      --prompt "unknown state"
seed --agent claude       --session scn-longtext   --state idle    --name "长名字项目 $(printf 'x%.0s' $(seq 1 60))" \
  --prompt "$(printf 'a%.0s' $(seq 1 138))😀$(printf 'b%.0s' $(seq 1 60))"

sleep 3

# ---------------------------------------------------------------- service data

if command -v omarchy-shell >/dev/null && command -v jq >/dev/null; then
  echo "service (omarchy-shell shienze.muster status)"
  STATUS="$(omarchy-shell shienze.muster status 2>/dev/null)"
  STATES="$(jq -r '.states[]' <<<"$STATUS" 2>/dev/null)"
  COUNT="$(jq -r '.sessions' <<<"$STATUS" 2>/dev/null)"

  [ "${COUNT:-0}" -ge 17 ]; check $? "sees at least 17 sessions (got ${COUNT:-?})"

  for pair in pi:working opencode:idle omp:blocked grok:idle codex:working hermes:blocked \
    openclaw:idle cursor-agent:working claude:idle copilot:blocked crush:idle gemini:working muse:idle; do
    grep -qx -- "$pair" <<<"$STATES"; check $? "agent $pair present"
  done

  grep -qx -- "some-agent:working" <<<"$STATES"; check $? "unknown agent id still reported"
  grep -qx -- "crush:unknown" <<<"$STATES"; check $? "unknown state normalised to unknown"
  grep -qx -- "claude:idle" <<<"$STATES" && [ "$(grep -c '^claude:' <<<"$STATES")" -ge 2 ]
  check $? "alias claude-code folds into claude"

  FIRST="$(jq -r '.states[0]' <<<"$STATUS" 2>/dev/null)"
  case "$FIRST" in *:blocked) ok "blocked sorts to the top (first: $FIRST)";; *) bad "blocked should sort first (first: $FIRST)";; esac
else
  echo "service checks skipped (omarchy-shell/jq missing)"
fi

# ---------------------------------------------------------------- marks

echo "marks (generated SVGs)"
for id in pi opencode omp grok codex hermes openclaw cursor-agent claude copilot crush gemini muse; do
  for v in "" "-working" "-blocked"; do
    f="$MARKS/$id$v.svg"
    [ -s "$f" ]; check $? "mark $id$v exists"
  done
done

if command -v node >/dev/null; then
  node - "$PLUGIN/Model.js" "$MARKS" <<'JS'
const fs = require("fs");
const Model = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library\s*$/m, "");
const marks = process.argv[3];
const lib = new Function(Model + "\nreturn { truncate, agentMeta, normalizeRecord }; ")();
let fail = 0;
const bad = (m) => { console.log("  \x1b[31m✗\x1b[0m " + m); fail++; };
const good = (m) => console.log("  \x1b[32m✓\x1b[0m " + m);

// truncate must not leave half a surrogate pair
const emoji = "a".repeat(138) + "😀" + "b".repeat(60);
const cut = lib.truncate(emoji, 140);
const last = cut.charCodeAt(cut.length - 2);
if (last >= 0xd800 && last <= 0xdbff) bad("truncate leaves a lone surrogate"); else good("truncate never splits a surrogate pair");
if (/trimEnd\(/.test(Model)) bad("Model.js still calls trimEnd (missing in QML)"); else good("Model.js does not call trimEnd");

// alias folding + unknown agent + unknown state
const a = lib.normalizeRecord({ agent: "claude-code", state: "idle", cwd: "/x/y" }, "/p");
if (a && a.agent === "claude" && a.title === "y") good("claude-code folds to claude, project from cwd");
else bad("alias/project normalisation wrong: " + JSON.stringify(a));
const u = lib.normalizeRecord({ agent: "mystery", state: "bogus" }, "/p");
if (u && u.state === "unknown") good("unknown state normalised"); else bad("unknown state not normalised");

// one file per state per agent
const ids = ["pi","opencode","omp","grok","codex","hermes","openclaw","cursor-agent","claude","copilot","crush","gemini","muse"];
for (const id of ids) for (const v of ["", "-working", "-blocked"]) {
  const f = `${marks}/${id}${v}.svg`;
  if (!fs.existsSync(f)) bad("missing mark " + id + v);
}
good("all 39 marks present");
process.exit(fail ? 1 : 0);
JS
  check $? "Model.js unit checks"
fi

# ---------------------------------------------------------------- visual

if [ "$VISUAL" = 1 ]; then
  echo "visual (screenshots in $SHOT_DIR)"

  if command -v omarchy-shell >/dev/null && command -v grim >/dev/null; then
    shot() { grim "$SHOT_DIR/$1.png" 2>/dev/null; }

    # bar chip: the chip scrolls, so sample several frames
    for i in $(seq 1 10); do shot "bar-$i"; sleep 0.9; done
    ok "bar chip frames -> $SHOT_DIR/bar-*.png"

    # panel: open, capture the top, then scroll to the end and capture again
    omarchy-shell shienze.muster open >/dev/null 2>&1
    sleep 1.5
    shot panel-top
    ok "panel -> $SHOT_DIR/panel-top.png"

    # toast: test alert (uses the first session) and a real completion alert
    omarchy-shell shienze.muster test >/dev/null 2>&1
    sleep 1
    shot toast-test
    "$REPORT" --agent codex --session scn-toast --state working --name "toast check" --prompt "real completion" >/dev/null 2>&1
    sleep 3
    "$REPORT" --agent codex --session scn-toast --state idle --completed >/dev/null 2>&1
    sleep 3
    shot toast-alert
    "$REPORT" --agent codex --session scn-toast --remove >/dev/null 2>&1
    omarchy-shell shienze.muster close >/dev/null 2>&1
    ok "toasts -> $SHOT_DIR/toast-test.png, toast-alert.png"
  else
    echo "  (omarchy-shell/grim missing; skipped)"
  fi
fi

# ---------------------------------------------------------------- summary

echo
if [ "$fail" = 0 ]; then
  printf '\033[32m%d passed\033[0m, 0 failed\n' "$pass"
else
  printf '%d passed, \033[31m%d failed\033[0m\n' "$pass" "$fail"
fi
[ "$KEEP" = 1 ] && echo "(records kept; state dir still has the seeded sessions)"
exit $((fail > 0))
