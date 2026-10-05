import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Per-mouse sensor angle. Hyprland applies it through libinput's device
// rotation, so it works on any mouse and is independent of firmware.
// Live changes go through `hyprctl eval hl.device(...)`; the same value is
// mirrored into a generated Lua file so it survives Hyprland restarts.
// Settings are keyed by hardware id (bus:vendor:product[:serial]); device
// names are only handles resolved for applying them.
//
// Standalone panel plugin (no bar icon): summoned from the omarchy menu, the
// content appears as a centered card on a scrim; Esc, Tab and the arrow keys
// drive it like the old bar popup did.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false

  property string angleFile: (Quickshell.env("HOME") || "") + "/.config/hypr/mouse-angle.lua"
  property var angles: []        // persisted: [{ hwid, name, rotation }]
  property var mice: []          // connected pointers: [{ name, hwid }]
  property string selected: ""   // identity key: hwid, or name when unknown
  property var evalQueue: []
  property string lastError: ""
  property int fineStep: 1
  property int coarseStep: 5

  readonly property string fontFamily: Style.font.family
  readonly property color fg: Color.popups.text
  readonly property color dim: Util.alpha(Color.popups.text, 0.55)
  readonly property int rotation: rotationOf(selected)
  readonly property var rows: rowList()
  readonly property var steps: [-coarseStep, -fineStep, fineStep, coarseStep]

  function rotationOf(key) {
    var e = Model.find(root.angles, key)
    return e ? e.rotation : 0
  }

  // Connected mice first (one row per hardware id), then remembered entries
  // (e.g. an unplugged mouse).
  function rowList() {
    var out = [], seen = {}, i, key
    for (i = 0; i < root.mice.length; i++) {
      key = Model.keyOf(root.mice[i])
      if (seen[key]) continue
      seen[key] = true
      out.push({ key: key, name: root.mice[i].name, rotation: root.rotationOf(key) })
    }
    for (i = 0; i < root.angles.length; i++) {
      key = Model.keyOf(root.angles[i])
      if (!seen[key]) {
        seen[key] = true
        out.push({ key: key, name: root.angles[i].name, rotation: root.angles[i].rotation })
      }
    }
    return out
  }

  // Prefer a device that is actually rotated, so the panel opens on the mouse
  // you tuned rather than whichever one Hyprland happened to list first.
  function defaultSelection() {
    var i
    for (i = 0; i < root.angles.length; i++)
      if (root.angles[i].rotation !== 0) return Model.keyOf(root.angles[i])
    return root.mice.length > 0 ? Model.keyOf(root.mice[0]) : ""
  }

  function deviceByKey(key) {
    for (var i = 0; i < root.mice.length; i++)
      if (Model.keyOf(root.mice[i]) === key) return root.mice[i]
    return null
  }

  function selectedName() {
    var e = Model.find(root.angles, root.selected), d = deviceByKey(root.selected)
    return (e && e.name) || (d && d.name) || ""
  }

  function setAngle(key, deg) {
    if (!key) return
    var entry = Model.find(root.angles, key)
    var dev = deviceByKey(key)
    if (!entry && !dev) return
    // The name travels with the identity: refresh it to the connected
    // device's current name so startup applies keep working after renames.
    if (dev) {
      if (!entry) entry = { hwid: dev.hwid, name: dev.name }
      else { entry.hwid = dev.hwid; entry.name = dev.name }
    }
    if (!Model.isSafeName(entry.name)) {
      root.lastError = "Unusable device name: " + entry.name
      return
    }
    entry.rotation = Model.normalize(deg)
    root.angles = Model.upsert(root.angles, entry)
    root.saveAngleFile()
    root.applyAngle(entry)
  }

  function nudge(delta) {
    if (root.selected) root.setAngle(root.selected, root.rotation + delta)
  }

  // Apply to every connected device carrying this hardware id (identical
  // models resolve to the same id). Nothing connected: the generated file
  // applies it at the next Hyprland start.
  function applyAngle(entry) {
    var key = Model.keyOf(entry), queue = [], i
    for (i = 0; i < root.mice.length; i++)
      if (Model.keyOf(root.mice[i]) === key)
        queue.push('hl.device({ name = "' + root.mice[i].name + '", rotation = ' + entry.rotation + ' })')
    if (queue.length === 0) return
    root.evalQueue = queue
    runNextEval()
  }

  function runNextEval() {
    if (root.evalQueue.length === 0) return
    evalProc.command = ["hyprctl", "eval", root.evalQueue[0]]
    evalProc.running = true
  }

  // Reconcile remembered entries with the connected devices: name-only
  // entries adopt a hardware id (pre-hwid state files, plus stale Hyprland
  // "-N" dedup names), hwid-keyed entries re-heal their stored name after
  // renames, and duplicate identities collapse into the first entry.
  function syncEntries() {
    var out = [], dirty = false, i, j, e, d
    for (i = 0; i < root.angles.length; i++) {
      e = root.angles[i]
      if (!e.hwid) {
        for (j = 0; j < root.mice.length; j++)
          if (root.mice[j].name === e.name && root.mice[j].hwid) { e.hwid = root.mice[j].hwid; dirty = true; break }
        var m = String(e.name || "").match(/^(.*)-\d+$/)
        if (!e.hwid && m)
          for (j = 0; j < root.mice.length; j++)
            if (root.mice[j].name === m[1] && root.mice[j].hwid) { e.hwid = root.mice[j].hwid; e.name = root.mice[j].name; dirty = true; break }
      }
      if (e.hwid) {
        for (j = 0; j < root.mice.length; j++) {
          d = root.mice[j]
          if (Model.keyOf(d) === Model.keyOf(e) && d.name !== e.name) { e.name = d.name; dirty = true; break }
        }
      }
      if (Model.find(out, Model.keyOf(e))) { dirty = true; continue }
      out.push(e)
    }
    if (dirty) { root.angles = out; root.saveAngleFile() }
  }

  function saveAngleFile() {
    // Atomic replace: Hyprland may read the file mid-write on a reload.
    saveProc.command = ["sh", "-c", 'printf %s "$1" > "$2.tmp" && mv "$2.tmp" "$2"', "sh", Model.formatAngleFile(root.angles), root.angleFile]
    saveProc.running = true
  }

  function refreshDevices() {
    if (!listProc.running) listProc.running = true
  }

  function noteError(raw, exitCode) {
    var text = String(raw || "").trim()
    if (exitCode !== 0 || /^error/i.test(text)) root.lastError = text
    else root.lastError = ""
  }

  function open(payloadJson) {
    root.opened = true
    refreshDevices()
    angleView.reload()
    // The window is instantiated hidden, so focus set declaratively would be
    // evaluated before the surface is mapped and Escape would land nowhere.
    // Re-acquire after mapping.
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.kaz.omarchy-mouse-angle")
    else close()
  }

  // Tab cycles the mouse rows (the bar popup used this to jump bar panels).
  function switchRow(direction) {
    var list = root.rows
    if (list.length === 0) return
    var i = 0
    for (var j = 0; j < list.length; j++)
      if (list[j].key === root.selected) { i = j; break }
    root.selected = list[(i + direction + list.length) % list.length].key
  }

  Component.onCompleted: {
    refreshDevices()
    angleView.reload()
  }
  onOpenedChanged: if (opened) refreshDevices()

  FileView {
    id: angleView
    path: root.angleFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.angles = Model.parseAngleFile(text())
      if (root.selected === "") root.selected = root.defaultSelection()
    }
    // Re-read through reload() so text() is never stale.
    onFileChanged: reload()
    onLoadFailed: root.angles = []
  }

  Process {
    id: listProc
    running: false
    // sysfs key masks ride along so keyboards with an embedded mouse node
    // (e.g. the Wooting 60HE) can be told apart from standalone mice; the
    // id column gives the evdev hardware identity used as the settings key.
    command: ["sh", "-c", 'hyprctl devices -j; echo ' + Model.NODES_MARKER + '; for d in /sys/class/input/event*/device; do printf "%s\\t%s\\t%s:%s:%s%s\\n" "$(cat "$d/name" 2>/dev/null)" "$(cat "$d/capabilities/key" 2>/dev/null)" "$(cat "$d/id/bustype" 2>/dev/null)" "$(cat "$d/id/vendor" 2>/dev/null)" "$(cat "$d/id/product" 2>/dev/null)" "$(u="$d/uniq"; [ -s "$u" ] && printf ":%s" "$(cat "$u")")"; done']
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      root.mice = Model.parseDeviceDump(listOut.text)
      root.syncEntries()
      if (root.selected === "") root.selected = root.defaultSelection()
    }
  }

  // Mice are unplugged and replugged while the panel sits open.
  Timer {
    interval: 2000
    repeat: true
    running: root.opened
    onTriggered: root.refreshDevices()
  }

  Process {
    id: evalProc
    running: false
    command: ["hyprctl", "eval", "hl.device({})"]
    stdout: StdioCollector { id: evalOut; waitForEnd: true }
    stderr: StdioCollector { id: evalErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.evalQueue = root.evalQueue.slice(1)
      root.noteError(String(evalOut.text || "") + String(evalErr.text || ""), exitCode)
      root.runNextEval()
    }
  }

  Process {
    id: saveProc
    running: false
    command: ["true"]
    stdout: StdioCollector { id: saveOut; waitForEnd: true }
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.noteError(String(saveOut.text || "") + String(saveErr.text || ""), exitCode)
    }
  }


  IpcHandler {
    target: "io.github.kaz.omarchy-mouse-angle"
    function open(): string { root.open(""); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.opened ? root.dismiss() : root.open(""); return "ok" }
    function query(): string { return root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "kaz-mouse-angle"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    readonly property int pad: Style.space(16)
    readonly property int contentWidth: Style.space(380)

    Rectangle {
      anchors.fill: parent
      // Fixed near-black regardless of theme, like the other scrim panels,
      // so the card keeps its contrast on any wallpaper.
      color: Qt.rgba(0, 0, 0, 0.78)

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }

      BorderSurface {
        id: card
        width: card.borderLeft + panel.pad + panel.contentWidth + panel.pad + card.borderRight
        height: card.borderTop + panel.pad + column.implicitHeight + panel.pad + card.borderBottom
        anchors.centerIn: parent
        color: Util.alpha(Color.popups.background, 0.97)
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius

        PanelKeyCatcher {
          id: keyCatcher
          anchors.fill: parent
          onMoveRequested: function(dx, dy) {
            if (dx !== 0) root.nudge(dx)
            else if (dy !== 0) root.nudge(-dy * root.coarseStep)
          }
          onCloseRequested: root.dismiss()
          onTabRequested: function(direction) { root.switchRow(direction) }

          Column {
            id: column
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: card.borderLeft + panel.pad
            anchors.rightMargin: card.borderRight + panel.pad
            anchors.topMargin: card.borderTop + panel.pad
            spacing: Style.space(14)

            Item {
              width: parent.width
              implicitHeight: Math.max(heroLabels.implicitHeight, heroIcon.height, heroAngle.implicitHeight)

              MouseIcon {
                id: heroIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                iconSize: Style.font.title * 1.6
                color: root.fg
                innerColor: Color.popups.background
                rotation: Model.signed(root.rotation)
              }

              Column {
                id: heroLabels
                anchors.left: heroIcon.right
                anchors.leftMargin: Style.space(12)
                anchors.right: heroAngle.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: root.selectedName() !== "" ? Model.prettyName(root.selectedName()) : "No mouse detected"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: Model.describe(root.rotation).toUpperCase()
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Text {
                id: heroAngle
                textFormat: Text.PlainText
                text: Model.label(root.rotation)
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "MOUSE"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.rows

                Item {
                  required property var modelData
                  width: column.width
                  implicitHeight: rowButton.implicitHeight

                  Button {
                    id: rowButton
                    width: parent.width
                    text: Model.prettyName(modelData.name)
                    fontSize: Style.font.bodySmall
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                    bordered: true
                    active: root.selected === modelData.key
                    onClicked: root.selected = modelData.key
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: Model.label(modelData.rotation)
                    color: root.selected === modelData.key ? root.fg : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }

            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)
              opacity: root.selected !== "" ? 1 : 0.45

              PanelSectionHeader {
                text: "ANGLE"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Row {
                id: stepRow
                width: parent.width
                spacing: Style.space(6)
                readonly property real cellWidth: (width - spacing * (root.steps.length + 1)) / (root.steps.length + 1)

                Repeater {
                  model: root.steps

                  Button {
                    required property var modelData
                    width: stepRow.cellWidth
                    text: (modelData > 0 ? "+" : "") + modelData + "\u00b0"
                    fontSize: Style.font.bodySmall
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                    bordered: true
                    enabled: root.selected !== ""
                    onClicked: root.nudge(modelData)
                  }
                }

                Button {
                  width: stepRow.cellWidth
                  text: "0\u00b0"
                  fontSize: Style.font.bodySmall
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                  bordered: true
                  enabled: root.selected !== "" && root.rotation !== 0
                  onClicked: root.setAngle(root.selected, 0)
                }
              }

              CursorSurface {
                width: parent.width
                height: angleSlider.implicitHeight + Style.spacing.controlGap
                foreground: root.fg
                outline: true

                PanelSlider {
                  id: angleSlider
                  bar: null
                  trackColor: Util.alpha(root.fg, 0.25)
                  fillColor: root.fg
                  knobColor: root.fg
                  tickColor: Color.popups.background
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: 359
                  step: 1
                  integer: true
                  value: root.rotation
                  enabled: root.selected !== ""
                  onReleased: function(v) { root.setAngle(root.selected, v) }
                }
              }

              Text {
                textFormat: Text.PlainText
                text: root.lastError !== ""
                  ? root.lastError
                  : "clockwise degrees \u2014 353 = 7\u00b0 anticlockwise"
                color: root.lastError !== "" ? root.fg : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }
        }
      }
    }
  }
}
