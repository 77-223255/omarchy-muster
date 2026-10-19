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
  return Object.assign(Model.normalizeRecord(Object.assign({}, base, over), "/r.json"), over)
}

eq("shouldAlert: no baseline", Model.shouldAlert(sess({}), null), false)
eq("shouldAlert: completedRuns grew",
  Model.shouldAlert(sess({ completedRuns: 2 }), { completedRuns: 1, state: "working" }), true)
eq("shouldAlert: settled transition",
  Model.shouldAlert(sess({ state: "done" }), { completedRuns: 1, state: "working" }), true)
eq("shouldAlert: error transition",
  Model.shouldAlert(sess({ state: "error" }), { completedRuns: 1, state: "blocked" }), true)
eq("shouldAlert: already settled",
  Model.shouldAlert(sess({ state: "done" }), { completedRuns: 1, state: "done" }), false)
eq("shouldAlert: still working",
  Model.shouldAlert(sess({ state: "working" }), { completedRuns: 1, state: "working" }), false)
eq("shouldAlert: settled then idle without a run",
  Model.shouldAlert(sess({ state: "idle" }), { completedRuns: 1, state: "done" }), false)
eq("shouldAlert: settled across an already-settled baseline",
  Model.shouldAlert(sess({ state: "done", completedRuns: 1 }), { completedRuns: 1, state: "error" }), false)

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
