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

  // The completion toast is the one surface that renders a mark through
  // omarchy's notification font (the bar font). That font is a Nerd Font, and
  // omarchy's brand glyphs (U+E900..E90D) collide with Nerd Font codepoints —
  // U+E901 is a Nerd Font "cP", not pi — so a brand mark sent as -g renders as
  // the wrong icon. Render those marks as tiny SVGs in the notification text
  // colour instead, and hand the toast an image. Nerd Font marks (claude,
  // gemini, …) still ride the glyph hint and keep the theme's text colour.
  readonly property string marksDir: {
    var d = String(root.stateDir)
    var cut = d.lastIndexOf("/")
    return (cut > 0 ? d.slice(0, cut) : d) + "/marks"
  }
  readonly property color notificationText: Color.notifications.text
  onNotificationTextChanged: root.writeMarks()

  function hexColor(c) {
    function pair(v) {
      var n = Math.round(Math.max(0, Math.min(1, Number(v))) * 255).toString(16)
      return n.length < 2 ? "0" + n : n
    }
    return "#" + pair(c.r) + pair(c.g) + pair(c.b)
  }

  // One line per brand agent: id then the omarchy font codepoint. Kept in
  // sync with Model.js's AGENTS table (every mark with font: "omarchy").
  readonly property string markScript: [
    "dir=\"$1\"",
    "color=\"$2\"",
    "mkdir -p \"$dir\"",
    "mark() { printf \"%s\" \"<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64' viewBox='0 0 64 64'><text x='32' y='62' font-family='omarchy' font-size='60' text-anchor='middle' fill='$color'>&#x$2;</text></svg>\" > \"$dir/$1.svg\"; }",
    "mark pi E901",
    "mark opencode E902",
    "mark omp E903",
    "mark grok E904",
    "mark codex E905",
    "mark hermes E90A",
    "mark openclaw E90C",
    "mark cursor-agent E90D"
  ].join("\n")

  function writeMarks() {
    if (!markWriter.running) markWriter.running = true
  }

  // Normalized, sorted sessions. Reassigned wholesale on every change so QML
  // bindings re-evaluate.
  property var sessions: []
  property int revision: 0

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

  readonly property int refreshIntervalSec: 2    // rescan cadence for new/removed records
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
    command: ["mkdir", "-p", root.stateDir]
  }

  Process {
    id: markWriter
    running: false
    command: ["bash", "-c", root.markScript, "muster-marks", root.marksDir, root.hexColor(root.notificationText)]
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
    command: ["find", root.stateDir, "-maxdepth", "1", "-type", "f", "-name", "*.json", "-printf", "%p\n"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyListing(text)
    }
  }

  function applyListing(output) {
    var paths = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var path = lines[i].trim()
      if (path !== "") paths.push(path)
    }
    paths.sort()
    // Same list, same watchers: reassigning would tear down every FileView
    // just to build identical ones.
    if (JSON.stringify(paths) !== JSON.stringify(recordPaths)) recordPaths = paths
    // A record rewritten by rename() can outrun inotify's file watch, so the
    // scan tick also re-reads every record. JSON files this small make that
    // cheaper than reasoning about which platforms drop the watch.
    root.forceReload()
  }

  function forceReload() {
    for (var i = 0; i < recordInstantiator.count; i++) {
      var watcher = recordInstantiator.objectAt(i)
      if (watcher) watcher.reloadToken++
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
    root.revision++
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

  function notificationCommand(session, isTest) {
    var subject = (isTest === true ? "test  ·  " : "") + session.title
    var args = ["omarchy-notification-send", "-u", "normal"]
    var mark = String(session.agentIcon || "")
    if (mark !== "") {
      if (session.agentFont === "omarchy")
        args = args.concat(["-i", root.marksDir + "/" + session.agent + ".svg"])
      else
        args = args.concat(["-g", mark])
    }
    args = args.concat([
      subject,
      session.lastPrompt !== "" ? Model.truncate(session.lastPrompt, 180)
        : (session.cwd !== "" ? session.cwd : "finished")
    ])
    // Clicking the notification jumps to the terminal that produced it.
    // Hyprland >= 0.56 with a Lua config reads `dispatch` as Lua and rejects
    // the classic `focuswindow address:…`, so try the Lua form first and fall
    // back — the same pair omarchy-launch-or-focus uses. The address goes into
    // Lua source, so only a plain hex address is accepted.
    if (/^0x[0-9a-fA-F]+$/.test(session.windowAddress))
      args = args.concat(["--exec", "bash", "-c",
        'hyprctl dispatch "hl.dsp.focus({ window = \\"address:$1\\" })" || hyprctl dispatch focuswindow "address:$1"',
        "muster-focus", session.windowAddress])
    return args
  }

  // Wired to the panel's "Test" button and shell IPC so the wiring can be
  // checked without waiting for a real run to finish.
  // Fired by a click on a panel card, and by shell IPC, so the alert path can
  // be checked without waiting for a real run to finish. The notification is
  // marked as a test so it cannot be mistaken for a completion.
  function testAlert(session) {
    var subject = session && session.title ? session
      : (root.sessions.length > 0 ? root.sessions[0] : {
        title: "Muster",
        agent: "pi",
        agentIcon: String.fromCodePoint(0xe901),
        agentFont: "omarchy",
        lastPrompt: "Test alert",
        cwd: "",
        windowAddress: ""
      })
    root._lastAlertAt = 0
    if (root.soundEnabled) root.playSound()
    if (root.notifyEnabled) Quickshell.execDetached(root.notificationCommand(subject, true))
  }

}
