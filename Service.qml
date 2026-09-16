import QtQuick
import Quickshell
import Quickshell.Io
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
// agent-status-report helper, a future hook. This service discovers, watches,
// and reacts to them; it never guesses a state from anything else.
Item {
  id: root
  visible: false

  // Pushed by the bar widget (a service gets no inline shell.json entry).
  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: Model.stateDir(Quickshell.env("XDG_STATE_HOME") || "", root.home)

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
  }

  Process {
    id: mkdirProcess
    running: false
    command: ["mkdir", "-p", root.stateDir]
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
    var subject = (isTest === true ? "test  ·  " : "") + session.title + " · " + session.agentLabel
    var args = ["omarchy-notification-send", "-u", "normal"]
    // A one-character label (pi's "π") doubles as the popup's mark.
    if (session.agentLabel.length === 1) args = args.concat(["-g", session.agentLabel])
    args = args.concat([
      subject,
      session.lastPrompt !== "" ? Model.truncate(session.lastPrompt, 180)
        : (session.cwd !== "" ? session.cwd : "finished")
    ])
    // Clicking the notification jumps to the terminal that produced it.
    if (session.windowAddress !== "")
      args = args.concat(["--exec", "hyprctl", "dispatch", "focuswindow", "address:" + session.windowAddress])
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
        title: "Agent Status",
        agentLabel: "pi",
        lastPrompt: "Test alert",
        cwd: "",
        windowAddress: ""
      })
    root._lastAlertAt = 0
    if (root.soundEnabled) root.playSound()
    if (root.notifyEnabled) Quickshell.execDetached(root.notificationCommand(subject, true))
  }

}
