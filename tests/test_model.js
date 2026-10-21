// Unit tests for Model.js — run with `node tests/test_model.js`.
//
// Model.js is a QML `.pragma library` script, so it is loaded through Node's
// vm module: the `.pragma` line is stripped (it is not JavaScript) and the
// rest is evaluated in a fresh realm whose globals are exactly what QML's JS
// engine would provide — the standard built-ins and nothing else.

"use strict"

const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs
  .readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .split("\n")
  .filter((line) => !/^\s*\.pragma\b/.test(line))
  .join("\n")

const context = vm.createContext({})
vm.runInContext(source, context, { filename: "Model.js" })
const Model = vm.runInContext(
  "({ normalizeRecord, isSettled, shouldAlert, summarize, sortSessions, stateDir })",
  context
)

let passed = 0
let failed = 0

function check(name, cond, extra) {
  if (cond) {
    passed += 1
  } else {
    failed += 1
    console.error("FAIL:", name, extra === undefined ? "" : JSON.stringify(extra))
  }
}

function eq(name, actual, expected) {
  check(name, JSON.stringify(actual) === JSON.stringify(expected),
    { actual, expected })
}

const base = { agent: "pi", state: "working" }

// ---------------------------------------------------------- normalizeRecord

eq("normalizeRecord: path is carried through",
  Model.normalizeRecord({ ...base }, "/state/muster/pi~s.json").path,
  "/state/muster/pi~s.json")
eq("normalizeRecord: not an object", Model.normalizeRecord(null, "/r.json"), null)
eq("normalizeRecord: no agent", Model.normalizeRecord({ state: "working" }, "/r.json"), null)
eq("normalizeRecord: protocol app spelling accepted",
  Model.normalizeRecord({ app: "claude-code", state: "working" }, "/r.json").agent, "claude")
eq("normalizeRecord: agent alias resolved",
  Model.normalizeRecord({ ...base, agent: "oh-my-pi" }, "/r.json").agent, "omp")
eq("normalizeRecord: kimi-code alias resolved",
  Model.normalizeRecord({ ...base, agent: "kimi-code" }, "/r.json").agent, "kimi")
eq("normalizeRecord: kimi mark",
  Model.normalizeRecord({ ...base, agent: "kimi" }, "/r.json").agentIcon,
  String.fromCodePoint(0xf06a9))
eq("normalizeRecord: openrouter alias resolved",
  Model.normalizeRecord({ ...base, agent: "openrouter" }, "/r.json").agent, "ori")
eq("normalizeRecord: ori brand mark",
  Model.normalizeRecord({ ...base, agent: "ori" }, "/r.json").agentIcon,
  String.fromCodePoint(0xe909))
eq("normalizeRecord: ori uses the omarchy font",
  Model.normalizeRecord({ ...base, agent: "ori" }, "/r.json").agentFont, "omarchy")
eq("normalizeRecord: antigravity alias resolved",
  Model.normalizeRecord({ ...base, agent: "antigravity" }, "/r.json").agent, "agy")
eq("normalizeRecord: antigravity mark",
  Model.normalizeRecord({ ...base, agent: "agy" }, "/r.json").agentIcon,
  String.fromCodePoint(0xf0ae2))
eq("normalizeRecord: cursor-cli alias resolved",
  Model.normalizeRecord({ ...base, agent: "cursor-cli" }, "/r.json").agent, "cursor-agent")
eq("normalizeRecord: unknown agent kept as a plain id",
  Model.normalizeRecord({ ...base, agent: "My Agent" }, "/r.json").agent, "my-agent")
eq("normalizeRecord: prototype names are not agents",
  Model.normalizeRecord({ ...base, agent: "constructor" }, "/r.json").agent, "constructor")
eq("normalizeRecord: state kept",
  Model.normalizeRecord({ ...base, state: "blocked" }, "/r.json").state, "blocked")
eq("normalizeRecord: unknown state normalised",
  Model.normalizeRecord({ ...base, state: "sideways" }, "/r.json").state, "unknown")
eq("normalizeRecord: missing state normalised",
  Model.normalizeRecord({ agent: "pi" }, "/r.json").state, "unknown")
eq("normalizeRecord: name wins over title",
  Model.normalizeRecord({ ...base, name: "Build", title: "Other" }, "/r.json").name, "Build")
eq("normalizeRecord: title is the protocol spelling of name",
  Model.normalizeRecord({ ...base, title: "Other" }, "/r.json").name, "Other")
eq("normalizeRecord: message wins over msg",
  Model.normalizeRecord({ ...base, message: "one", msg: "two" }, "/r.json").message, "one")
eq("normalizeRecord: msg is the protocol spelling of message",
  Model.normalizeRecord({ ...base, msg: "two" }, "/r.json").message, "two")
eq("normalizeRecord: project from cwd",
  Model.normalizeRecord({ ...base, cwd: "/home/u/muster" }, "/r.json").project, "muster")
