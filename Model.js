.pragma library

// Pure helpers for the muster plugin. Nothing here touches QML objects,
// so the file can be shared by the service, the bar widget and the panel.

// A record is a handful of fields. The reader caps every read at this many
// bytes so a large file cannot be pulled into the long-lived shell; anything
// longer is not a record and is dropped unparsed.
var MAX_RECORD_BYTES = 65536

// Every agent omarchy ships as a selectable default (`omarchy default agent`),
// with the ids and aliases that command accepts, and the mark omarchy's own
// menu uses for it: `font: "omarchy"` is a brand glyph in
// /usr/share/fonts/omarchy/omarchy.ttf, otherwise the bar's Nerd Font renders
// it. Nothing here is invented — see `setup.default.agent.*` in
// /usr/share/omarchy/default/omarchy/omarchy-menu.jsonc.
var AGENTS = {
  pi: { label: "Pi", icon: 0xe901, font: "omarchy" },
  opencode: { label: "OpenCode", icon: 0xe902, font: "omarchy" },
  omp: { label: "Oh My Pi", icon: 0xe903, font: "omarchy" },
  grok: { label: "Grok", icon: 0xe904, font: "omarchy" },
  codex: { label: "Codex", icon: 0xe905, font: "omarchy" },
  hermes: { label: "Hermes", icon: 0xe90a, font: "omarchy" },
  openclaw: { label: "OpenClaw", icon: 0xe90c, font: "omarchy" },
  "cursor-agent": { label: "Cursor", icon: 0xe90d, font: "omarchy" },
  claude: { label: "Claude", icon: 0xf06c4, font: "" },
  copilot: { label: "Copilot", icon: 0xf4b8, font: "" },
  crush: { label: "Crush", icon: 0xf02d1, font: "" },
  gemini: { label: "Gemini", icon: 0xf0ae2, font: "" },
  muse: { label: "Muse", icon: 0xf06e4, font: "" }
}

// Spellings an integration might reasonably use for the same agent.
var ALIASES = {
  "oh-my-pi": "omp",
  "open-code": "opencode",
  "claude-code": "claude",
  anthropic: "claude",
  "openai-codex": "codex",
  "gemini-cli": "gemini",
  "github-copilot": "copilot",
  "muse-code": "muse",
  musecode: "muse",
  cursor: "cursor-agent",
  "pi-coding-agent": "pi"
}

// JSON.parse produces only strings, numbers, booleans, null, arrays and plain
// objects — but String() and Number() are not total over those: an object whose
// toString/valueOf are not callable ({"toString":1}) makes them throw, and an
// exception here reached the service's rebuild() and froze every card and
// alert. So a value is converted only when its type is one that has a defined
// conversion, and anything else becomes empty.
function asText(value) {
  if (typeof value === "string") return value
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  return ""
}

// The id of a record is written by same-user code and is otherwise free text:
// it names a file under the sessions directory, it is shown as the card's
// agent label, and it is used to build the notification's icon path. A record
// could therefore carry 64 KiB of text or a `../../..` traversal. Every id
// that is not one of the ids above is reduced here to a short, plain, path-safe
// token, so nothing downstream has to trust it: no separator, no traversal, no
// unbounded length, nothing that needs escaping.
// hasOwnProperty, not `obj[key]`: AGENTS and ALIASES are plain object literals,
// so a record naming its agent "constructor" or "__proto__" would otherwise
// match an inherited Object.prototype member and return a function or an object
// instead of a string — the one thing this function exists to prevent.
function hasOwn(table, key) {
  return Object.prototype.hasOwnProperty.call(table, key)
}

function safeAgentId(raw) {
  var key = asText(raw).toLowerCase()
  if (hasOwn(AGENTS, key)) return key
  if (hasOwn(ALIASES, key)) return ALIASES[key]
  var cleaned = key.replace(/[^a-z0-9]+/g, "-").replace(/^[-.]+/, "").replace(/-+$/, "")
  return cleaned.slice(0, 24)
}

var DEFAULT_AGENT = { label: "agent" }

// The widget's own mark for "no sessions" is the glyph omarchy itself uses for
// a notification, so it renders in every theme.
var IDLE_GLYPH = "󰂚"

