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
  property var record: null
  property int reloadToken: 0
  property int maxRecordBytes: Model.MAX_RECORD_BYTES

  // -f (stat) rejects a directory, FIFO, socket or device node; !-L (lstat)
  // rejects a symlink so a record cannot point at another file. dd repeats
  // the symlink rejection as part of the open with iflag=nofollow — a test
  // followed by a separate open leaves a window to swap the file — and
  // iflag=nonblock keeps a special file from ever making the shell wait.
  // bs+count cap the read even if the file grows after the size check.
  readonly property string readScript: [
    "set -u",
    "file=\"$1\" cap=\"$2\"",
    "[ -f \"$file\" ] && [ ! -L \"$file\" ] || exit 0",
    "size=$(stat -c %s -- \"$file\" 2>/dev/null) || exit 0",
    "[ \"$size\" -le \"$cap\" ] || exit 0",
    "exec dd if=\"$file\" iflag=nofollow,nonblock bs=\"$cap\" count=1 status=none 2>/dev/null"
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
    command: ["bash", "-c", root.readScript, "muster-read", root.path, String(root.maxRecordBytes)]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
  }

  function read() {
    if (root.path !== "") reader.running = true
  }

  onPathChanged: root.read()
  onReloadTokenChanged: root.read()
  Component.onCompleted: root.read()
}
