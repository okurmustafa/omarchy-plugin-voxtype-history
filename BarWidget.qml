import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// History icon for the bar, and the host for the dictation log panel.
// Left click opens the panel. The chip tints while Voxtype is recording.
BarWidget {
  id: root
  moduleName: "io.github.okurmustafa.voxtype-history"

  property var entries: []
  property bool paused: false
  property bool wired: false
  property bool voxtypeConfigured: false
  property string recordingState: "idle"
  property string lastError: ""
  property bool busy: false

  readonly property string dataDir: Quickshell.env("HOME") + "/.local/share/voxtype-history"
  readonly property string historyPath: dataDir + "/history.jsonl"
  readonly property string metaPath: dataDir + "/meta.json"
  readonly property string voxtypeConfigPath: Quickshell.env("HOME") + "/.config/voxtype/config.toml"
  readonly property string helperPath: resolveHelper()
  readonly property int todayCount: Model.todayCount(entries, new Date())
  readonly property bool recording: recordingState === "recording" || recordingState === "transcribing"
  readonly property url scrollMark: Qt.resolvedUrl("assets/scroll.svg")

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function resolveHelper() {
    var raw = String(Qt.resolvedUrl("bin/voxtype-history"))
    if (raw.indexOf("file://") !== 0) return raw
    var path = raw.substring(7)
    if (path.charAt(0) !== "/") {
      var slash = path.indexOf("/")
      path = slash >= 0 ? path.substring(slash) : path
    }
    try { return decodeURIComponent(path) } catch (e) { return path }
  }

  function loadHistory(raw) {
    entries = Model.parseHistory(raw)
  }

  function loadMeta(raw) {
    paused = Model.parseMeta(raw).paused
  }

  function loadConfig(raw) {
    voxtypeConfigured = String(raw || "").length > 0
    wired = Model.configLooksWired(raw)
  }

  function runCli(args) {
    if (helperPath === "" || cliProc.running) return
    busy = true
    lastError = ""
    var command = [helperPath]
    for (var i = 0; i < args.length; i++) command.push(args[i])
    cliProc.command = command
    cliProc.running = true
  }

  function enableCapture() { runCli(["enable"]) }
  function disableCapture() { runCli(["disable"]) }
  function togglePause() { runCli(paused ? ["resume"] : ["pause"]) }
  function copyEntry(id) { runCli(["copy", id]) }
  function pinEntry(id, pinned) { runCli([pinned ? "pin" : "unpin", id]) }
  function deleteEntry(id) { runCli(["delete", id]) }
  function clearUnpinned() { runCli(["clear"]) }
  function clearAll() { runCli(["clear", "--all"]) }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onEntriesChanged: injectPanel()
  onPausedChanged: injectPanel()
  onWiredChanged: injectPanel()

  Process {
    command: ["mkdir", "-p", "-m", "700", root.dataDir]
    running: true
  }

  FileView {
    path: root.dataDir
    watchChanges: true
    printErrors: false
    onFileChanged: {
      historyFile.reload()
      metaFile.reload()
    }
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadHistory(text())
    onLoadFailed: root.loadHistory("")
    onFileChanged: reload()
  }

  FileView {
    id: metaFile
    path: root.metaPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadMeta(text())
    onLoadFailed: root.loadMeta("{}")
    onFileChanged: reload()
  }

  FileView {
    id: configFile
    path: root.voxtypeConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfig(text())
    onLoadFailed: root.loadConfig("")
    onFileChanged: reload()
  }

  Process {
    command: ["bash", "-c", "omarchy-voxtype-status"]
    running: true
    stdout: SplitParser {
      onRead: function(raw) {
        try {
          var data = JSON.parse(String(raw || "{}"))
          root.recordingState = String(data.alt || data.class || "idle")
        } catch (e) {
          root.recordingState = "idle"
        }
      }
    }
  }

  Process {
    id: cliProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err) root.lastError = err
      }
    }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = "Command exited " + exitCode
      historyFile.reload()
      metaFile.reload()
      configFile.reload()
    }
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
    target: "io.github.okurmustafa.voxtype-history"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function enable(): void { root.enableCapture() }
    function pause(): void { root.togglePause() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Font Awesome scroll, present in Nerd Fonts Omarchy ships.
    // Only drawn if the SVG mark fails to load.
    text: "\uf70e"
    slotSize: Style.bar.statusSlot
    opticalSize: Style.bar.iconFont
    tooltipText: Model.barTooltip(root.wired, root.paused, root.recordingState, root.entries.length, root.todayCount)
    active: root.recording
    dimmed: root.paused && !root.recording
    iconComponent: Component {
      Item {
        Image {
          id: barMark
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
          anchors.fill: barMark
          source: barMark
          visible: barMark.status === Image.Ready
          colorization: 1.0
          colorizationColor: button.active && button.useActiveColor ? button.activeColor : button.foreground
        }

        Text {
          anchors.centerIn: parent
          visible: barMark.status !== Image.Ready
          text: button.text
          color: button.active && button.useActiveColor ? button.activeColor : button.foreground
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePause()
      else root.togglePanel()
    }
  }
}
