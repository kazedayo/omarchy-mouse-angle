import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Per-mouse sensor angle. Hyprland applies it through libinput's device
// rotation, so it works on any mouse and is independent of firmware.
// Live changes go through `hyprctl eval hl.device(...)`; the same value is
// mirrored into a generated Lua file so it survives Hyprland restarts.
Panel {
  id: root
  moduleName: "io.github.kaz.omarchy-mouse-angle"
  ipcTarget: "io.github.kaz.omarchy-mouse-angle"

  property string angleFile: (Quickshell.env("HOME") || "") + "/.config/hypr/mouse-angle.lua"
  property var angles: []        // persisted: [{ name, rotation }]
  property var mice: []          // currently connected pointer devices
  property string selected: ""
  property string lastError: ""
  property int fineStep: 1
  property int coarseStep: 5

  readonly property color dim: Qt.darker(barForeground, 1.4)
  readonly property int rotation: rotationOf(selected)
  readonly property var rows: rowList()
  readonly property var steps: [-coarseStep, -fineStep, fineStep, coarseStep]

  function rotationOf(name) {
    var e = Model.find(root.angles, name)
    return e ? e.rotation : 0
  }

  // Connected mice first, then remembered names (e.g. an unplugged mouse).
  function rowList() {
    var out = [], i
    for (i = 0; i < root.mice.length; i++)
      out.push({ name: root.mice[i], rotation: root.rotationOf(root.mice[i]) })
    for (i = 0; i < root.angles.length; i++)
      if (root.mice.indexOf(root.angles[i].name) === -1)
        out.push({ name: root.angles[i].name, rotation: root.angles[i].rotation })
    return out
  }

  // Prefer a device that is actually rotated, so the bar shows the mouse you
  // tuned rather than whichever one Hyprland happened to list first.
  function defaultSelection() {
    var i
    for (i = 0; i < root.angles.length; i++)
      if (root.angles[i].rotation !== 0) return root.angles[i].name
    return root.mice.length > 0 ? root.mice[0] : ""
  }

  function setAngle(name, deg) {
    if (!name) return
    if (!Model.isSafeName(name)) {
      root.lastError = "Unusable device name: " + name
      return
    }
    var next = Model.normalize(deg)
    root.angles = Model.upsert(root.angles, name, next)
    root.saveAngleFile()
    root.applyAngle(name, next)
  }

  function nudge(delta) {
    if (root.selected) root.setAngle(root.selected, root.rotation + delta)
  }

  function applyAngle(name, deg) {
    evalProc.command = ["hyprctl", "eval", 'hl.device({ name = "' + name + '", rotation = ' + deg + ' })']
    evalProc.running = true
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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
    // (e.g. the Wooting 60HE) can be told apart from standalone mice.
    command: ["sh", "-c", 'hyprctl devices -j; echo ' + Model.NODES_MARKER + '; for d in /sys/class/input/event*/device; do printf "%s\\t%s\\n" "$(cat "$d/name" 2>/dev/null)" "$(cat "$d/capabilities/key" 2>/dev/null)"; done']
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      root.mice = Model.parseDeviceDump(listOut.text)
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
      root.noteError(String(evalOut.text || "") + String(evalErr.text || ""), exitCode)
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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.selected !== ""
      ? Model.prettyName(root.selected) + " \u2014 " + Model.describe(root.rotation)
      : "No mouse detected"
    iconComponent: Component {
      Item {
        // Tilted by the signed angle (QML rotation is clockwise, like
        // libinput's degrees) — the exact value lives in the tooltip/panel.
        MouseIcon {
          anchors.centerIn: parent
          iconSize: parent.width
          color: root.selected !== "" ? root.barForeground : root.dim
          innerColor: root.bar ? root.bar.background : Color.background
          rotation: Model.signed(root.rotation)
        }
      }
    }
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.nudge(dx)
        else if (dy !== 0) root.nudge(-dy * root.coarseStep)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroLabels.implicitHeight, heroAngle.implicitHeight)

          Column {
            id: heroLabels
            anchors.left: parent.left
            anchors.right: heroAngle.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.selected !== "" ? Model.prettyName(root.selected) : "No mouse detected"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: Model.describe(root.rotation).toUpperCase()
              color: root.dim
              font.family: root.bar.fontFamily
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
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "MOUSE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
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
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.selected === modelData.name
                onClicked: root.selected = modelData.name
              }

              Text {
                textFormat: Text.PlainText
                text: Model.label(modelData.rotation)
                color: root.selected === modelData.name ? root.bar.foreground : root.dim
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)
          opacity: root.selected !== "" ? 1 : 0.45

          PanelSectionHeader {
            text: "ANGLE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
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
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
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
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
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
            foreground: root.bar.foreground
            outline: true

            PanelSlider {
              id: angleSlider
              bar: root.bar
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
            color: root.lastError !== "" ? root.bar.foreground : root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
        }
      }
    }
  }
}
