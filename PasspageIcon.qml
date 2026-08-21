import QtQuick
import qs.Commons
import qs.Ui

// Native rendering of the passpage stamp mark (the site's LogoMark.tsx):
// a slightly tilted frame, a faint inner inset, and "PP". Drawn with
// rectangles and text rather than an SVG so it stays crisp at bar size and
// takes the theme foreground like every other bar glyph.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool warning: false
  property bool showInset: iconSize >= 18
  // Two tilted letters turn to mush under ~16px; a single P keeps the mark readable in the bar.
  readonly property bool compact: iconSize < 16
  // Bar glyphs around us are upright, solid, ~13px shapes. In compact mode
  // drop the tilt and thicken the frame so the mark carries the same weight.
  readonly property real tilt: compact ? 0 : -9

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real frameWidth: compact ? iconSize * 1.0 : iconSize * 0.92
  readonly property real frameHeight: compact ? iconSize * 0.82 : iconSize * 0.74
  readonly property real stroke: compact ? Math.max(1.5, iconSize * 0.13) : Math.max(1, iconSize * 0.085)

  Item {
    anchors.centerIn: parent
    width: root.frameWidth
    height: root.frameHeight
    rotation: root.tilt

    Rectangle {
      anchors.fill: parent
      color: "transparent"
      border.width: root.stroke
      border.color: root.color
      radius: Math.max(1, root.iconSize * 0.06)
      antialiasing: true
    }

    Rectangle {
      visible: root.showInset
      anchors.fill: parent
      anchors.margins: root.stroke * 2.2
      color: "transparent"
      border.width: Math.max(1, root.stroke * 0.5)
      border.color: root.color
      opacity: 0.4
      antialiasing: true
    }

    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: root.iconSize * 0.02
      text: root.compact ? "P" : "PP"
      color: root.color
      font.family: Style.font.family
      font.pixelSize: Math.max(6, root.iconSize * (root.compact ? 0.62 : 0.42))
      font.bold: true
      font.letterSpacing: root.compact ? 0 : root.iconSize * 0.04
      renderType: Text.QtRendering
    }
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: -width * 0.15
    anchors.bottomMargin: -width * 0.15
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