eq("normalizeRecord: declared project wins over cwd",
  Model.normalizeRecord({ ...base, cwd: "/home/u/muster", project: "Muster" }, "/r.json").project,
  "Muster")

// ------------------------------------------------------------- terminalId

eq("terminalId: absent -> empty",
  Model.normalizeRecord({ ...base }).terminalId, "")
eq("terminalId: tap:1234 accepted",
  Model.normalizeRecord({ ...base, terminalId: "tap:1234" }).terminalId, "tap:1234")
eq("terminalId: charset dots/underscores/dashes accepted",
  Model.normalizeRecord({ ...base, terminalId: "tap-1.pid_2:A" }).terminalId, "tap-1.pid_2:A")
eq("terminalId: 64 chars accepted",
  Model.normalizeRecord({ ...base, terminalId: "a".repeat(64) }).terminalId, "a".repeat(64))
for (const bad of [
  "a".repeat(65),          // over the 64-char cap
  "-tap",                  // must start alphanumeric
  ".tap",
  ":tap",
  "tap id",                // whitespace
  "tap/x",                 // separator outside the charset
  "tap!",                  // punctuation outside the charset
  "tap\u0000",             // control character
  "tap\ninjected",         // newline forgery
  " "                      // blank
]) {
  eq("terminalId: rejected " + JSON.stringify(bad),
    Model.normalizeRecord({ ...base, terminalId: bad }).terminalId, "")
}
check("terminalId: non-string is empty",
  Model.normalizeRecord({ ...base, terminalId: { toString: 1 } }).terminalId === "")

// ------------------------------------------------------------- recordId cap

eq("recordId: 263 chars survive",
  Model.normalizeRecord({ ...base, recordId: "a".repeat(263) }).recordId, "a".repeat(263))
eq("recordId: capped at 263",
  Model.normalizeRecord({ ...base, recordId: "a".repeat(400) }).recordId.length, 263)
eq("recordId: protocol id spelling accepted",
  Model.normalizeRecord({ ...base, id: "build/test" }).recordId, "build/test")
eq("recordId: whitespace stripped",
  Model.normalizeRecord({ ...base, recordId: "  build  " }).recordId, "build")
eq("recordId: control characters stripped",
  Model.normalizeRecord({ ...base, recordId: "bu\u0007ild\u202e" }).recordId, "build")

// --------------------------------------------------------- title fallback

eq("title: empty name falls back to recordId",
  Model.normalizeRecord({ ...base, recordId: "build/test" }).title, "build/test")
eq("title: name still wins over recordId",
  Model.normalizeRecord({ ...base, name: "Fix flake", recordId: "build/test" }).title, "Fix flake")
eq("title: no name, no recordId -> project",
  Model.normalizeRecord({ ...base, cwd: "/home/u/muster" }).title, "muster")
eq("title: nothing but the agent -> label",
  Model.normalizeRecord({ ...base }).title, "Pi")
eq("title: recordId wins over project",
  Model.normalizeRecord({ ...base, recordId: "build", cwd: "/home/u/muster" }).title, "build")
check("title: recordId fallback keeps name empty",
  Model.normalizeRecord({ ...base, recordId: "build" }).name === "")

// ------------------------------------------------- progress / kind gating

eq("progress: kept while working",
  Model.normalizeRecord({ ...base, progress: 42 }).progress, 42)
eq("progress: kept while blocked",
  Model.normalizeRecord({ ...base, state: "blocked", progress: 7 }).progress, 7)
eq("progress: dropped once done",
  Model.normalizeRecord({ ...base, state: "done", progress: 42 }).progress, -1)
eq("progress: dropped on error",
  Model.normalizeRecord({ ...base, state: "error", progress: 42 }).progress, -1)
eq("progress: dropped when idle",
  Model.normalizeRecord({ ...base, state: "idle", progress: 42 }).progress, -1)
eq("progress: dropped when unknown state",
  Model.normalizeRecord({ ...base, state: "sideways", progress: 42 }).progress, -1)
eq("progress: out of range dropped",
  Model.normalizeRecord({ ...base, progress: 150 }).progress, -1)
eq("progress: rounded",
  Model.normalizeRecord({ ...base, progress: 42.4 }).progress, 42)
eq("progress: non-numeric dropped",
  Model.normalizeRecord({ ...base, progress: "lots" }).progress, -1)

eq("kind: kept while blocked",
  Model.normalizeRecord({ ...base, state: "blocked", kind: "permission" }).kind, "permission")
eq("kind: dropped while working",
  Model.normalizeRecord({ ...base, kind: "question" }).kind, "")
eq("kind: dropped once done",
  Model.normalizeRecord({ ...base, state: "done", kind: "auth" }).kind, "")
eq("kind: unrecognised value dropped",
  Model.normalizeRecord({ ...base, state: "blocked", kind: "banana" }).kind, "")
eq("kind: normalised case",
  Model.normalizeRecord({ ...base, state: "blocked", kind: "AUTH" }).kind, "auth")

