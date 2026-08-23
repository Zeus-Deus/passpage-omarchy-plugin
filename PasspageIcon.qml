import QtQuick
import qs.Commons
import qs.Ui

// Native rendering of the passpage stamp mark (the site's LogoMark.tsx):
// a slightly tilted frame, a faint inner inset, and "PP". Drawn with
// rectangles and text rather than an SVG so it takes the theme foreground.
// Used in the panel hero; the bar uses a plain Nerd Font page glyph because
// this mark cannot read at 13px.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool warning: false
  property bool showInset: iconSize >= 18

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real frameWidth: iconSize * 0.92
  readonly property real frameHeight: iconSize * 0.74
  readonly property real stroke: Math.max(1, iconSize * 0.085)

  Item {
    anchors.centerIn: parent
    width: root.frameWidth
    height: root.frameHeight
    rotation: -9

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
      text: "PP"
      color: root.color
      font.family: Style.font.family
      font.pixelSize: Math.max(6, root.iconSize * 0.42)
      font.bold: true
      font.letterSpacing: root.iconSize * 0.04
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
