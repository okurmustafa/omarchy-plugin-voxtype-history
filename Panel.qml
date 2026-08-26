import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.okurmustafa.voxtype-history"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(contentForeground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var entries: hostWidget && hostWidget.entries ? hostWidget.entries : []
  readonly property bool paused: hostWidget ? hostWidget.paused === true : false
  readonly property bool wired: hostWidget ? hostWidget.wired === true : false
  readonly property bool voxtypeConfigured: hostWidget ? hostWidget.voxtypeConfigured === true : false
  readonly property bool busy: hostWidget ? hostWidget.busy === true : false
  readonly property string lastError: hostWidget ? String(hostWidget.lastError || "") : ""
  readonly property int todayCount: hostWidget ? hostWidget.todayCount : 0

  property string query: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool searchFocused: false
  property bool clearConfirmOpen: false
  property double nowMs: Date.now()

  readonly property var visibleEntries: Model.filterEntries(entries, query)
  readonly property var selectedEntry: selectedIndex >= 0 && selectedIndex < visibleEntries.length
    ? visibleEntries[selectedIndex] : null
  readonly property bool keysBlocked: searchFocused || clearConfirmOpen

  readonly property int rowHeight: Math.max(Style.space(56), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  readonly property url scrollMark: Qt.resolvedUrl("assets/scroll.svg")

  function open() {
    query = ""
    selectedIndex = 0
    cursorActive = false
    clearConfirmOpen = false
    nowMs = Date.now()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
      if (keyCatcher) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    query = ""
    clearConfirmOpen = false
    cursorActive = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function callHost(name, a, b) {
    if (!hostWidget || typeof hostWidget[name] !== "function") return
    if (b !== undefined) hostWidget[name](a, b)
    else if (a !== undefined) hostWidget[name](a)
    else hostWidget[name]()
  }

  function clampSelection() {
    if (visibleEntries.length === 0) {
      selectedIndex = 0
      return
    }
    if (selectedIndex >= visibleEntries.length) selectedIndex = visibleEntries.length - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  function moveSelection(delta) {
    if (visibleEntries.length === 0) return
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(visibleEntries.length - 1, selectedIndex + delta))
  }

  function activateSelected() {
    if (selectedEntry) callHost("copyEntry", selectedEntry.id)
  }

  function focusSearch() {
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.keysBlocked
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveSelection(dy)
      }
      onDeleteRequested: {
        if (root.selectedEntry) root.callHost("deleteEntry", root.selectedEntry.id)
      }
      onTextKey: function(t) {
        if (t === "/" || t === "f" || t === "F") {
          root.focusSearch()
        } else if (t === "p" || t === "P") {
          if (root.selectedEntry)
            root.callHost("pinEntry", root.selectedEntry.id, !root.selectedEntry.pinned)
        } else if (t === "c" || t === "C") {
          root.activateSelected()
        }
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: Math.max(heroIcon.height, heroLabels.height, pauseSwitch.height)

          Item {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.font.display
            height: Style.font.display

            Image {
              id: heroMark
              anchors.fill: parent
              source: root.scrollMark
              sourceSize.width: Math.max(2, width) * 2
              sourceSize.height: Math.max(2, height) * 2
              fillMode: Image.PreserveAspectFit
              smooth: true
              antialiasing: true
              visible: false
              layer.enabled: true
            }

            MultiEffect {
              anchors.fill: heroMark
              source: heroMark
              visible: heroMark.status === Image.Ready
              colorization: 1.0
              colorizationColor: root.contentForeground
            }

            Text {
              anchors.centerIn: parent
              visible: heroMark.status !== Image.Ready
              text: "\uf70e"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.display
            }
          }

          ToggleSwitch {
            id: pauseSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.wired && !root.paused
            enabled: root.wired
            foreground: root.contentForeground
            onToggled: root.callHost("togglePause")

            PanelToolTip {
              visible: pauseSwitch.containsMouse
              text: root.paused ? "Resume logging" : "Pause logging"
              fontFamily: root.contentFontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: pauseSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Dictation (Voxtype) History"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.paused ? "Logging paused" : (root.wired ? (root.todayCount + " today · " + root.entries.length + " saved") : "Capture is off")
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Rectangle {
          visible: !root.wired
          width: parent.width
          height: setupColumn.height + Style.space(16)
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.contentForeground, Color.accent)

          Column {
            id: setupColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(10)
            spacing: Style.space(8)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.voxtypeConfigured
                ? "Voxtype is not sending transcripts here yet. Enable capture to log each dictation locally."
                : "Install Voxtype first (Install → AI → Dictation), then enable capture."
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            Button {
              text: "Enable capture"
              enabled: root.voxtypeConfigured && !root.busy
              foreground: root.contentForeground
              onClicked: root.callHost("enableCapture")
            }
          }
        }

        TextField {
          id: searchField
          width: parent.width
          placeholderText: "Search dictations"
          foreground: root.contentForeground
          font.family: root.contentFontFamily
          text: root.query
          onTextChanged: {
            root.query = text
            root.clampSelection()
          }
          onActiveFocusChanged: root.searchFocused = activeFocus
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              if (searchField.text !== "") searchField.text = ""
              keyCatcher.forceActiveFocus()
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              keyCatcher.forceActiveFocus()
              root.moveSelection(0)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }
        }

        Text {
          visible: root.lastError !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.lastError
          color: root.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: root.wired && root.visibleEntries.length === 0
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.query !== "" ? "No matches." : "No dictations yet. Hold F9 or Super+Ctrl+X to dictate."
          color: root.dim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
        }

        ListView {
          id: list
          visible: root.visibleEntries.length > 0
          width: parent.width
          height: Math.min(root.rowHeight * Math.min(root.visibleEntries.length, 6), root.rowHeight * 6)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.visibleEntries
          currentIndex: root.selectedIndex
          spacing: Style.space(2)

          onCountChanged: root.clampSelection()

          delegate: Rectangle {
            required property var modelData
            required property int index
            width: list.width
            height: root.rowHeight
            radius: Style.cornerRadius
            color: {
              if (root.cursorActive && index === root.selectedIndex)
                return Style.selectedFillFor(root.contentForeground, Color.accent)
              if (rowMouse.containsMouse)
                return Style.hoverFillFor(root.contentForeground, Color.accent)
              return "transparent"
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton
              onEntered: {
                root.cursorActive = true
                root.selectedIndex = index
              }
              onClicked: function(event) {
                root.selectedIndex = index
                root.callHost("copyEntry", modelData.id)
              }
            }

            Column {
              anchors.left: parent.left
              anchors.right: actions.left
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: Model.previewText(modelData.text, 72)
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: (modelData.pinned ? "Pinned · " : "") + Model.relativeTime(modelData.ts, new Date(root.nowMs))
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: actions
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PanelActionButton {
                iconText: modelData.pinned ? String.fromCodePoint(0xF0403) : String.fromCodePoint(0xF0931)
                tooltipText: modelData.pinned ? "Unpin" : "Pin"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.callHost("pinEntry", modelData.id, !modelData.pinned)
              }

              PanelActionButton {
                iconText: String.fromCodePoint(0xF018F)
                tooltipText: "Copy"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.callHost("copyEntry", modelData.id)
              }

              PanelActionButton {
                iconText: String.fromCodePoint(0xF01B4)
                tooltipText: "Delete"
                foreground: root.urgent
                hoverColor: root.urgent
                fontFamily: root.contentFontFamily
                onClicked: root.callHost("deleteEntry", modelData.id)
              }
            }
          }
        }

        Item {
          visible: root.entries.length > 0 && !root.clearConfirmOpen
          width: parent.width
          height: clearButton.height

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "c copies · p pins · / searches"
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            id: clearButton
            anchors.right: parent.right
            text: "Clear"
            foreground: root.contentForeground
            onClicked: root.clearConfirmOpen = true
          }
        }

        Rectangle {
          visible: root.clearConfirmOpen
          width: parent.width
          height: confirmRow.height + Style.space(12)
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.urgent, root.urgent)

          Row {
            id: confirmRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(8)
            spacing: Style.space(8)

            Text {
              width: parent.width - clearUnpinnedBtn.width - clearAllBtn.width - cancelBtn.width - parent.spacing * 3
              anchors.verticalCenter: parent.verticalCenter
              wrapMode: Text.WordWrap
              text: "Remove unpinned dictations?"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            Button {
              id: cancelBtn
              text: "Cancel"
              foreground: root.contentForeground
              onClicked: root.clearConfirmOpen = false
            }

            Button {
              id: clearUnpinnedBtn
              text: "Unpinned"
              foreground: root.contentForeground
              onClicked: {
                root.callHost("clearUnpinned")
                root.clearConfirmOpen = false
              }
            }

            Button {
              id: clearAllBtn
              text: "All"
              foreground: root.urgent
              onClicked: {
                root.callHost("clearAll")
                root.clearConfirmOpen = false
              }
            }
          }
        }
      }
    }
  }
}
