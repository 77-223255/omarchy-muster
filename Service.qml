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
  // Marks are SVG files with predictable names in a predictable directory, so
  // the write cannot be a plain redirection: a same-user writer that puts a
  // symlink at marks/pi.svg would otherwise have the long-lived shell truncate
  // and rewrite whatever it points at. Each file is staged under a random name
  // created with O_EXCL, written with O_NOFOLLOW, and published with an atomic
  // rename — rename replaces the link itself, it never follows it. The marks
  // hold no session data (they are generated SVGs of omarchy's own glyphs), so
  // they stay world-readable.
  readonly property string markScript: [
    "set -u",
    "dir=\"$1\"; text=\"$2\"; accent=\"$3\"; urgent=\"$4\"; b=\"$5\"",
    "umask 022",
    "[[ $b == /* ]] || { echo \"muster: the state path must be absolute\" >&2; exit 1; }",
    "[ \"$dir\" = \"$b/omarchy/muster/marks\" ] || { echo \"muster: unexpected marks path $dir\" >&2; exit 1; }",
    "# The previous version re-lstat'ed ../$1 after entering, which a lure",
    "# defeats: if the swapped-in directory is itself named like the component,",
    "# then ../$1 inside it names that very directory and matches. What cannot be",
    "# faked is the kernel's own answer to three questions — which entry did we",
    "# look at, which inode did cd land in, and who is the parent of that inode.",
    "# All three must agree with the pinned parent, and a symlink target has a",
    "# different parent, so a redirect is refused no matter what it is named.",
    "step() {",
    "  [ -e \"$1\" ] || { mkdir -- \"$1\" 2>/dev/null || true; }",
    "  [ -e \"$1\" ] || { echo \"muster: cannot create $1\" >&2; return 1; }",
    "  [ ! -L \"$1\" ] || { echo \"muster: $1 is a symlink; refusing\" >&2; return 1; }",
    "  pp=$(stat -c '%d:%i' . 2>/dev/null) || pp=\"\"",
    "  ee=$(stat -c '%d:%i' -- \"$1\" 2>/dev/null) || ee=\"\"",
    "  [ -n \"$pp\" ] && [ -n \"$ee\" ] || { echo \"muster: cannot stat $1\" >&2; return 1; }",
    "  cd -P -- \"$1\" 2>/dev/null || { echo \"muster: cannot enter $1\" >&2; return 1; }",
    "  [ -d . ] && [ -O . ] || { echo \"muster: $1 is not a directory owned by this user\" >&2; return 1; }",
    "  di=$(stat -c '%d:%i' . 2>/dev/null) || di=\"\"",
    "  dp=$(stat -c '%d:%i' .. 2>/dev/null) || dp=\"\"",
    "  [ \"$di\" = \"$ee\" ] || { echo \"muster: $1 changed while it was being used\" >&2; return 1; }",
    "  [ \"$dp\" = \"$pp\" ] || { echo \"muster: $1 led outside its parent; refusing\" >&2; return 1; }",
    "}",
    "cd -P -- \"$b\" 2>/dev/null || { echo \"muster: cannot enter $b\" >&2; exit 1; }",
    "step omarchy || exit 1",
    "step muster || exit 1",
    "step marks || exit 1",
    "# The staging file is created by the same open that writes it, with O_EXCL:",
    "# a name that already exists — including one pre-created as a hardlink —",
    "# makes the open fail rather than be followed or truncated, so there is no",
    "# window between creating the name and writing to it. mktemp followed by a",
    "# separate redirect-by-name had exactly that window, and O_NOFOLLOW does not",
    "# close it because a hardlink is not a symlink. The mode comes from the",
    "# umask, so nothing has to chmod the path afterwards (a chmod by name is the",
    "# same reopen window), and the rename only ever moves a directory entry.",
    "rand=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \\n') || return 1",
    "write() {",
    "  name=\"$1\"; font=\"$2\"; code=\"$3\"; fill=\"$4\"; y=\"$5\"",
    "  local n=0 cand tmp=\"\"",
    "  while [ -z \"$tmp\" ]; do",
    "    n=$((n + 1))",
    "    [ \"$n\" -le 5 ] || return 1",
    "    cand=\".mark.$rand.$n\"",
    "    printf \"%s\" \"<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64' viewBox='0 0 64 64'><text x='32' y='$y' font-family='$font' font-size='56' text-anchor='middle' fill='$fill'>&#x$code;</text></svg>\" | dd of=\"$cand\" conv=excl status=none 2>/dev/null && tmp=\"$cand\"",
    "  done",
    "  mv -T -f -- \"$tmp\" \"$name.svg\"",
    "}",
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
    if (markWriter.running) {
      root._marksPending = true
      return
    }
    markWriter.running = true
  }

  property bool _marksPending: false

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
  readonly property int testAlertMinIntervalMs: 1000  // one test alert per second, at most
  readonly property string soundFile: "/usr/share/sounds/freedesktop/stereo/complete.oga"
  readonly property string soundPlayer: "paplay"

  // ------------------------------------------------------------ discovery

  property var recordPaths: []
  property var _seen: ({})

  function refresh() {
    if (!listProcess.running) listProcess.running = true
  }

  // One inotify line is "<events>\t<name>". A record that changed is reloaded
  // here, so a content change is seen even when mtime and size did not move.
  function onWatchEvent(line) {
    var parts = String(line).split("\t")
    var name = parts.length > 1 ? parts[1] : ""
    if (name.slice(-5) === ".json") {
      var path = String(root.stateDir) + "/" + name
      for (var i = 0; i < recordInstantiator.count; i++) {
        var watcher = recordInstantiator.objectAt(i)
        if (watcher && String(watcher.path) === path) watcher.reloadToken++
      }
    }
    root.refresh()
  }

  Component.onCompleted: {
    // mkdirProcess owns the directory chain, and it is the caller that creates
    // it with umask 077 — the marks are (re)written from its exit handler. Doing
    // it here as well would race it, and the mark script's umask 022 could then
    // create the shared …/omarchy directory group-traversable.
    mkdirProcess.running = true
    refresh()
  }

  // Creates and vets the two directories the plugin owns, one level at a time.
  // Session records hold the last user prompt and the working directory, so the
  // sessions directory must stay owner-only, and every component this plugin
  // creates under the state home must be a real directory owned by this user.
  // mkdir, chmod and every later open follow a symlinked component, so a
  // same-user writer that drops a link at …/omarchy/muster would otherwise move
  // the whole directory — records included — out of the state home. The state
  // home itself is only created when missing and is never checked: a user who
  // symlinks XDG_STATE_HOME into a dotfiles repo did that on purpose. The walk
  // creates one level at a time, so an existing directory deeper down is never
  // reached through a link.
  readonly property string mkdirScript: [
    "set -u",
    "b=\"$1\"",
    "[[ $b == /* ]] || { echo \"muster: the state path must be absolute\" >&2; exit 1; }",
    "umask 077",
    "# The state home itself may not exist yet and may legitimately be a link:",
    "# a user who symlinks XDG_STATE_HOME into a dotfiles repo meant to.",
    "[ -d \"$b\" ] || mkdir -p -- \"$b\" || { echo \"muster: cannot create $b\" >&2; exit 1; }",
    "# A path check followed by a separate use leaves a window in which a",
    "# same-user writer can swap that component for a symlink, and lstat only",
    "# refuses a link at the *last* name, so a link at an earlier component is",
    "# traversed by both the check and the use. Re-lstat'ing ../$1 after entering",
    "# is not enough either: if the swapped-in directory is itself named like the",
    "# component, ../$1 inside it names that very directory and matches. What",
    "# cannot be faked is the kernel's own answer to three questions — which",
    "# entry was looked at, which inode cd landed in, and who is the parent of",
    "# that inode. All three must agree with the pinned parent, and a symlink",
    "# target has a different parent, so a redirect is refused whatever it is",
    "# named. The walk goes one relative component at a time from the directory",
    "# just pinned, and after the last check \".\" is the kernel's directory",
    "# object for the vetted inode, so everything after it is relative to that.",
    "step() {",
    "  [ -e \"$1\" ] || { mkdir -- \"$1\" 2>/dev/null || true; }",
    "  [ -e \"$1\" ] || { echo \"muster: cannot create $1\" >&2; return 1; }",
    "  [ ! -L \"$1\" ] || { echo \"muster: $1 is a symlink; refusing\" >&2; return 1; }",
    "  pp=$(stat -c '%d:%i' . 2>/dev/null) || pp=\"\"",
    "  ee=$(stat -c '%d:%i' -- \"$1\" 2>/dev/null) || ee=\"\"",
    "  [ -n \"$pp\" ] && [ -n \"$ee\" ] || { echo \"muster: cannot stat $1\" >&2; return 1; }",
    "  cd -P -- \"$1\" 2>/dev/null || { echo \"muster: cannot enter $1\" >&2; return 1; }",
    "  [ -d . ] && [ -O . ] || { echo \"muster: $1 is not a directory owned by this user\" >&2; return 1; }",
    "  di=$(stat -c '%d:%i' . 2>/dev/null) || di=\"\"",
    "  dp=$(stat -c '%d:%i' .. 2>/dev/null) || dp=\"\"",
    "  [ \"$di\" = \"$ee\" ] || { echo \"muster: $1 changed while it was being used\" >&2; return 1; }",
    "  [ \"$dp\" = \"$pp\" ] || { echo \"muster: $1 led outside its parent; refusing\" >&2; return 1; }",
    "}",
    "# Only plain files are ever deleted here, never a link or a special file, and",
    "# the directory is pinned before the delete, which is the one thing in this",
    "# script that cannot be undone.",
    "prune() {",
    "  find -- . -maxdepth 1 -type f -name '*.json' -mtime +7 -delete 2>/dev/null || true",
    "  find -- . -maxdepth 1 -type f \\( -name '.muster.*' -o -name '.mark.*' -o -name '*.tmp' \\) -mmin +60 -delete 2>/dev/null || true",
    "}",
    "walk_to() {",
    "  cd -P -- \"$b\" 2>/dev/null || { echo \"muster: cannot enter $b\" >&2; return 1; }",
    "  step omarchy || return 1",
    "  step muster || return 1",
    "  step \"$1\" || return 1",
    "}",
    "walk_to sessions || exit 1",
    "# The records hold prompts and stay owner-only; the marks next to them are",
    "# generated SVGs with no session data and stay readable.",
    "chmod 700 . 2>/dev/null || true",
    "[ \"$(stat -c %a . 2>/dev/null)\" = 700 ] || echo \"muster: the records directory is not owner-only; records may be readable by other users\" >&2",
    "prune",
    "# Re-entered from the state home rather than from .. : .. is the current",
    "# directory's parent pointer, which a rename can change, so it is not the",
    "# inode that was pinned.",
    "walk_to marks || exit 1",
    "chmod 755 . 2>/dev/null || true",
    "prune"
  ].join("\n")

  Process {
    id: mkdirProcess
    running: false
    command: ["bash", "-c", root.mkdirScript, "muster-mkdir",
      Model.stateBase(Quickshell.env("XDG_STATE_HOME") || "", root.home)]
    // The marks live in a directory this script creates, so they are (re)written
    // once it exists — the first write on a fresh install would otherwise race
    // the directory's creation. Only watch the directory once it is ours.
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      inotifyProbe.running = true
      root.writeMarks()
    }
  }

  Process {
    id: markWriter
    running: false
    // A colour change can arrive while a previous run is in flight; the request
    // is remembered rather than dropped, so the toast's icon is not left
    // pointing at a mark that never got written.
    onExited: {
      if (root._marksPending) {
        root._marksPending = false
        root.writeMarks()
      }
    }
    command: ["bash", "-c", root.markScript, "muster-marks", root.marksDir,
      root.hexColor(root.notificationText), root.hexColor(root.notificationAccent),
      root.hexColor(root.notificationUrgent), Model.stateBase(Quickshell.env("XDG_STATE_HOME") || "", root.home)]
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
    // Content changes are watched as well as renames: a writer that rewrites a
    // record in place and restores its mtime would otherwise never be re-read,
    // because the scan only reloads a record whose mtime/size key moved. The
    // event carries the file name, so exactly that record is re-read instead of
    // every record.
    command: ["inotifywait", "-m", "-q", "-e", "create", "-e", "delete",
      "-e", "moved_to", "-e", "moved_from", "-e", "modify", "-e", "close_write",
      "--format", "%e\t%f", "--", root.stateDir]
    stdout: SplitParser { onRead: line => root.onWatchEvent(line) }
    // If the watch dies (directory replaced, inotifywait killed), keep trying.
    onExited: watchRetry.restart()
    // `--` so a state path that begins with a dash (a relative XDG_STATE_HOME)
    // is a watch root, not an option.
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
    // A timeout, because a filesystem that stops answering would otherwise make
    // this child run forever and `running` would stay true, which stops every
    // later scan for the life of the shell.
    // `! -name` with a literal newline drops a file name that would otherwise
    // split into a second path, `head` caps the listing so a writer cannot make
    // the shell watch an unbounded number of records, and the mtime lets the
    // scan reload only records that changed instead of spawning a reader per
    // record on every tick.
    // The reload key is mtime plus size: mtime alone can be preserved by a
    // writer (utimensat), which would keep a changed record from being re-read.
    // Newest first, so the 256-record cap keeps live sessions and drops junk a
    // writer threw in, instead of whatever readdir happened to return first.
    // Newest first, so the 256-record cap keeps the live sessions. Sorting
    // everything (not the first N readdir entries) is what makes that true: a
    // pre-sort `head` selected the newest of an arbitrary subset, so a writer
    // that filled the directory could push a live record out of the sample.
    // The work is bounded by the timeout and the kill, not by a head before the
    // sort, so a flooded directory costs one bounded pass per scan instead of
    // wedging the shell.
    command: ["bash", "-c",
      "timeout -k 2 5 find -- \"$1\" -maxdepth 1 -type f -name '*.json' ! -name $'*\\n*' -printf '%p\\t%T@\\t%s\\n' 2>/dev/null | sort -t$'\\t' -k2,2nr | head -n 256",
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
      // mtime and size are last, so the tab before them is the separator even
      // when the file name itself contains a tab.
      var cut = line.lastIndexOf("\t")
      if (cut <= 0) continue
      var path = line.slice(0, line.lastIndexOf("\t", cut - 1))
      if (path === "") continue
      // Reject a split fragment (a file name containing a newline) and
      // anything that is not a record under the sessions directory.
      if (path.indexOf(prefix) !== 0 || path.slice(-5) !== ".json") continue
      paths.push(path)
      mtimes[path] = line.slice(line.lastIndexOf("\t", cut - 1) + 1)
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
    // JSON, not a separator join: a record can contain any character, and a
    // crafted name containing the separator could otherwise make two different
    // session sets look identical and suppress the UI update.
    var parts = []
    for (var i = 0; i < list.length; i++) {
      var session = list[i]
      parts.push(JSON.stringify([session.path, session.agent, session.state,
        session.completedRuns, session.updatedAt, session.name, session.message,
        session.lastPrompt, session.cwd, session.project]))
    }
    return parts.join("\n")
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
  // positional data, never as shell source. The address *is* placed inside the
  // Lua string below, so its safety rests on the hex-only test right above it,
  // and the pane on the id test — both are enforced again in Model.js.
  function focusCommand(address, pane) {
    var steps = []
    if (/^[A-Za-z0-9:_.-]{1,64}$/.test(String(pane || "")))
      steps.push('herdr agent focus -- "$2" >/dev/null 2>&1 || true')
    if (/^0x[0-9a-fA-F]{1,16}$/.test(String(address || "")))
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
  //
  // The agent id is the one record field that does reach that path, so it is
  // bounded and stripped in one place (Model.safeAgentLabel): a record is
  // written by same-user code and its `agent` field is otherwise free text,
  // which would put an arbitrary string — and an arbitrary path in the `-i`
  // argument — into another service's argv and into its on-disk notification
  // log. An id that is not a plain id falls back to a generic label and no
  // icon.
  function notificationCommand(session, isTest) {
    var who = Model.safeAgentLabel(session)
    // The word "test" is in the title, so a self-triggered alert cannot be
    // mistaken for a real completion at a glance.
    var subject = isTest === true ? "Muster  ·  test"
      : "Muster  ·  " + who.label
    var body = isTest === true ? "Test alert"
      : (session.state === "blocked" ? "Needs your input" : "Run finished")
    var args = ["omarchy-notification-send", "-u", "normal"]
    var mark = String(session.agentIcon || "")
    if (mark !== "" && who.id !== "") {
      var state = session.state === "working" ? "-working"
        : (session.state === "blocked" ? "-blocked" : "")
      args = args.concat(["-i", root.marksDir + "/" + who.id + state + ".svg"])
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
  property real _lastTestAt: 0

  function testAlert(session) {
    // A test alert is reachable from the IPC surface, so it is rate-limited on
    // its own: whatever triggers it cannot turn this into a spawn storm of
    // paplay and notification processes, and it cannot spam the notification
    // log. It is not the completion debounce — a test is asked for on purpose
    // and should fire at once — so it gets its own, shorter interval.
    var now = Date.now()
    if (now - root._lastTestAt < root.testAlertMinIntervalMs) return
    root._lastTestAt = now
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