var STATES = ["working", "blocked", "idle", "unknown"]

// Returns the canonical id alongside the label and mark, so a record written
// as "claude-code" groups with "claude" instead of becoming a second agent.
// `font` says which family draws the mark: omarchy's own for the brand
// codepoints, the bar's Nerd Font for the rest.
function agentMeta(agent) {
  var key = safeAgentId(agent)
  if (key === "") return { id: "", label: "", icon: "", font: "" }
  if (hasOwn(ALIASES, key)) key = ALIASES[key]
  var def = hasOwn(AGENTS, key) ? AGENTS[key] : undefined
  if (def) {
    return {
      id: key,
      label: def.label,
      icon: String.fromCodePoint(def.icon),
      font: String(def.font || "")
    }
  }
  return { id: key, label: key !== "" ? key : DEFAULT_AGENT.label, icon: "", font: "" }
}

// The agent id is the only record field that reaches omarchy's notification
// path, which takes the summary and the body as process arguments and then
// persists them under ~/.local/state/omarchy/notifications/. So the label that
// goes there is bounded and stripped here, once, and an id that is not a plain
// id yields no icon path at all. Everything else in a record stays in the
// record.
function safeAgentLabel(session) {
  var id = safeAgentId(session ? session.agent : "")
  if (id === "") return { id: "", label: "agent" }
  var label = asText(session.agentLabel) || id
  label = label.replace(/[^A-Za-z0-9 ._-]/g, "").slice(0, 24)
  if (label === "") label = id.slice(0, 24)
  return { id: id, label: label }
}

// ------------------------------------------------------------- records

// Display and identifier text from a record is stripped of control characters
// and bidi overrides: a record is untrusted input, and a newline or a U+202E in
// a project name forges card text, tooltips and the doctor's report. No path or
// prompt needs those bytes.
function printable(value, cap) {
  return asText(value)
    .replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff]/g, "")
    .slice(0, cap)
}

function projectFromCwd(cwd) {
  var value = asText(cwd).replace(/\/+$/, "")
  if (!value || value === "/") return ""
  var parts = value.split("/")
  return parts[parts.length - 1] || value
}

function toNumber(value, fallback) {
  // Only a number or a numeric string is converted; Number({}) is NaN but
  // Number({"valueOf":1}) throws the same way String() does.
  if (typeof value === "number") return isFinite(value) ? value : fallback
  if (typeof value === "string" && value.trim() !== "") {
    var n = Number(value)
    return isFinite(n) ? n : fallback
  }
  return fallback
}

// Turn one raw JSON record into the shape the UI binds against. Returns null
// for records that cannot be trusted (no agent, wrong type). Every string is
// bounded here: a record is untrusted input, and one field of 64 KiB must not
// become a 64 KiB label, a filename or a notification argument. The caps match
// the writers (bin/muster-report, pi/muster.ts) so a well-written record is
// never shortened.
function normalizeRecord(raw, path) {
  if (!raw || typeof raw !== "object") return null
  var meta = agentMeta(raw.agent)
  if (meta.id === "") return null

  var state = (asText(raw.state) || "unknown").toLowerCase()
  if (STATES.indexOf(state) === -1) state = "unknown"

  var cwd = printable(raw.cwd, 1024)
  var declared = printable(raw.project, 256)
  var project = declared !== "" ? declared : projectFromCwd(cwd)
  var name = printable(raw.name, 80).trim()

  return {
    path: asText(path),
    agent: meta.id,
    agentLabel: meta.label,
    agentIcon: meta.icon,
    agentFont: meta.font,
    name: name,
    title: name !== "" ? name : (project !== "" ? project : meta.label),
    cwd: cwd,
    project: project,
    state: state,
    message: printable(raw.message, 240),
    lastPrompt: printable(raw.lastPrompt, 240),
    pid: toNumber(raw.pid, 0),
    // Only a plain window address or pane id can ever reach a command line, so
    // a record cannot smuggle anything into the focus command.
    windowAddress: /^0x[0-9a-fA-F]{1,16}$/.test(asText(raw.windowAddress))
      ? asText(raw.windowAddress) : "",
    herdrPane: /^[A-Za-z0-9:_.-]{1,64}$/.test(asText(raw.herdrPane))
      ? asText(raw.herdrPane) : "",
    updatedAt: toNumber(raw.updatedAt, 0),
    completedRuns: toNumber(raw.completedRuns, 0),
    seq: toNumber(raw.seq, 0)
  }
}