// --------------------------------------------------------------- isSettled

eq("isSettled: done", Model.isSettled("done"), true)
eq("isSettled: error", Model.isSettled("error"), true)
eq("isSettled: working", Model.isSettled("working"), false)
eq("isSettled: blocked", Model.isSettled("blocked"), false)
eq("isSettled: idle", Model.isSettled("idle"), false)
eq("isSettled: unknown", Model.isSettled("unknown"), false)

// -------------------------------------------------------------- shouldAlert

function sess(over) {
  return Model.normalizeRecord(Object.assign({}, base, over), "/r.json")
}

eq("shouldAlert: no baseline", Model.shouldAlert(sess({}), null), false)
eq("shouldAlert: no baseline on a settled record",
  Model.shouldAlert(sess({ state: "done" }), undefined), false)
eq("shouldAlert: working -> done",
  Model.shouldAlert(sess({ state: "done" }), { state: "working" }), true)
eq("shouldAlert: blocked -> error",
  Model.shouldAlert(sess({ state: "error" }), { state: "blocked" }), true)
eq("shouldAlert: idle -> done",
  Model.shouldAlert(sess({ state: "done" }), { state: "idle" }), true)
eq("shouldAlert: already done",
  Model.shouldAlert(sess({ state: "done" }), { state: "done" }), false)
eq("shouldAlert: already error",
  Model.shouldAlert(sess({ state: "error" }), { state: "error" }), false)
eq("shouldAlert: still working",
  Model.shouldAlert(sess({ state: "working" }), { state: "working" }), false)
eq("shouldAlert: done -> idle (acknowledged)",
  Model.shouldAlert(sess({ state: "idle" }), { state: "done" }), false)
eq("shouldAlert: error -> done is not a new edge",
  Model.shouldAlert(sess({ state: "done" }), { state: "error" }), false)
eq("shouldAlert: unknown is not settled",
  Model.shouldAlert(sess({ state: "unknown" }), { state: "working" }), false)

// ------------------------------------------------- removed legacy fields

for (const gone of ["lastPrompt", "completedRuns", "seq"]) {
  check("normalizeRecord: " + gone + " is not carried",
    !(gone in Model.normalizeRecord(Object.assign({}, base, { [gone]: 1 }), "/r.json")))
}

// ---------------------------------------------------------- focus fields

eq("windowAddress: plain address kept",
  Model.normalizeRecord({ ...base, windowAddress: "0x601dc3f347b0" }).windowAddress, "0x601dc3f347b0")
eq("windowAddress: anything else dropped",
  Model.normalizeRecord({ ...base, windowAddress: "0x1; rm -rf /" }).windowAddress, "")
eq("herdrPane: plain id kept",
  Model.normalizeRecord({ ...base, herdrPane: "pane-3" }).herdrPane, "pane-3")
eq("herdrPane: shell source dropped",
  Model.normalizeRecord({ ...base, herdrPane: "a; rm -rf /" }).herdrPane, "")
eq("herdrPane: leading dash dropped",
  Model.normalizeRecord({ ...base, herdrPane: "-rf" }).herdrPane, "")
eq("tmuxPane: %N kept",
  Model.normalizeRecord({ ...base, tmuxPane: "%3" }).tmuxPane, "%3")
eq("tmuxPane: not a pane id dropped",
  Model.normalizeRecord({ ...base, tmuxPane: "3" }).tmuxPane, "")
eq("tmuxSocket: absolute path kept",
  Model.normalizeRecord({ ...base, tmuxSocket: "/tmp/tmux-1000/default" }).tmuxSocket,
  "/tmp/tmux-1000/default")
eq("tmuxSocket: relative path dropped",
  Model.normalizeRecord({ ...base, tmuxSocket: "tmp/sock" }).tmuxSocket, "")
eq("tmuxSocket: traversal dropped",
  Model.normalizeRecord({ ...base, tmuxSocket: "/tmp/../etc/sock" }).tmuxSocket, "")
eq("tmuxSocket: dot segment dropped",
  Model.normalizeRecord({ ...base, tmuxSocket: "/tmp/./sock" }).tmuxSocket, "")
eq("tmuxSocket: empty segment dropped",
  Model.normalizeRecord({ ...base, tmuxSocket: "/tmp//sock" }).tmuxSocket, "")

// --------------------------------------------------------------- summarize

eq("summarize: mixed list", Model.summarize([
  { state: "working" }, { state: "blocked" }, { state: "done" },
  { state: "done" }, { state: "idle" }, { state: "error" }, { state: "bogus" }
]), { working: 1, blocked: 1, done: 2, error: 1, idle: 1, unknown: 1 })
eq("summarize: empty list", Model.summarize([]),
  { working: 0, blocked: 0, done: 0, error: 0, idle: 0, unknown: 0 })

// ------------------------------------------------------------------ report

console.log(`model tests: ${passed} passed, ${failed} failed`)
if (failed > 0) process.exit(1)
