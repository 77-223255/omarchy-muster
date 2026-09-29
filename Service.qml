import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// The single source of truth for agent sessions.
//
// A headless singleton (kind: "service", keepLoaded) so exactly one instance
// exists no matter how many monitors the shell renders. Bar widgets read
// `sessions` from here and push their settings in; the completion sound and
// notification fire here, once, which is why this is not part of the widget:
// a bar surface exists per monitor.
//
// Records are files. Any agent integration may write one JSON object per
// session into the sessions directory — the bundled pi bridge, the
// muster-report helper, a future hook. This service discovers, watches,
// and reacts to them; it never guesses a state from anything else.
Item {
  id: root
  visible: false

  // Pushed by the bar widget (a service gets no inline shell.json entry).
  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: Model.stateDir(Quickshell.env("XDG_STATE_HOME") || "", root.home)

  // The completion toast is the one surface that cannot set its own font: it
  // draws -g in omarchy's notification font (the bar's Nerd Font). omarchy's
  // brand glyphs (U+E900..E90D) collide with Nerd Font codepoints there —
  // U+E901 is a Nerd Font "cP", not pi — so a mark sent as a glyph renders as
  // the wrong icon. Render every mark as a tiny SVG instead and hand the toast
  // an image, which also lets the fill follow the theme.
  readonly property string marksDir: {
    var d = String(root.stateDir)
    var cut = d.lastIndexOf("/")
    return (cut > 0 ? d.slice(0, cut) : d) + "/marks"
  }
  // The marks are ours, so the fill is ours too: they mirror the bar/panel
  // palette — blocked urgent, working accent, idle the notification text
  // colour. (org.freedesktop.Notifications itself has no colour field.)
  readonly property color notificationText: Color.notifications.text
  readonly property color notificationAccent: Color.accent
  readonly property color notificationUrgent: Color.urgent
  onNotificationTextChanged: root.writeMarks()
  onNotificationAccentChanged: root.writeMarks()
  onNotificationUrgentChanged: root.writeMarks()

  function hexColor(c) {
    function pair(v) {
      var n = Math.round(Math.max(0, Math.min(1, Number(v))) * 255).toString(16)
      return n.length < 2 ? "0" + n : n
    }
    return "#" + pair(c.r) + pair(c.g) + pair(c.b)
  }

  // One line per agent: id, font family, codepoint. Kept in sync with
  // Model.js's AGENTS table. Brand marks use omarchy's own font; Nerd Font
  // marks use the monospace alias, which is the font the toast's glyph hint
  // would resolve to anyway. Each agent gets the three state colours.
  readonly property string markScript: [
    "dir=\"$1\"",
    "text=\"$2\"",
    "accent=\"$3\"",
    "urgent=\"$4\"",
    "mkdir -p \"$dir\"",
    "write() { printf \"%s\" \"<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64' viewBox='0 0 64 64'><text x='32' y='$5' font-family='$2' font-size='56' text-anchor='middle' fill='$4'>&#x$3;</text></svg>\" > \"$dir/$1.svg\"; }",
    "mark() { write \"$1\" \"$2\" \"$3\" \"$text\" \"$4\"; write \"$1-working\" \"$2\" \"$3\" \"$accent\" \"$4\"; write \"$1-blocked\" \"$2\" \"$3\" \"$urgent\" \"$4\"; }",
    "mark pi omarchy E901 60",
    "mark opencode omarchy E902 60",
    "mark omp omarchy E903 60",
    "mark grok omarchy E904 60",
    "mark codex omarchy E905 60",
    "mark hermes omarchy E90A 60",
    "mark openclaw omarchy E90C 60",
    "mark cursor-agent omarchy E90D 60",
    "mark claude monospace F06C4 54",
    "mark copilot monospace F4B8 54",
    "mark crush monospace F02D1 54",
    "mark gemini monospace F0AE2 54",
    "mark muse monospace F06E4 54"
  ].join("\n")

  function writeMarks() {
    if (!markWriter.running) markWriter.running = true
  }

  // Normalized, sorted sessions. Reassigned wholesale on every change so QML
  // bindings re-evaluate.
  property var sessions: []

  // ------------------------------------------------------------- settings

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Only these two are user-facing. Everything else below is deliberately a
  // constant: these are the values that were verified to work, and a widget
  // whose alerts went quiet because of a stray setting is worse than one you
  // tune by editing a line. Change them here if you must.
  readonly property bool soundEnabled: setting("soundEnabled", true) === true
  readonly property bool notifyEnabled: setting("notifyEnabled", true) === true

  readonly property int refreshIntervalSec: 2    // fallback rescan cadence; inotifywait makes new records instant
  readonly property int staleAfterSec: 120       // forget a record whose writer stopped (heartbeat is 30s)
  readonly property int debounceMs: 2000         // collapse several sessions finishing together
  readonly property string soundFile: "/usr/share/sounds/freedesktop/stereo/complete.oga"
  readonly property string soundPlayer: "paplay"

  // ------------------------------------------------------------ discovery

  property var recordPaths: []
  property var _seen: ({})

  function refresh() {
    if (!listProcess.running) listProcess.running = true
  }

  Component.onCompleted: {
    mkdirProcess.running = true
    refresh()
    root.writeMarks()
  }

  Process {
    id: mkdirProcess
    running: false
    // Session records hold the last user prompt and the working directory, so
    // the directory must stay owner-only, and it must be a real directory
    // owned by this user — never a symlink a same-user writer could point at
    // another location. mkdir/chmod follow a symlinked path, so the parent and
    // the sessions directory are both checked before they are touched. umask
    // covers a fresh creation; the chmod repairs one an earlier version left
    // world-readable.
    command: ["bash", "-c",
      "set -u; d=\"$1\"; p=$(dirname -- \"$d\"); " +
      "[ ! -L \"$p\" ] || { echo \"muster: $p is a symlink; refusing\" >&2; exit 1; }; " +
      "umask 077; mkdir -p -- \"$d\" || exit 1; " +
      "[ ! -L \"$d\" ] && [ -d \"$d\" ] && [ -O \"$d\" ] || { echo \"muster: $d is not a directory owned by this user\" >&2; exit 1; }; " +
      "chmod 700 -- \"$d\" 2>/dev/null || true",
      "muster-mkdir", root.stateDir]
    // Only watch the directory once it exists and belongs to us.
    onExited: function(exitCode) { if (exitCode === 0) inotifyProbe.running = true }
  }

  Process {
    id: markWriter
    running: false
    command: ["bash", "-c", root.markScript, "muster-marks", root.marksDir,
      root.hexColor(root.notificationText), root.hexColor(root.notificationAccent),
      root.hexColor(root.notificationUrgent)]
  }

  // The scan tick finds new records, but that can be up to refreshIntervalSec
  // after the agent wrote one. A directory watch closes that gap: opening pi
  // on an existing conversation shows its card at once. inotifywait is
  // optional — without it the scan below is still the fallback.
  Process {
    id: inotifyProbe
    running: false
    command: ["bash", "-c", "command -v inotifywait >/dev/null 2>&1"]
    onExited: function(exitCode) { if (exitCode === 0) watchProcess.running = true }
  }

  Process {
    id: watchProcess
    running: false
    command: ["inotifywait", "-m", "-q", "-e", "create", "-e", "delete",
      "-e", "moved_to", "-e", "moved_from", root.stateDir]
    stdout: SplitParser { onRead: root.refresh() }
    // If the watch dies (directory replaced, inotifywait killed), keep trying.
    onExited: watchRetry.restart()
  }

  Timer {
    id: watchRetry
    interval: 5000
    onTriggered: if (!watchProcess.running) watchProcess.running = true
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: listProcess
    running: false
    // `! -name` with a literal newline drops a file name that would otherwise
    // split into a second path, `head` caps the listing so a writer cannot make
    // the shell watch an unbounded number of records, and the mtime lets the
    // scan reload only records that changed instead of spawning a reader per
    // record on every tick.
    command: ["bash", "-c",
      "find \"$1\" -maxdepth 1 -type f -name '*.json' ! -name $'*\\n*' -printf '%p\\t%T@\\n' 2>/dev/null | head -n 256",
      "muster-list", root.stateDir]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyListing(text)
    }
  }

  // path -> mtime from the last listing, so an unchanged record is not read
  // again on a plain scan tick.
  property var _mtimes: ({})

  function applyListing(output) {
    var prefix = String(root.stateDir) + "/"
    var paths = []
    var mtimes = {}
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line === "") continue
      // The mtime is last, so the tab before it is the separator even when the
      // file name itself contains a tab.
      var cut = line.lastIndexOf("\t")
      if (cut <= 0) continue
      var path = line.slice(0, cut)
      // Reject a split fragment (a file name containing a newline) and
      // anything that is not a record under the sessions directory.
      if (path.indexOf(prefix) !== 0 || path.slice(-5) !== ".json") continue
      paths.push(path)
      mtimes[path] = line.slice(cut + 1)
    }
    paths.sort()

    var previous = root._mtimes
    var pathsChanged = JSON.stringify(paths) !== JSON.stringify(root.recordPaths)
    root._mtimes = mtimes
    if (pathsChanged) recordPaths = paths
    // A new path is read when its Record mounts, so only an existing record
    // whose mtime moved needs an explicit reload.
    for (var j = 0; j < recordInstantiator.count; j++) {
      var watcher = recordInstantiator.objectAt(j)
      if (!watcher) continue
      var current = String(watcher.path || "")
      if (current !== "" && previous[current] !== mtimes[current]) watcher.reloadToken++
    }
  }

  Instantiator {
    id: recordInstantiator
    model: root.recordPaths

    delegate: Record {
      required property var modelData
      path: modelData
      onRecordChanged: root.rebuild()
    }

    onObjectAdded: root.rebuild()
    onObjectRemoved: root.rebuild()
  }

  // ------------------------------------------------------------- sessions

  function rebuild() {
    var now = Date.now()
    // One live session per agent process: a stale record left behind by a
    // crash, or a hand-copied file, must not show up as a second session.
    var byKey = ({})
    var order = []
    for (var i = 0; i < recordInstantiator.count; i++) {
      var watcher = recordInstantiator.objectAt(i)
      if (!watcher) continue
      var session = Model.normalizeRecord(watcher.record, watcher.path)
      if (!session) continue
      if (Model.isStale(session, now, root.staleAfterSec)) continue
      var key = session.pid > 0 ? ("pid:" + session.pid) : ("path:" + session.path)
      var existing = byKey[key]
      if (!existing) {
        byKey[key] = session
        order.push(key)
        continue
      }
      if (session.updatedAt > existing.updatedAt
          || (session.updatedAt === existing.updatedAt && session.seq > existing.seq))
        byKey[key] = session
    }

    var collected = []
    for (var k = 0; k < order.length; k++) collected.push(byKey[order[k]])
    collected = Model.sortSessions(collected)
    root.detectCompletions(collected, now)

    var signature = root.signature(collected)
    if (signature === root._signature) return
    root._signature = signature
    root.sessions = collected
  }

  property string _signature: ""

  function signature(list) {
    var parts = []
    for (var i = 0; i < list.length; i++) {
      var session = list[i]
      parts.push([session.path, session.agent, session.state, session.completedRuns,
        session.updatedAt, session.name, session.message, session.lastPrompt,
        session.cwd].join("\u0001"))
    }
    return parts.join("\u0002")
  }

  // ------------------------------------------------------------- alerts

  property real _lastAlertAt: 0

  // A record counts as "finished a run" when its completedRuns counter grows.
  // Comparing counters instead of states survives a scan interval that missed
  // a fast working→idle flip.
  function detectCompletions(list, now) {
    var previous = root._seen
    var next = {}
    for (var i = 0; i < list.length; i++) {
      var session = list[i]
      var before = previous[session.path]
      next[session.path] = { completedRuns: session.completedRuns, state: session.state }
      if (!before) continue
      if (session.completedRuns > (before.completedRuns || 0)) root.fireAlert(session, now)
    }
    root._seen = next
  }

  function fireAlert(session, now) {
    if (now - root._lastAlertAt < root.debounceMs) return
    root._lastAlertAt = now
    if (root.soundEnabled) root.playSound()
    if (root.notifyEnabled) Quickshell.execDetached(root.notificationCommand(session))
  }

  function playSound() {
    if (root.soundPlayer.indexOf("mpv") !== -1)
      Quickshell.execDetached([root.soundPlayer, "--no-video", root.soundFile])
    else
      Quickshell.execDetached([root.soundPlayer, root.soundFile])
  }

  // The argv that focuses the session. A session is addressable two ways: a
  // Hyprland window (any plain terminal) and, inside herdr, a pane. herdr runs
  // its panes under a daemon, so the pane process has no terminal window in its
  // ancestry — the window shown is the herdr client's, and the pane is moved to
  // with `herdr agent focus`. Run the pane switch first, then bring the window
  // forward. Hyprland >= 0.56 with a Lua config reads `dispatch` as Lua and
  // rejects the classic `focuswindow address:…`, so try the Lua form first and
  // fall back — the same pair omarchy-launch-or-focus uses. Both values go in as
  // positional data, never as Lua/shell source, so only a plain hex address and
  // a plain pane id are accepted.
  function focusCommand(address, pane) {
    var steps = []
    if (/^[A-Za-z0-9:_.-]+$/.test(String(pane || "")))
      steps.push('herdr agent focus -- "$2" >/dev/null 2>&1 || true')
    if (/^0x[0-9a-fA-F]+$/.test(String(address || "")))
      steps.push('hyprctl dispatch "hl.dsp.focus({ window = \\"address:$1\\" })" || hyprctl dispatch focuswindow "address:$1"')
    if (steps.length === 0) return null
    return ["bash", "-c", steps.join("\n"), "muster-focus",
      String(address || ""), String(pane || "")]
  }

  // Left-clicking a panel card jumps to the session's terminal; a notification
  // click runs the same command.
  function focusSession(session) {
    var argv = root.focusCommand(session && session.windowAddress, session && session.herdrPane)
    if (argv) Quickshell.execDetached(argv)
  }

  // The completion toast. It deliberately carries no session content: omarchy's
  // notification service takes the summary and body as process arguments
  // (omarchy-notification-send -> busctl) and then persists them under
  // ~/.local/state/omarchy/notifications/, so a prompt placed here would be
  // readable by other local users from /proc/<pid>/cmdline and kept on disk.
  // The summary and body below are built only from non-content fields: the
  // agent's label from Model.AGENTS and a fixed state word.
  function notificationCommand(session, isTest) {
    var subject = isTest === true ? "Muster"
      : "Muster  ·  " + String(session.agentLabel || session.agent || "agent")
    var body = isTest === true ? "Test alert"
      : (session.state === "blocked" ? "Needs your input" : "Run finished")
    var args = ["omarchy-notification-send", "-u", "normal"]
    var mark = String(session.agentIcon || "")
    if (mark !== "") {
      var state = session.state === "working" ? "-working"
        : (session.state === "blocked" ? "-blocked" : "")
      args = args.concat(["-i", root.marksDir + "/" + session.agent + state + ".svg"])
    }
    args = args.concat([subject, body])
    // Clicking the notification jumps to the terminal that produced it.
    var focus = root.focusCommand(session.windowAddress, session.herdrPane)
    if (focus) args = args.concat(["--exec"]).concat(focus)
    return args
  }

  // -----------------------------------------------------------------------
  // OPT-IN CONTENT TOAST — UNSAFE, DISABLED ON PURPOSE
  //
  // This is the version that puts the session's title and last user prompt in
  // the toast. It is kept, verbatim, so it can be switched on the day upstream
  // gives the notification path a private channel — see
  // basecamp/omarchy#8209 (the fix, basecamp/omarchy#8259, is still unmerged).
  //
  // It is not enabled because the text travels through the argv of both
  // omarchy-notification-send and busctl, and omarchy's notification service
  // then writes it to ~/.local/state/omarchy/notifications/ (mode 0644).
  // Another local user can read it from /proc/<pid>/cmdline and, when the home
  // directory is traversable, from that file. The marketplace build therefore
  // ships the safe notificationCommand above.
  //
  // To opt in: delete the safe notificationCommand above, uncomment the block
  // below and `omarchy restart shell`. You accept the exposure.
  //
  // function notificationCommand(session, isTest) {
  //   var subject = (isTest === true ? "test  ·  " : "alert  ·  ") + session.title
  //   var args = ["omarchy-notification-send", "-u", "normal"]
  //   var mark = String(session.agentIcon || "")
  //   if (mark !== "") {
  //     var state = session.state === "working" ? "-working"
  //       : (session.state === "blocked" ? "-blocked" : "")
  //     args = args.concat(["-i", root.marksDir + "/" + session.agent + state + ".svg"])
  //   }
  //   args = args.concat([
  //     subject,
  //     session.lastPrompt !== "" ? Model.truncate(session.lastPrompt, 180)
  //       : (session.cwd !== "" ? session.cwd : "finished")
  //   ])
  //   var focus = root.focusCommand(session.windowAddress, session.herdrPane)
  //   if (focus) args = args.concat(["--exec"]).concat(focus)
  //   return args
  // }

  // Right-clicking a panel card, the chip's middle click, and the `test` IPC
  // all land here, so the alert path can be checked without waiting for a real
  // run to finish. The notification is marked as a test so it cannot be
  // mistaken for a completion.
  function testAlert(session) {
    var subject = session && session.title ? session
      : (root.sessions.length > 0 ? root.sessions[0] : {
        title: "Muster",
        agent: "pi",
        agentIcon: String.fromCodePoint(0xe901),
        lastPrompt: "Test alert",
        cwd: "",
        windowAddress: ""
      })
    root._lastAlertAt = 0
    if (root.soundEnabled) root.playSound()
    if (root.notifyEnabled) Quickshell.execDetached(root.notificationCommand(subject, true))
  }

}
