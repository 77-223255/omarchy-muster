import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The popup behind the bar chip. A display: it renders whatever the plugin's
// service has discovered and forwards the two actions worth having — focus a
// session's terminal, and toggle the alerts.
Panel {
  id: root
  moduleName: "shienze.muster"
  ipcTarget: "shienze.muster"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color dimColor: Qt.darker(contentForeground, 1.35)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property int cursor: 0
  property var sessions: service && service.sessions ? service.sessions : []
  readonly property var summary: Model.summarize(sessions)

  // One breathing clock for the whole panel.
  //
  // The cards live inside a Repeater over `sessions`, so every list change
  // (each heartbeat, each state change) re-creates the delegates. A per-card
  // animation therefore restarted mid-breath and looked like a reset after a
  // few cycles. The phase lives here instead, and a linear 0→1 ramp mapped
  // through a cosine is continuous across the loop point *and* gives the ease,
  // so nothing snaps no matter how often the cards are rebuilt.
  property real breathPhase: 0
  readonly property real breath: 0.5 - 0.5 * Math.cos(2 * Math.PI * breathPhase)

  NumberAnimation on breathPhase {
    running: root.opened
    loops: Animation.Infinite
    from: 0
    to: 1
    duration: 3400
  }

  onSessionsChanged: if (cursor >= sessions.length) cursor = Math.max(0, sessions.length - 1)

  function open() {
    root.refresh()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function refresh() {
    if (service && typeof service.refresh === "function") service.refresh()
  }

  // A click on a card fires the alert path for that session, marked as a test
  // in the notification. Focusing the terminal lives on the notification's own
  // click action now, so it is one click away rather than being the click.
  function activate(session) {
    if (!session) return
    if (service && typeof service.testAlert === "function") service.testAlert(session)
  }

  // Rewrite the widget's inline entry in ~/.config/omarchy/shell.json through
  // the shell facade, the way every shell widget persists a setting.
  function persist(newSettings) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    for (var key in newSettings) entry[key] = newSettings[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ------------------------------------------------------------- hero

  // No mark here: the cards carry the colour, so the header stays plain.

  // ------------------------------------------------------------- card

  // A running session is a solid block of the theme colour, a blocked one the
  // urgent colour, everything else plain. The text inverts to the popup's own
  // background (the language the settings tiles use), and the only thing that
  // moves is a soft rim around a running card.
  component SessionCard: BorderSurface {
    id: card
    required property var session
    required property int cardIndex
    property bool hasCursor: false

    readonly property bool hot: hasCursor || mouse.containsMouse
    readonly property bool running: session.state === "working"
    readonly property bool blocked: session.state === "blocked"
    readonly property bool alive: running || blocked

    // The interior is always the same grey; the state lives on the rim and in
    // the title. Only a working card's rim moves.
    readonly property color cardFill: Qt.rgba(root.contentForeground.r, root.contentForeground.g,
      root.contentForeground.b, hot ? 0.10 : 0.06)
    readonly property color titleColor: blocked ? root.urgentColor
      : (running ? root.accentColor : root.contentForeground)
    // The working rim: a lightened, soft theme colour whose opacity follows
    // the panel's shared breathing clock. A blocked card gets the same rim in
    // the urgent colour, held still.
    readonly property color ringColor: Qt.lighter(root.accentColor, 1.45)

    width: parent ? parent.width : implicitWidth
    implicitHeight: body.implicitHeight + Style.spacing.huge
    radius: Style.cornerRadius
    color: cardFill
    borderSpec: Border.controlSpec(
      hasCursor ? "focus" : (hot ? "hover-cursor" : "normal"),
      blocked ? root.urgentColor : (running ? root.accentColor : root.contentForeground),
      root.accentColor, root.urgentColor)

    Rectangle {
      anchors.fill: parent
      radius: card.radius
      color: "transparent"
      border.width: Math.max(1, Style.space(2))
      border.color: card.blocked
        ? Qt.rgba(root.urgentColor.r, root.urgentColor.g, root.urgentColor.b, 0.85)
        : Qt.rgba(card.ringColor.r, card.ringColor.g, card.ringColor.b, 0.22 + 0.58 * root.breath)
      antialiasing: true
      visible: card.alive
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activate(card.session)
      onContainsMouseChanged: if (containsMouse) root.cursor = card.cardIndex
    }

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.xxl
      anchors.rightMargin: Style.spacing.xxl
      spacing: Style.spacing.sm

      // The agent's own mark, then the folder it is working in. No agent name:
      // the mark says who, the folder says where.
      Item {
        width: parent.width
        implicitHeight: Math.max(agentMark.implicitHeight, folderLabelText.implicitHeight)

        Text {
          id: agentMark
          textFormat: Text.PlainText
          visible: card.session.agentIcon !== ""
          text: card.session.agentIcon
          color: card.titleColor
          font.family: card.session.agentFont === "omarchy" ? "omarchy" : root.contentFontFamily
          font.pixelSize: Style.font.subtitle
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: folderLabelText
          textFormat: Text.PlainText
          width: parent.width - (agentMark.visible ? agentMark.width + Style.spacing.lg : 0)
          text: Model.folderLabel(card.session)
          color: card.titleColor
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: card.running || card.blocked
          elide: Text.ElideRight
          anchors.left: agentMark.visible ? agentMark.right : parent.left
          anchors.leftMargin: agentMark.visible ? Style.spacing.lg : 0
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: card.session.state === "blocked" && card.session.message !== ""
        text: "! " + card.session.message
        color: root.urgentColor
        font.bold: true
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: card.session.lastPrompt !== ""
        text: "› " + Model.truncate(card.session.lastPrompt, 140)
        color: root.dimColor
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // Two states, two tiles, no gap between them: the outer corners follow the
  // theme's rounding, the inner ones stay square so the pair reads as one
  // control. On = the theme accent, off = a grey tile.

  component SettingTile: Rectangle {
    id: tile
    required property string label
    property bool checked: false
    property bool outerLeft: false
    property bool outerRight: false
    signal clicked()

    readonly property real corner: Style.cornerRadius
    readonly property bool hot: tileMouse.containsMouse
    readonly property color fill: checked
      ? root.accentColor
      : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b,
          hot ? 0.20 : 0.12)

    implicitHeight: Style.space(44)
    topLeftRadius: outerLeft ? corner : 0
    bottomLeftRadius: outerLeft ? corner : 0
    topRightRadius: outerRight ? corner : 0
    bottomRightRadius: outerRight ? corner : 0
    color: fill

    Behavior on color { ColorAnimation { duration: 120 } }

    Text {
      anchors.centerIn: parent
      text: tile.label
      color: tile.checked
        ? (root.bar && root.bar.background ? root.bar.background : Color.background)
        : root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: tile.checked
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight, Style.space(540))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.activate(root.sessions[root.cursor])
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        root.cursor = Math.max(0, Math.min(root.sessions.length - 1, root.cursor + dy))
      }
      onTextKey: function(t) {
        if (t === "t" || t === "T") {
          if (root.service && root.service.testAlert) root.service.testAlert()
        }
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: mainColumn
          width: panelScroll.width
          spacing: Style.spacing.xxxl

          PanelHero {
            width: parent.width
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            title: "Agents"
            meta: root.sessions.length === 0
              ? "NOTHING RUNNING"
              : (root.summary.blocked > 0
                ? root.summary.blocked + " NEEDS YOU  ·  " + root.summary.working + " WORKING"
                : root.summary.working + " WORKING  ·  " + root.summary.idle + " READY")
          }

          Text {
            width: parent.width
            visible: root.sessions.length === 0
            text: "No agent sessions.\nRecords are read from ~/.local/state/omarchy/muster/sessions/ — an agent appears here once its bridge or hook writes one."
            color: root.dimColor
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width
            spacing: Style.spacing.lg

            Repeater {
              model: root.sessions

              delegate: SessionCard {
                required property var modelData
                required property int index
                session: modelData
                cardIndex: index
                hasCursor: root.cursor === index
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          Row {
            width: parent.width
            spacing: 0

            SettingTile {
              width: Math.floor(parent.width / 2)
              outerLeft: true
              label: "Sound"
              checked: root.setting("soundEnabled", true) === true
              onClicked: root.persist({ soundEnabled: !checked })
            }

            SettingTile {
              width: parent.width - Math.floor(parent.width / 2)
              outerRight: true
              label: "Notification"
              checked: root.setting("notifyEnabled", true) === true
              onClicked: root.persist({ notifyEnabled: !checked })
            }
          }
        }
      }

      ScrollBar {
        id: scrollBar
        anchors.left: panelScroll.right
        anchors.leftMargin: Style.space(4)
        anchors.top: panelScroll.top
        anchors.bottom: panelScroll.bottom
        orientation: Qt.Vertical
        policy: panelScroll.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        width: Style.space(4)
        padding: 0
        size: panelScroll.height / Math.max(panelScroll.height, panelScroll.contentHeight)
        position: panelScroll.contentY / Math.max(1, panelScroll.contentHeight)

        onPositionChanged: {
          if (scrollBar.pressed) panelScroll.contentY = position * panelScroll.contentHeight
        }

        contentItem: Rectangle {
          implicitWidth: Style.space(4)
          radius: width / 2
          color: root.accentColor
          opacity: scrollBar.pressed ? 0.95 : (scrollBar.hovered ? 0.8 : (panelScroll.moving || panelScroll.flicking ? 0.65 : 0.35))

          Behavior on opacity { NumberAnimation { duration: 150 } }
        }
      }
    }
  }
}
