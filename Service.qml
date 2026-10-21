import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// The single source of truth for agent sessions.
//
// A headless singleton (kind: "service", keepLoaded) so exactly one instance
// exists no matter how many monitors the shell renders. Bar widgets read
// `sessions` from here and push their settings in; the completion sound and
// notification fire here, once, which is why this is not part of the widget:
// a bar surface exists per monitor.
//
// Records are files. bin/muster-tap writes one JSON object per session into
// the sessions directory. This service discovers, watches, and reacts to
// them; it never guesses a state from anything else.
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
  readonly property color notificationText: Commons.Color.notifications.text
  readonly property color notificationAccent: Commons.Color.accent
  readonly property color notificationUrgent: Commons.Color.urgent
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
    "rand=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \\n') || exit 1",
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
    "mark() { write \"$1\" \"$2\" \"$3\" \"$text\" \"$4\"; write \"$1-working\" \"$2\" \"$3\" \"$accent\" \"$4\"; write \"$1-blocked\" \"$2\" \"$3\" \"$urgent\" \"$4\"; write \"$1-done\" \"$2\" \"$3\" \"$accent\" \"$4\"; write \"$1-error\" \"$2\" \"$3\" \"$urgent\" \"$4\"; }",
    "mark pi omarchy E901 60",
    "mark opencode omarchy E902 60",
    "mark omp omarchy E903 60",
    "mark grok omarchy E904 60",
    "mark codex omarchy E905 60",
    "mark hermes omarchy E90A 60",
    "mark openclaw omarchy E90C 60",
    "mark cursor-agent omarchy E90D 60",
    "mark ori omarchy E909 60",
    "mark agy monospace F0AE2 54",
    "mark claude monospace F06C4 54",
    "mark copilot monospace F4B8 54",
    "mark crush monospace F02D1 54",
    "mark gemini monospace F0AE2 54",
    "mark kimi monospace F06A9 54",
    "mark muse monospace F06E4 54"
  ].join("\n")

  function writeMarks() {
    // The colour bindings evaluate before Component.onCompleted starts the
    // setup walk, and the mark script's mkdir runs under umask 022: writing
    // marks first could create the shared …/omarchy directory
    // group-traversable. Wait until the walk has succeeded.
    if (!root._setupDone) return
    if (markWriter.running) {
      root._marksPending = true
      return
    }
    markWriter.running = true
  }

  property bool _setupDone: false
  property int _setupAttempts: 0
  property bool _watchPending: false
  property string _watchDirId: ""
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
  readonly property int staleAfterSec: 120       // forget a live record whose writer stopped (heartbeat is 30s)
  readonly property int settledAfterSec: 21600   // keep a finished (done/error) record for six hours
  readonly property int debounceMs: 2000         // collapse several sessions finishing together
  readonly property int testAlertMinIntervalMs: 1000  // one test alert per second, at most
  readonly property string soundFile: "/usr/share/sounds/freedesktop/stereo/complete.oga"
  readonly property string soundPlayer: "paplay"

  // ------------------------------------------------------------ discovery

  property var recordPaths: []
  // The last state seen for each record path, so a run finishing is visible as
  // the edge into done/error. The protocol carries no completion counter.
  property var _seen: ({})
  property var _pathSeen: ({})
  // Records that appear settled after this service started are a run that
  // finished while we were watching but a scan missed the working edge. This
  // replaces the old completedRuns counter without adding a field to the
  // protocol record.
  readonly property real _startedAt: Date.now()
  // Paths whose settled (done/error) state the user has already looked at by
  // focusing the session. The protocol leaves "stop showing a finished record"
  // to the consumer; this is that acknowledgement, held in memory only.
  property var _acknowledged: ({})

  function refresh() {
    // Nothing is safe to list until the setup walk has created and vetted the
    // sessions directory (and the marks writer must not run before it either).
    if (!root._setupDone) return
    if (!listProcess.running) listProcess.running = true
  }

  // One inotify line is "<events>\t<name>". A record that changed is reloaded
  // here, so a content change is seen even when mtime and size did not move.
  function onWatchEvent(line) {
    // Slice past the event tab rather than split("\t")[1]: a record name may
    // itself contain a tab, and split would keep only the first fragment and
    // miss the record that actually changed.
    var raw = String(line)
    var cut = raw.indexOf("\t")
    var event = cut >= 0 ? raw.slice(0, cut) : ""
    var name = cut >= 0 ? raw.slice(cut + 1) : ""
    if (name.slice(-5) === ".json") {
      var path = String(root.stateDir) + "/" + name
      if (event.indexOf("DELETE") !== -1 || event.indexOf("MOVED_FROM") !== -1)
        root.forgetPath(path)
      else
        root.scheduleReload(path)
    }
    // Events can arrive far faster than a scan can run; coalesce the scan
    // through a short timer rather than spawning find|sort|head per event.
    root._watchPending = true
  }

  // A record file that is gone must leave the listing, or the "known paths"
  // protection would keep deleted sessions forever and eventually crowd out
  // every new one.
  function forgetPath(path: string): void {
    if (path === "") return
    var index = root.recordPaths.indexOf(path)
    if (index !== -1) {
      var next = root.recordPaths.slice()
      next.splice(index, 1)
      root.recordPaths = next
    }
    delete root._mtimes[path]
    delete root._acknowledged[path]
    delete root._pathSeen[path]
    if (root._reloadQueue[path] === true) {
      delete root._reloadQueue[path]
      root._reloadQueued -= 1
    }
    root.scheduleRebuild()
  }

  // Creates and vets the state directory chain. Retried a bounded number of
  // times so a transient failure, or a symlink a same-user writer planted, does
  // not strand the plugin for the rest of the session; the exit handler decides
  // whether the attempt succeeded.
  function startSetup() {
    if (root._setupDone || mkdirProcess.running) return
    if (root._setupAttempts >= 4) return
    root._setupAttempts += 1
    mkdirProcess.running = true
  }

  Component.onCompleted: {
    // mkdirProcess owns the directory chain and creates it with umask 077;
    // the first scan and the marks both start from its exit handler, so
    // nothing here runs under a different umask or against a missing path.
    root.startSetup()
  }

  // Creates and vets the two directories the plugin owns, one level at a time.
  // Session records hold the agent's state and the working directory, so the
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
    "# The records hold session state and stay owner-only; the marks next to them are",
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

  // Re-vets the sessions directory on every scan and lists it with a fixed
  // field order. The startup walk proves the path once; a same-user writer can
  // replace a component with a symlink afterwards, which would redirect the
  // listing and every read, so the walk is repeated here and each component is
  // pinned against its parent inode. mtime and size come before the name, so
  // nothing in a file name can move where the sort key starts, and the whole
  // pipeline (not just find) runs under the caller's timeout, because sort
  // buffers all of its input before head can cap it.
  readonly property string listScript: [
    "set -u",
    "b=\"$1\"",
    "[[ $b == /* ]] || exit 1",
    "step() {",
    "  { [ -d \"$1\" ] && [ ! -L \"$1\" ] && [ -O \"$1\" ]; } || return 1",
    "  pp=$(stat -c '%d:%i' . 2>/dev/null) || return 1",
    "  ee=$(stat -c '%d:%i' -- \"$1\" 2>/dev/null) || return 1",
    "  cd -P -- \"$1\" 2>/dev/null || return 1",
    "  di=$(stat -c '%d:%i' . 2>/dev/null) || return 1",
    "  dp=$(stat -c '%d:%i' .. 2>/dev/null) || return 1",
    "  [ \"$di\" = \"$ee\" ] && [ \"$dp\" = \"$pp\" ]",
    "}",
    "cd -P -- \"$b\" 2>/dev/null || exit 1",
    "step omarchy || exit 1",
    "step muster || exit 1",
    "step sessions || exit 1",
    "# The vetted directory's identity, so the service can notice a later swap or",
    "# recreation and restart its inotify watch instead of watching a dead inode.",
    "printf '#dir %s\\n' \"$(stat -c '%d:%i' . 2>/dev/null)\"",
    "# Done/error records are kept for a week; a tap killed with SIGKILL can",
    "# leave a staging file, which is cleared after an hour. Running this in the",
    "# scan (not only at shell start) keeps a long-lived shell from accumulating",
    "# both.",
    "find -- . -maxdepth 1 -type f -name '*.json' -mtime +7 -delete 2>/dev/null || true",
    "find -- . -maxdepth 1 -type f -name '.muster.*' -mmin +60 -delete 2>/dev/null || true",
    "find -- . -maxdepth 1 -type f -name '*.json' ! -name $'*\\n*' -printf '%T@\\t%s\\t%f\\n' 2>/dev/null | sort -k1,1nr | head -n 256"
  ].join("\n")

  Process {
    id: mkdirProcess
    running: false
    command: ["timeout", "-k", "2", "30", "bash", "-c", root.mkdirScript, "muster-mkdir",
      Model.stateBase(Quickshell.env("XDG_STATE_HOME") || "", root.home)]
    // The marks live in a directory this script creates, so they are (re)written
    // once it exists — the first write on a fresh install would otherwise race
    // the directory's creation. Only watch the directory once it is ours.
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // A refused symlinked component or a transient failure must not strand
        // the plugin for the whole session; retry a bounded number of times.
        if (root._setupAttempts < 4) setupRetry.restart()
        else console.warn("muster", "state directory setup failed after retries; session monitoring is off until the next shell restart")
        return
      }
      root._setupDone = true
      inotifyProbe.running = true
      root.writeMarks()
      root.refresh()
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
    command: ["timeout", "-k", "2", "30", "bash", "-c", root.markScript, "muster-marks", root.marksDir,
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
    id: setupRetry
    interval: 5000
    onTriggered: root.startSetup()
  }

  Timer {
    // One scan per burst of watch events, not one per event.
    interval: 250
    running: true
    repeat: true
    onTriggered: {
      if (root._watchPending) {
        root._watchPending = false
        root.refresh()
      }
    }
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
    command: ["timeout", "-k", "2", "5", "bash", "-c", root.listScript,
      "muster-list", Model.stateBase(Quickshell.env("XDG_STATE_HOME") || "", root.home)]

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
    var dirId = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line === "") continue
      if (line.indexOf("#dir ") === 0) { dirId = line.slice(5); continue }
      // Fixed fields: mtime, size, name. The name is last and may contain a
      // tab, so the first two tabs are the only separators; nothing in a file
      // name can shift where the sort key (mtime) was read from.
      var t1 = line.indexOf("\t")
      if (t1 <= 0) continue
      var t2 = line.indexOf("\t", t1 + 1)
      if (t2 <= t1) continue
      var name = line.slice(t2 + 1)
      if (name === "" || name.indexOf("/") !== -1 || name.slice(-5) !== ".json") continue
      var path = prefix + name
      paths.push(path)
      mtimes[path] = line.slice(0, t1) + "\t" + line.slice(t1 + 1, t2)
    }
    paths.sort()

    // A directory replaced after the watch started leaves inotifywait on a dead
    // inode (it does not exit, so watchRetry never fires). Restart the watch
    // when the vetted identity moves; the scan above is the fallback meanwhile.
    if (dirId !== "" && root._watchDirId !== "" && dirId !== root._watchDirId && watchProcess.running) {
      watchProcess.running = false
      watchRetry.restart()
    }
    if (dirId !== "") root._watchDirId = dirId

    var previous = root._mtimes
    var nowMs = Date.now()
    // The listing is capped at 256 by mtime, and mtime is writer-controlled:
    // 256 freshly touched files could push every real session out of the bar.
    // Keep recently known paths ahead of the new ones, up to 512; a path that
    // has not been seen for ten minutes is dropped, so deleted files do not
    // accumulate forever. The oldest known paths give way first.
    var seen = ({})
    var merged = []
    for (var i = 0; i < paths.length; i++) {
      root._pathSeen[paths[i]] = nowMs
      seen[paths[i]] = true
      merged.push(paths[i])
    }
    var knownPaths = []
    for (var k = 0; k < root.recordPaths.length; k++) {
      var known = root.recordPaths[k]
      if (seen[known] || previous[known] === undefined) continue
      if (nowMs - (root._pathSeen[known] || 0) > 600000) continue
      knownPaths.push(known)
      seen[known] = true
    }
    knownPaths.sort(function (a, b) {
      return (root._pathSeen[a] || 0) - (root._pathSeen[b] || 0)
    })
    merged = knownPaths.concat(merged)
    if (merged.length > 512) merged = merged.slice(merged.length - 512)
    seen = ({})
    for (var m = 0; m < merged.length; m++) seen[merged[m]] = true
    for (var key in root._pathSeen) {
      if (!seen[key]) delete root._pathSeen[key]
    }

    var nextMtimes = ({})
    for (var i = 0; i < paths.length; i++) nextMtimes[paths[i]] = mtimes[paths[i]]
    for (var k = 0; k < merged.length; k++) {
      var kept = merged[k]
      if (nextMtimes[kept] === undefined && previous[kept] !== undefined)
        nextMtimes[kept] = previous[kept]
    }
    paths = merged

    var pathsChanged = JSON.stringify(paths) !== JSON.stringify(root.recordPaths)
    root._mtimes = nextMtimes
    if (pathsChanged) recordPaths = paths
    // Acknowledged paths are in-memory only. Drop the ones whose record is
    // gone so a long shell session does not grow the map without bound.
    if (pathsChanged) {
      for (var ack in root._acknowledged) {
        if (paths.indexOf(ack) === -1) delete root._acknowledged[ack]
      }
    }
    // A new path is read when its Record mounts, so only an existing record
    // whose mtime moved needs an explicit reload.
    for (var j = 0; j < recordInstantiator.count; j++) {
      var watcher = recordInstantiator.objectAt(j)
      if (!watcher) continue
      var current = String(watcher.path || "")
      if (current !== "" && previous[current] !== undefined
          && previous[current] !== nextMtimes[current]) root.scheduleReload(current)
    }
  }

  Instantiator {
    id: recordInstantiator
    model: root.recordPaths

    delegate: Record {
      required property var modelData
      required property int index
      path: modelData
      readDelay: Math.round(index * 5000 / Math.max(1, root.recordPaths.length))
      stateBase: Model.stateBase(Quickshell.env("XDG_STATE_HOME") || "", root.home)
      onRecordChanged: root.scheduleRebuild()
    }

    onObjectAdded: root.scheduleRebuild()
    onObjectRemoved: root.scheduleRebuild()
  }

  // One rebuild per burst of record changes. A tap can publish several
  // records in one batch, and rebuilding the whole list for each of them is
  // O(N^2) at the 256-record cap. `restart()` must not run while the timer is
  // already armed: a writer faster than the interval would postpone the
  // rebuild forever and freeze the bar and the completion alerts.
  function scheduleRebuild(): void {
    if (!rebuildTimer.running) rebuildTimer.restart()
  }

  Timer {
    id: rebuildTimer
    interval: 100
    repeat: false
    onTriggered: root.rebuild()
  }

  // Record reads are bounded in the same way: one writer can touch a file
  // faster than a reader can run, so changed paths go through a queue and at
  // most four reads start per interval. Duplicate paths coalesce.
  property var _reloadQueue: ({})
  property int _reloadQueued: 0

  function scheduleReload(path: string): void {
    if (path === "" || root._reloadQueue[path] === true) return
    // Only a record the scan has already accepted is re-read here. A new
    // file mounts its own Record and reads once; letting arbitrary *.json
    // names into this queue would let a writer starve the real reloads.
    if (root._pathSeen[path] === undefined) return
    if (root._reloadQueued >= 128) return
    root._reloadQueue[path] = true
    root._reloadQueued += 1
    if (!reloadTimer.running) reloadTimer.start()
  }

  function flushReloads(): void {
    var paths = Object.keys(root._reloadQueue)
    for (var i = 0; i < paths.length && i < 4; i++) {
      var path = paths[i]
      delete root._reloadQueue[path]
      root._reloadQueued -= 1
      for (var j = 0; j < recordInstantiator.count; j++) {
        var watcher = recordInstantiator.objectAt(j)
        if (watcher && String(watcher.path) === path) {
          watcher.reloadToken++
          break
        }
      }
    }
    if (root._reloadQueued === 0) reloadTimer.stop()
  }

  Timer {
    id: reloadTimer
    interval: 150
    repeat: true
    onTriggered: root.flushReloads()
  }

  // ------------------------------------------------------------- sessions

  function rebuild() {
    var now = Date.now()
    // One card per record file. The file path is the identity the service
    // actually observes; `pid`, `updatedAt` and `terminalId` are all
    // self-asserted by the writer. Keying by pid used to let a forged record
    // with a victim's pid replace the victim's card; a forged record can
    // still add a card, but it cannot evict a different file's card.
    var collected = []
    for (var i = 0; i < recordInstantiator.count; i++) {
      var watcher = recordInstantiator.objectAt(i)
      if (!watcher) continue
      var session = Model.normalizeRecord(watcher.record, watcher.path)
      if (!session) continue
      // A settled record the user has focused reads as idle; a live record
      // clears any earlier acknowledgement so a later finish alerts again.
      if (Model.isSettled(session.state)) {
        if (root._acknowledged[session.path] === true) {
          session.state = "idle"
          session.kind = ""
        }
      } else if (root._acknowledged[session.path] === true) {
        delete root._acknowledged[session.path]
      }
      if (Model.isStale(session, now, root.staleAfterSec, root.settledAfterSec)) continue
      collected.push(session)
    }

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
        session.kind, session.progress, session.updatedAt,
        session.name, session.message, session.cwd, session.project,
        session.recordId, session.terminalId, session.windowAddress, session.herdrPane,
        session.tmuxPane, session.tmuxSocket, session.pid]))
    }
    return parts.join("\n")
  }

  // ------------------------------------------------------------- alerts

  property real _lastAlertAt: 0
  property var _alertTimes: []
  readonly property int alertBurstLimit: 10
  readonly property int alertBurstWindowMs: 60000

  // A run finishing is the state edge into done/error: the record was working
  // (or blocked) and is now settled. The protocol has no completion counter,
  // so the previous state of each record is what a finished run looks like.
  function detectCompletions(list, now) {
    var previous = root._seen
    var next = {}
    for (var i = 0; i < list.length; i++) {
      var session = list[i]
      var before = previous[session.path]
      next[session.path] = { state: session.state }
      if (!before) {
        if (Model.isSettled(session.state) && session.updatedAt >= root._startedAt)
          root.fireAlert(session, now)
        continue
      }
      if (Model.shouldAlert(session, before)) root.fireAlert(session, now)
    }
    root._seen = next
  }

  function fireAlert(session, now) {
    // The debounce collapses sessions that finish together; the rolling cap
    // stops a same-UID writer that settles a record over and over from
    // turning the alert into a sustained notification and sound stream.
    if (now - root._lastAlertAt < root.debounceMs) return
    var recent = []
    for (var i = 0; i < root._alertTimes.length; i++)
      if (now - root._alertTimes[i] < root.alertBurstWindowMs) recent.push(root._alertTimes[i])
    if (recent.length >= root.alertBurstLimit) return
    recent.push(now)
    root._alertTimes = recent
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

  // The argv that focuses the session. A session is addressable three ways: a
  // Hyprland window (any plain terminal), and inside a multiplexer, a pane.
  // herdr runs its panes under a daemon, so the pane process has no terminal
  // window in its ancestry — the window shown is the herdr client's, and the
  // pane is moved to with `herdr agent focus`. tmux keeps the pane under its
  // own server, so the window is the attached client's and the pane is reached
  // with `tmux switch-client`. Move the multiplexer first, then bring the
  // window forward. Hyprland >= 0.56 with a Lua config reads `dispatch` as Lua
  // and rejects the classic `focuswindow address:…`, so try the Lua form first
  // and fall back — the same pair omarchy-launch-or-focus uses. Every value
  // goes in as positional data, never as shell source: `$1` the address, `$2`
  // the herdr pane, `$3` the tmux pane, `$4` the tmux socket. The address *is*
  // placed inside the Lua string below, so its safety rests on the hex-only
  // test right above it, and each pane on its own id test — all enforced again
  // in Model.js.
  function focusCommand(address, herdrPane, tmuxPane, tmuxSocket) {
    // Every step is bounded: the click runs detached, so a wedged compositor,
    // multiplexer or tmux server must not leave a stray process behind. Each
    // call ends in `|| true` because one surface being unavailable must not
    // stop the others.
    var steps = []
    if (Model.safeHerdrPane(herdrPane) !== "")
      steps.push('timeout 2 herdr agent focus -- "$2" >/dev/null 2>&1 || true')
    // `select-window`/`select-pane` set the session's active window and pane
    // (they work with no client attached); `switch-client -t %N` then moves an
    // attached client to that session, window and pane. The order matters: a
    // failing tmux command aborts the rest of a `\;`-joined list, so the only
    // one that can fail without a client — switch-client — goes last, after the
    // selects have already pointed the session at the pane.
    if (/^%[0-9]{1,6}$/.test(String(tmuxPane || ""))) {
      var server = Model.safeTmuxSocket(String(tmuxSocket || "")) !== "" ? ' -S "$4"' : ""
      steps.push('timeout 2 tmux' + server + ' select-window -t "$3" \\; select-pane -t "$3" \\; switch-client -t "$3" >/dev/null 2>&1 || true')
    }
    if (/^0x[0-9a-fA-F]{1,16}$/.test(String(address || "")))
      steps.push('timeout 2 hyprctl dispatch "hl.dsp.focus({ window = \\"address:$1\\" })" || timeout 2 hyprctl dispatch focuswindow "address:$1"')
    if (steps.length === 0) return null
    return ["bash", "-c", steps.join("\n"), "muster-focus",
      String(address || ""), String(herdrPane || ""), String(tmuxPane || ""), String(tmuxSocket || "")]
  }

  // Left-clicking a panel card jumps to the session's terminal; a notification
  // click runs the same command.
  function focusSession(session) {
    // Focusing a finished session is the acknowledgement the spec leaves to the
    // consumer: the card stops reading as "done" and falls back to idle.
    if (session && session.path && Model.isSettled(session.state)) {
      root._acknowledged[session.path] = true
      root.rebuild()
    }
    var argv = root.focusCommand(session && session.windowAddress, session && session.herdrPane,
      session && session.tmuxPane, session && session.tmuxSocket)
    if (argv) Quickshell.execDetached(argv)
  }

  // The completion toast. It carries no session content: only the agent's
  // label and a fixed word for the state. The text goes through
  // omarchy-notification-send's argv (visible under /proc/<pid>/cmdline) and
  // the notification engine persists the summary and body in
  // ~/.local/state/omarchy/notifications/history.json, so a prompt placed here
  // would be visible in the sender's argv and kept on disk.
  //
  // The agent id is the one record field that does reach that path, so it is
  // bounded and stripped in one place (Model.safeAgentLabel): a record is
  // written by same-user code and its `agent` field is otherwise free text,
  // which would put an arbitrary string — and an arbitrary path in the
  // `--image` argument — into another service's argv and into its on-disk
  // notification history. An id that is not a plain id falls back to a generic
  // label and no icon.
  function notificationCommand(session, isTest) {
    var who = Model.safeAgentLabel(session)
    // The word "test" is in the title, so a self-triggered alert cannot be
    // mistaken for a real completion at a glance.
    var subject, body
    if (isTest === true) {
      subject = "Muster  ·  test"
      body = "Test alert"
    } else {
      subject = "Muster  ·  " + who.label
      body = session.state === "error" ? "Run failed" : "Run finished"
    }
    // omarchy-notification-send only treats a dash-leading description as text
    // when it is not one of its option flags. A body that is exactly `--image=…`
    // (or `-i`, `-g`, …) would otherwise be parsed as that option, and `--image`
    // makes the notification service read the named path. A leading space keeps
    // such a body a description; every other field here is already a constant
    // or a sanitised id that cannot start with a dash.
    if (body.charAt(0) === "-") body = " " + body
    // The rewritten Omarchy notification engine (Omapager) groups cards by
    // app_name, applies Do Not Disturb and snoozes, and keeps history. The
    // sender's default name, omarchy-action, is reserved for Omarchy's own
    // confirmation toasts: it bypasses quiet and is dropped when silenced, so
    // Muster names itself instead.
    var args = ["omarchy-notification-send", "--app-name", "Muster", "-u", "normal"]
    var mark = String(session.agentIcon || "")
    if (mark !== "" && who.id !== "") {
      // Every settled or live state that has its own mark uses it; unknown and
      // idle fall back to the plain, un-suffixed mark.
      var markable = ["working", "blocked", "done", "error"]
      var state = markable.indexOf(session.state) !== -1 ? "-" + session.state : ""
      // The generated mark is an image, not a themed icon name: the engine's
      // -i is a theme lookup, while --image is the standard image-path hint and
      // the flag that accepts a local file.
      args = args.concat(["--image", root.marksDir + "/" + who.id + state + ".svg"])
    }
    args = args.concat([subject, body])
    // Clicking the notification jumps to the terminal that produced it.
    var focus = root.focusCommand(session.windowAddress, session.herdrPane,
      session.tmuxPane, session.tmuxSocket)
    if (focus) args = args.concat(["--exec"]).concat(focus)
    return args
  }

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
        cwd: "",
        windowAddress: ""
      })
    // Stamp the completion debounce rather than clearing it: resetting it to 0
    // let the next real completion bypass the 2 s window, so a test plus a
    // finished run could stack two alerts.
    root._lastAlertAt = now
    if (root.soundEnabled) root.playSound()
    if (root.notifyEnabled) Quickshell.execDetached(root.notificationCommand(subject, true))
  }

}
