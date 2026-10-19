import QtQuick
import Quickshell.Io
import "Model.js" as Model

// One agent session record, read off the file its integration writes.
//
// A record is untrusted input: any agent integration may write one, and it
// runs as the same user as the shell. The sessions directory is owner-only, so
// another local user cannot write there, but that says nothing about what a
// same-user writer puts at a record path. The reader therefore refuses to
// follow a symlink, refuses anything that is not a plain file, and caps the
// read, so a record cannot steer the long-lived shell at another file, make it
// wait on a special file, or make it allocate without bound.
Item {
  id: root
  visible: false

  property string path: ""
  property string stateBase: ""
  property var record: null
  property int reloadToken: 0
  property int maxRecordBytes: Model.MAX_RECORD_BYTES
  // A listing can mount 256 delegates at once; starting every reader in the
  // same tick is a process burst. The Service spaces the first read by index.
  property int readDelay: 0
  property bool ready: false

  // The parent chain is re-vetted here the way the scan's list script vets it,
  // so a directory component swapped for a symlink between the listing and this
  // read cannot redirect it. The checks are shell builtins (-d, -L, -O, cd), so
  // this adds no subprocess per read; only stat and dd run, and the caller's
  // timeout bounds the whole script (previously only dd was wrapped, so a
  // stalled filesystem could leave reader.running true forever).
  readonly property string readScript: [
    "set -u",
    "file=\"$1\" cap=\"$2\" b=\"$3\"",
    "[[ -n \"$b\" && $file == \"$b\"/* ]] || exit 0",
    "cd -P -- \"$b\" 2>/dev/null || exit 0",
    "for c in omarchy muster sessions; do",
    "  [ -d \"$c\" ] && [ ! -L \"$c\" ] && [ -O \"$c\" ] || exit 0",
    "  cd -- \"$c\" || exit 0",
    "done",
    "name=\"${file##*/}\"",
    "[ -f \"$name\" ] && [ ! -L \"$name\" ] && [ -O \"$name\" ] || exit 0",
    "size=$(stat -c %s -- \"$name\" 2>/dev/null) || exit 0",
    "[ \"$size\" -le \"$cap\" ] || exit 0",
    "exec dd if=\"$name\" iflag=nofollow,nonblock bs=\"$cap\" count=1 status=none 2>/dev/null"
  ].join("\n")

  function parse(content) {
    var text = String(content || "")
    // A file caught mid-delete or mid-rename reads as empty; that is not a
    // malformed record worth a warning.
    if (text.trim() === "") {
      root.record = null
      return
    }
    try {
      var parsed = JSON.parse(text)
      root.record = parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      console.warn("muster", "Ignoring bad session record", root.path, e)
      root.record = null
    }
  }

  // A process, not a FileView: the read has to be the one the script above
  // guards. Directory events and the service's scan tick drive reloadToken, so
  // a rewritten record is picked up the same way as before.
  Process {
    id: reader
    running: false
    command: ["timeout", "-k", "2", "5", "bash", "-c", root.readScript, "muster-read",
      root.path, String(root.maxRecordBytes), root.stateBase]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.parse(text)
        if (root.pending && !reader.running) {
          root.pending = false
          root.read()
        }
      }
    }

    // A reload can arrive while the read is still finishing. StdioCollector's
    // onStreamFinished can fire before `running` flips false, so the pending
    // flag must also be consumed here — otherwise the last write before a
    // writer goes quiet is never re-read and the card stays stale.
    onExited: {
      if (root.pending) {
        root.pending = false
        root.read()
      }
    }
  }

  property bool pending: false

  // A reload that arrives while a read is in flight is remembered, not dropped:
  // this reader is the only thing that re-reads a rewritten record, so a
  // dropped reload would leave the card stale until the next mtime change.
  Timer {
    id: initialRead
    interval: Math.max(0, root.readDelay)
    repeat: false
    onTriggered: {
      root.ready = true
      root.read()
    }
  }

  function read() {
    if (root.path === "") return
    if (reader.running) {
      root.pending = true
      return
    }
    reader.running = true
  }


  onPathChanged: if (root.ready) root.read()
  onReloadTokenChanged: if (root.ready) root.read()
  Component.onCompleted: initialRead.start()
}
