.pragma library

// Pure helpers for the muster plugin. Nothing here touches QML objects,
// so the file can be shared by the service, the bar widget and the panel.

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

var DEFAULT_AGENT = { label: "agent" }

// The widget's own mark for "no sessions" is the glyph omarchy itself uses for
// a notification, so it renders in every theme.
var IDLE_GLYPH = "󰂚"

var STATES = ["working", "blocked", "idle", "unknown"]

// Returns the canonical id alongside the label, so a record written as
// "claude-code" groups with "claude" instead of becoming a second agent. The
// label is the whole identity: pi's is the symbol "π", everyone else's is their
// name, and there are no invented logos.
function agentMeta(agent) {
  var key = String(agent || "").toLowerCase()
  if (ALIASES[key]) key = ALIASES[key]
  var def = AGENTS[key]
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

// ------------------------------------------------------------- records

function projectFromCwd(cwd) {
  var value = String(cwd || "").replace(/\/+$/, "")
  if (!value || value === "/") return ""
  var parts = value.split("/")
  return parts[parts.length - 1] || value
}

function toNumber(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

// Turn one raw JSON record into the shape the UI binds against. Returns null
// for records that cannot be trusted (no agent, wrong type).
function normalizeRecord(raw, path) {
  if (!raw || typeof raw !== "object") return null
  var meta = agentMeta(raw.agent)
  if (meta.id === "") return null

  var state = String(raw.state || "unknown").toLowerCase()
  if (STATES.indexOf(state) === -1) state = "unknown"

  var cwd = typeof raw.cwd === "string" ? raw.cwd : ""
  var project = typeof raw.project === "string" && raw.project !== ""
    ? raw.project : projectFromCwd(cwd)
  var name = typeof raw.name === "string" ? raw.name.trim() : ""

  return {
    path: String(path || ""),
    agent: meta.id,
    agentLabel: meta.label,
    agentIcon: meta.icon,
    agentFont: meta.font,
    sessionId: String(raw.sessionId || ""),
    name: name,
    title: name !== "" ? name : (project !== "" ? project : meta.label),
    cwd: cwd,
    project: project,
    state: state,
    message: typeof raw.message === "string" ? raw.message : "",
    lastPrompt: typeof raw.lastPrompt === "string" ? raw.lastPrompt : "",
    pid: toNumber(raw.pid, 0),
    windowAddress: typeof raw.windowAddress === "string" ? raw.windowAddress : "",
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
  if (!session.updatedAt) return false
  return (now - session.updatedAt) > staleAfterSec * 1000
}

function summarize(sessions) {
  var out = { total: sessions.length, working: 0, blocked: 0, idle: 0, unknown: 0 }
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
  var value = String(text || "").replace(/\s+/g, " ").trim()
  if (value.length <= limit) return value
  // QML's JS engine has no String.prototype.trimEnd (ES2019), so drop the
  // trailing space with a regex instead. Short text returns above and never
  // reached this line, which is why only long prompts broke the panel card
  // and the notification body.
  return value.slice(0, Math.max(0, limit - 1)).replace(/\s+$/, "") + "…"
}

function stateDir(xdgStateHome, home) {
  var base = String(xdgStateHome || "")
  if (base === "") base = String(home || "") + "/.local/state"
  return base + "/omarchy/muster/sessions"
}
