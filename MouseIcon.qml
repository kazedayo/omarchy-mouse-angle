import QtQuick
import qs.Commons

// Mouse seen from above: capsule body with a wheel notch. The caller tilts
// it by the sensor angle, so the bar shows "which way this mouse points"
// without printing a number.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color innerColor: Color.background

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real s: iconSize

  Rectangle {
    width: root.s * 0.52
    height: root.s * 0.94
    radius: width / 2
    color: root.color
    anchors.centerIn: parent
  }

  Rectangle {
    width: Math.max(1, root.s * 0.09)
    height: root.s * 0.24
    radius: width / 2
    color: root.innerColor
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.s * 0.10
  }
}
