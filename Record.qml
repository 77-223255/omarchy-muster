import QtQuick
import Quickshell.Io

// One agent session record, read straight off the file its integration writes.
// The plugin never learns how the state was produced — a record that appears in
// the sessions directory is a session, whoever wrote it.
Item {
  id: root
  visible: false

  property string path: ""
  property var record: null
  property int reloadToken: 0

  FileView {
    id: fileView
    path: root.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.record = null
  }

  onReloadTokenChanged: fileView.reload()

  function parse(content) {
    // A file caught mid-delete or mid-rename reads as empty; that is not a
    // malformed record worth a warning.
    if (String(content || "").trim() === "") {
      root.record = null
      return
    }
    try {
      var parsed = JSON.parse(String(content || ""))
      root.record = parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      console.warn("agent-status", "Ignoring bad session record", root.path, e)
      root.record = null
    }
  }
}