// ------------------------------------------------------------- ordering

function stateRank(state) {
  // blocked is what needs the user, so it outranks working for the top of the
  // list; unknown means an agent reported without a state we recognise.
  if (state === "blocked") return 0
  if (state === "working") return 1
  if (state === "unknown") return 2
  if (state === "idle") return 3
  return 4
}

function sortSessions(list) {
  var copy = list.slice()
  copy.sort(function(a, b) {
    var rank = stateRank(a.state) - stateRank(b.state)
    if (rank !== 0) return rank
    if (b.updatedAt !== a.updatedAt) return b.updatedAt - a.updatedAt
    return String(a.title).localeCompare(String(b.title))
  })
  return copy
}

function isStale(session, now, staleAfterSec) {
  if (!staleAfterSec || staleAfterSec <= 0) return false
  // A record with no timestamp is malformed, not timeless: treating 0 as "not
  // stale" would let a writer pin a card forever, since nothing else ages it
  // out. Drop it like any other stale record.
  if (!session.updatedAt || session.updatedAt <= 0) return true
  // A timestamp in the future (a clock change, a buggy writer) would pin the
  // record forever, because now - updatedAt only ever goes negative.
  if (session.updatedAt > now + staleAfterSec * 1000) return true
  return (now - session.updatedAt) > staleAfterSec * 1000
}

function summarize(sessions) {
  var out = { working: 0, blocked: 0, idle: 0, unknown: 0 }
  for (var i = 0; i < sessions.length; i++) {
    var state = sessions[i].state
    if (out[state] === undefined) out.unknown += 1
    else out[state] += 1
  }
  return out
}

// ------------------------------------------------------------------ card

function folderLabel(session) {
  if (session.project !== "") return session.project
  return session.cwd !== "" ? session.cwd : ""
}

function stateLabel(state) {
  if (state === "working") return "working"
  if (state === "blocked") return "needs you"
  if (state === "idle") return "ready"
  return "unknown"
}

// ------------------------------------------------------------------ text

function truncate(text, limit) {
  var value = asText(text).replace(/\s+/g, " ").trim()
  if (value.length <= limit) return value
  // QML's JS engine has no String.prototype.trimEnd (ES2019), so drop the
  // trailing space with a regex instead. Short text returns above and never
  // reached this line, which is why only long prompts broke the panel card
  // and the notification body.
  var cut = value.slice(0, Math.max(0, limit - 1)).replace(/\s+$/, "")
  // Never keep half of a surrogate pair: a lone surrogate renders as a
  // replacement box in Qt.
  if (cut.length > 0) {
    var last = cut.charCodeAt(cut.length - 1)
    if (last >= 0xd800 && last <= 0xdbff) cut = cut.slice(0, -1)
  }
  return cut + "…"
}

function stateBase(xdgStateHome, home) {
  var base = String(xdgStateHome || "")
  // XDG paths are absolute by definition. A relative one would put the state
  // directory wherever the shell's cwd happens to be, and a value starting
  // with "-" would be read as an option by the tools that take the path, so
  // anything that is not absolute falls back to the home default.
  if (base === "" || base.charAt(0) !== "/") {
    // The home fallback is checked the same way: with no absolute home there is
    // no safe place for a file that holds a prompt, and a relative one would be
    // resolved against the shell's cwd by every reader below. This stays
    // non-writable on purpose — it must fail loudly, never fall back to a
    // shared directory such as /tmp, and never be scanned relative to a cwd.
    var h = String(home || "")
    base = (h.charAt(0) === "/" ? h : "") + "/.local/state"
  }
  // All slashes must stay one slash: stripping them would leave "" (a relative
  // path) or, for "//", an empty base the scripts then refuse.
  return /^\/+$/.test(base) ? "/" : base.replace(/\/+$/, "")
}

function stateDir(xdgStateHome, home) {
  return stateBase(xdgStateHome, home) + "/omarchy/muster/sessions"
}
