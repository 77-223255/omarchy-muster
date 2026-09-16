import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "shienze.agent-status"

  // The scan + alert loop lives in the plugin's service singleton, so the
  // chip only renders what the service knows. Probe the probe counter so the
  // binding re-evaluates once the service finishes mounting.
  property int serviceProbe: 0
  readonly property var svc: {
    var probe = serviceProbe
    if (probe < 0) return null
    if (!bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return null
    return bar.shell.serviceFor(moduleName)
  }

  readonly property var sessions: svc && svc.sessions ? svc.sessions : []
  readonly property var summary: Model.summarize(sessions)
  readonly property bool anyBlocked: summary.blocked > 0
  readonly property bool anyWorking: summary.working > 0 || anyBlocked
  readonly property bool horizontal: !(bar && bar.vertical)

  // Always visible: the chip is the way into the panel, so it keeps a bell
  // instead of disappearing — a chip that vanishes is a chip you cannot click.
  //
  // One mark per agent that has a session, in the order the service sorted them
  // (blocked first, then working), so whatever needs attention is on the left.
  // The marks are omarchy's own, taken from the menu's `setup.default.agent.*`
  // entries: no invented logos.
  readonly property var chipMarks: {
    var marks = []
    var seen = {}
    for (var i = 0; i < sessions.length; i++) {
      var session = sessions[i]
      if (seen[session.agent] === true) continue
      seen[session.agent] = true
      marks.push(session)
    }
    if (marks.length === 0) marks.push(null)
    return root.horizontal ? marks : marks.slice(0, 1)
  }

  readonly property color chipColor: anyBlocked
    ? (bar ? bar.urgent : Color.urgent)
    : (anyWorking ? Color.accent : (bar ? bar.barForeground : Color.foreground))
  readonly property string chipFont: bar ? bar.fontFamily : Style.font.family

  // Long content scrolls rather than pushing the bar around: the visible width
  // is capped and the text slides through it, the way omarchy's media widget
  // runs a long track title.
  readonly property real maxLabelWidth: Style.space(96)
  readonly property real labelWidth: horizontal
    ? Math.min(maxLabelWidth, chipRow.implicitWidth) : Style.space(16)

  implicitWidth: horizontal
    ? labelWidth + Style.space(17)
    : (bar ? bar.barSize : Style.bar.sizeHorizontal)
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  readonly property string tooltip: {
    if (sessions.length === 0) return "No agent sessions · click for details"
    var lines = []
    for (var i = 0; i < sessions.length && i < 8; i++) {
      var session = sessions[i]
      var where = session.project !== "" ? session.project : session.cwd
      lines.push(session.agentLabel + " · " + session.title + " · " + Model.stateLabel(session.state)
        + (where !== "" ? " · " + where : ""))
    }
    if (sessions.length > 8) lines.push("…")
    return lines.join("\n")
  }

  function pushSettings() {
    if (svc && "settings" in svc) svc.settings = settings || ({})
  }

  onSvcChanged: {
    pushSettings()
    injectPanel()
  }
  onSettingsChanged: {
    pushSettings()
    injectPanel()
  }
  onBarChanged: injectPanel()
  Component.onCompleted: pushSettings()

  Timer {
    interval: 2000
    repeat: true
    running: root.svc === null
    onTriggered: root.serviceProbe++
  }

  // Contract for shell.summon / hide / toggle and Bar panel routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function refresh() {
    if (svc && typeof svc.refresh === "function") svc.refresh()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("service" in target) target.service = root.svc
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "shienze.agent-status"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh() }
    function test(): void { if (root.svc && root.svc.testAlert) root.svc.testAlert() }
    function status(): string {
      var states = []
      var details = []
      for (var i = 0; i < root.sessions.length; i++) {
        var session = root.sessions[i]
        states.push(session.agent + ":" + session.state)
        details.push({
          agent: session.agent,
          state: session.state,
          folder: Model.folderLabel(session),
          pid: session.pid,
          completedRuns: session.completedRuns,
          window: session.windowAddress
        })
      }
      return JSON.stringify({
        service: root.svc !== null,
        sessions: root.sessions.length,
        states: states,
        details: details
      })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    labelVisible: false
    keepSpace: true
    active: root.anyWorking
    activeColor: root.anyBlocked ? (root.bar ? root.bar.urgent : Color.urgent) : Color.accent
    tooltipText: root.tooltip

    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        if (root.svc && root.svc.testAlert) root.svc.testAlert()
      } else if (b === Qt.LeftButton) {
        root.togglePanel()
      }
    }
  }

  Item {
    id: labelClip
    anchors.centerIn: parent
    width: root.labelWidth
    height: chipRow.implicitHeight
    clip: true

    Row {
      id: chipRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: root.horizontal ? Style.space(8) : 0

      readonly property bool needsScroll: root.horizontal && implicitWidth > labelClip.width

      NumberAnimation on x {
        running: chipRow.needsScroll
        loops: Animation.Infinite
        duration: Math.max(6000, chipRow.implicitWidth * 25)
        from: labelClip.width
        to: -chipRow.implicitWidth
        easing.type: Easing.Linear
        // Without this the row keeps whatever x it had when the scrolling
        // stopped (the list shrinking below the window is the common case),
        // leaving the marks parked off-screen.
        onRunningChanged: if (!running) chipRow.x = 0
      }

      Repeater {
        model: root.chipMarks

        delegate: Text {
          required property var modelData
          textFormat: Text.PlainText
          text: modelData === null ? Model.IDLE_GLYPH
            : (modelData.agentIcon !== "" ? modelData.agentIcon : modelData.agentLabel)
          color: root.chipColor
          font.family: modelData && modelData.agentFont === "omarchy" ? "omarchy" : root.chipFont
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }
}
