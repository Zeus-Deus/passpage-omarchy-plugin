import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget + popup for passpage.space. The bar shows a page glyph with
// the active-share count; the panel lists shares with copy / open / passcode
// / delete, keyboard-driven like the first-party tailscale and network panels.
Panel {
  id: root
  moduleName: "space.passpage.shares"
  ipcTarget: "passpage"
  manageIpc: false

  // Cursor model: one highlight at a time across keyboard and mouse.
  property string focusSection: "header"
  property int activeIndex: 0
  property int expiredIndex: 0
  property bool cursorActive: false

  // Inline passcode editor + delete confirmation own the keys while open.
  property string editingSlug: ""
  property var pendingDelete: null
  readonly property bool overlayOpen: pendingDelete !== null
  readonly property bool editorOpen: editingSlug !== ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  readonly property bool attention: passpage.keyMissing || passpage.error !== ""
  readonly property bool showExpired: passpage.expired.length > 0
  readonly property string heroMeta: Model.heroMeta({
    keyMissing: passpage.keyMissing, error: passpage.error, loading: passpage.loading,
    activeCount: passpage.activeCount, expiredCount: passpage.expiredCount, soonCount: passpage.soonCount
  })
  readonly property string countText: passpage.loaded && !passpage.keyMissing && passpage.activeCount > 0 ? String(passpage.activeCount) : ""
  readonly property string dashboardUrl: passpage.baseUrl + "/dashboard"

  function selectedShare() {
    if (focusSection === "active") return passpage.active[Math.max(0, Math.min(activeIndex, passpage.active.length - 1))] || null
    if (focusSection === "expired") return passpage.expired[Math.max(0, Math.min(expiredIndex, passpage.expired.length - 1))] || null
    return null
  }

  function ensureCursor() {
    if (activeIndex >= passpage.active.length) activeIndex = Math.max(0, passpage.active.length - 1)
    if (expiredIndex >= passpage.expired.length) expiredIndex = Math.max(0, passpage.expired.length - 1)
    if (focusSection === "active" && passpage.active.length === 0) focusSection = showExpired ? "expired" : "header"
    if (focusSection === "expired" && !showExpired) focusSection = passpage.active.length > 0 ? "active" : "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (focusSection === "header") {
      if (dy > 0) {
        if (passpage.active.length > 0) focusSection = "active"
        else if (showExpired) focusSection = "expired"
      }
    } else if (focusSection === "active") {
      if (dy < 0) {
        if (activeIndex <= 0) focusSection = "header"
        else activeIndex--
      } else if (activeIndex < passpage.active.length - 1) {
        activeIndex++
      } else if (showExpired) {
        focusSection = "expired"
        expiredIndex = 0
      }
    } else if (focusSection === "expired") {
      if (dy < 0) {
        if (expiredIndex <= 0) focusSection = passpage.active.length > 0 ? "active" : "header"
        else expiredIndex--
      } else if (expiredIndex < passpage.expired.length - 1) {
        expiredIndex++
      }
    }
    ensureCursor()
    scrollCursorIntoView()
  }

  // Enter on a row copies the link — the thing you almost always want.
  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") passpage.refresh()
    else copySelected()
  }

  // Expired links are dead, so copy/open only apply to active rows.
  function copySelected() {
    var share = selectedShare()
    if (share && focusSection === "active") passpage.copyLink(share)
  }

  function openSelected() {
    var share = selectedShare()
    if (share && focusSection === "active") passpage.openInBrowser(share)
  }

  function editPasscodeSelected() {
    var share = selectedShare()
    if (share && focusSection === "active") togglePasscodeEditor(share)
  }

  function requestDeleteSelected() {
    var share = selectedShare()
    if (share) requestDelete(share)
  }

  function togglePasscodeEditor(share) {
    if (!share || passpage.busySlug === share.slug) return
    editingSlug = editingSlug === share.slug ? "" : share.slug
    if (editingSlug === "") Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cancelPasscodeEditor() {
    editingSlug = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function requestDelete(share) {
    if (!share || passpage.busySlug !== "") return
    editingSlug = ""
    pendingDelete = share
    confirm.selectedIndex = 1
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  function closeConfirm() {
    pendingDelete = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "header") { if (panelFlick) panelFlick.contentY = 0; return }
    var column = focusSection === "active" ? activeColumn : expiredColumn
    var index = focusSection === "active" ? activeIndex : expiredIndex
    if (column && index >= 0 && index < column.children.length) scrollItemIntoView(column.children[index])
  }

  function setRowCursor(section, index) {
    if (overlayOpen) return
    cursorActive = true
    focusSection = section
    if (section === "active") activeIndex = index
    else expiredIndex = index
  }

  function setHeaderCursor() {
    if (overlayOpen) return
    cursorActive = true
    focusSection = "header"
  }

  function dismiss() {
    if (overlayOpen) { closeConfirm(); return }
    if (editorOpen) { cancelPasscodeEditor(); return }
    close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      focusSection = "header"
      if (panelFlick) panelFlick.contentY = 0
      passpage.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      editingSlug = ""
      pendingDelete = null
    }
  }
  onActiveIndexChanged: scrollCursorIntoView()
  onExpiredIndexChanged: scrollCursorIntoView()

  Service {
    id: passpage
    settings: root.settings
    onSharesUpdated: root.ensureCursor()
    onActionFinished: function(kind, slug, ok) {
      if (ok && root.editingSlug === slug) root.cancelPasscodeEditor()
      if (root.pendingDelete && root.pendingDelete.slug === slug) root.closeConfirm()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { passpage.refresh(); return "ok" }
    function status(): string {
      return JSON.stringify({ active: passpage.activeCount, expired: passpage.expiredCount,
        expiringSoon: passpage.soonCount, error: passpage.error, keyMissing: passpage.keyMissing })
    }
  }

  // Ids inside the icon Component are not reachable from the button, so the
  // slot width comes from measuring the count text here.
  TextMetrics {
    id: countMetrics
    text: root.countText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.heroMeta
    slotSize: Style.bar.iconSlot + (root.countText !== "" ? countMetrics.width + Style.space(3) : 0)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) passpage.refresh()
      else root.toggle()
    }
    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(3)

          // A plain Nerd Font page glyph: at bar size every neighbour is a
          // solid 13px icon, and the brand stamp can't read at that scale.
          // The tilted stamp lives in the panel hero instead.
          Item {
            anchors.verticalCenter: parent.verticalCenter
            width: barGlyph.implicitWidth
            height: barGlyph.implicitHeight

            Text {
              id: barGlyph
              text: "󰈙"
              color: root.countText !== "" || root.attention ? root.barForeground : Qt.darker(root.barForeground, 1.55)
              font.family: root.fontFamily
              font.pixelSize: Style.bar.iconFont
              renderType: Text.NativeRendering
            }

            BorderSurface {
              visible: root.attention
              width: Math.max(7, barGlyph.implicitHeight * 0.5)
              height: width
              radius: width / 2
              color: root.urgent
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.rightMargin: -width * 0.25
              anchors.bottomMargin: -width * 0.1
              borderSpec: Border.flat(Color.bar.background, 1)

              Text {
                anchors.centerIn: parent
                text: "!"
                color: Color.background
                font.family: root.fontFamily
                font.pixelSize: Math.max(6, parent.height * 0.72)
                font.bold: true
              }
            }
          }

          Text {
            visible: root.countText !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.countText
            color: root.barForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editorOpen || root.overlayOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; if (dy >= 0) return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.dismiss()
      onDeleteRequested: if (root.cursorActive) root.requestDeleteSelected()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") passpage.refresh()
        else if (t === "c" || t === "C") root.copySelected()
        else if (t === "o" || t === "O") root.openSelected()
        else if (t === "p" || t === "P") root.editPasscodeSelected()
        else if (t === "d" || t === "D") passpage.openInBrowser({ url: root.dashboardUrl })
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: "Passpage"
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: passpage.activeCount > 0 || root.attention ? 1.0 : 0.5
              iconComponent: Component {
                PasspageIcon {
                  iconSize: Style.font.display
                  color: root.foreground
                  badgeColor: root.urgent
                  warning: root.attention
                }
              }
              trailingControl: Component {
                PanelActionButton {
                  id: refreshButton
                  iconText: "󰑐"
                  tooltipText: "Refresh (r)"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  hasCursor: header.ringVisible
                  enabled: !passpage.loading && !passpage.keyMissing
                  onHovered: function(on) { if (on) header.focusHero() }
                  onClicked: passpage.refresh()

                  NumberAnimation on rotation {
                    running: passpage.loading
                    from: 0; to: 360; duration: 900
                    loops: Animation.Infinite
                  }
                  onRotationChanged: if (!passpage.loading && rotation !== 0) rotation = 0
                }
              }
            }
          }

          Text {
            visible: passpage.actionStatus !== "" || passpage.actionError !== ""
            width: parent.width
            text: passpage.actionError !== "" ? passpage.actionError : passpage.actionStatus
            color: passpage.actionError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          // Setup guidance when there is no key to use.
          CursorSurface {
            visible: passpage.keyMissing
            width: parent.width
            implicitHeight: setupInner.implicitHeight + Style.spacing.rowPaddingX * 2
            foreground: root.foreground

            Column {
              id: setupInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: "No API key at ~/.config/passpage/key"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                text: "Create a key in the passpage dashboard, then save it to that file (mode 600). The panel picks it up automatically."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Button {
                text: "Open dashboard"
                iconText: "󰖟"
                foreground: root.foreground
                onClicked: passpage.openInBrowser({ url: root.dashboardUrl })
              }
            }
          }

          PanelSeparator {
            visible: !passpage.keyMissing
            foreground: root.foreground
          }

          Column {
            visible: !passpage.keyMissing
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "ACTIVE SHARES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: passpage.loaded && passpage.active.length === 0
              width: parent.width
              text: "Nothing is live right now. Publish with the passpage API or CLI and it shows up here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: !passpage.loaded && passpage.error !== ""
              width: parent.width
              text: passpage.error
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: activeColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: passpage.active
                ShareRow {
                  required property var modelData
                  required property int index
                  width: activeColumn.width
                  share: modelData
                  rowIndex: index
                  section: "active"
                }
              }
            }
          }

          PanelSeparator {
            visible: root.showExpired
            foreground: root.foreground
          }

          Column {
            visible: root.showExpired
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "EXPIRED"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "Links are dead; passpage sweeps these after a week."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              id: expiredColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: passpage.expired
                ShareRow {
                  required property var modelData
                  required property int index
                  width: expiredColumn.width
                  share: modelData
                  rowIndex: index
                  section: "expired"
                }
              }
            }
          }
        }
      }

      // Delete confirmation. Keys route here while it is open; the catcher
      // above is blocked so j/k/x cannot move the cursor underneath.
      Item {
        id: confirmKeys
        anchors.fill: parent
        visible: root.overlayOpen
        focus: visible
        Keys.onPressed: function(event) { if (confirm.handleKey(event)) event.accepted = true }

        ConfirmDialog {
          id: confirm
          anchors.fill: parent
          opened: root.overlayOpen
          message: root.pendingDelete
            ? "Delete “" + Model.displayTitle(root.pendingDelete) + "”? The link stops working immediately."
            : ""
          confirmText: "Delete"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onCanceled: root.closeConfirm()
          onConfirmed: passpage.deleteShare(root.pendingDelete)
        }
      }
    }
  }

  component ShareRow: CursorSurface {
    id: row
    property var share: null
    property int rowIndex: 0
    property string section: "active"
    readonly property bool isActive: section === "active"
    readonly property string slug: share ? String(share.slug || "") : ""
    readonly property bool editing: root.editingSlug === slug
    readonly property bool isBusy: passpage.busySlug === slug
    readonly property bool soon: share ? Model.isExpiringSoon(share, passpage.nowMs) : false
    readonly property string title: Model.displayTitle(share)
    readonly property string detail: share ? Model.rowDetail(share, passpage.nowMs) : ""
    readonly property color textColor: isActive ? root.foreground : root.dim

    hasCursor: root.cursorActive && root.focusSection === section
      && (isActive ? root.activeIndex : root.expiredIndex) === rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    opacity: isBusy ? 0.55 : 1.0

    implicitHeight: Style.spacing.rowPaddingX + rowContent.implicitHeight
      + (editing ? editor.implicitHeight + Style.space(8) : 0)

    Behavior on implicitHeight { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setRowCursor(row.section, row.rowIndex)
      onClicked: if (!row.editing && row.isActive) passpage.copyLink(row.share)
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.rowPaddingX / 2
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: row.share && row.share.has_passcode ? "󰌾" : "󰈙"
        color: row.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: row.title
          color: row.textColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: row.detail
          color: row.soon ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: row.isActive
        iconText: "󰆏"
        tooltipText: "Copy link (c)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !row.isBusy
        Layout.alignment: Qt.AlignVCenter
        onClicked: passpage.copyLink(row.share)
      }

      PanelActionButton {
        visible: row.isActive
        iconText: "󰖟"
        tooltipText: "Open in browser (o)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !row.isBusy
        Layout.alignment: Qt.AlignVCenter
        onClicked: passpage.openInBrowser(row.share)
      }

      PanelActionButton {
        visible: row.isActive
        iconText: row.share && row.share.has_passcode ? "󰌾" : "󰌿"
        tooltipText: row.share && row.share.has_passcode ? "Change or remove passcode (p)" : "Set passcode (p)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        hasCursor: row.editing
        enabled: !row.isBusy
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.togglePasscodeEditor(row.share)
      }

      PanelActionButton {
        iconText: "󰆴"
        tooltipText: "Delete (x)"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        enabled: !row.isBusy
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.requestDelete(row.share)
      }
    }

    // Inline passcode editor, expands under the row like the wifi passphrase
    // prompt. Enter applies, Esc cancels, empty removes the passcode.
    Item {
      id: editor
      visible: row.editing
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: rowContent.bottom
      anchors.topMargin: Style.space(8)
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      implicitHeight: passField.implicitHeight

      TextField {
        id: passField
        anchors.left: parent.left
        anchors.right: applyButton.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        password: true
        placeholderText: row.share && row.share.has_passcode ? "New passcode — leave empty to remove" : "Passcode"
        foreground: root.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        enabled: !row.isBusy
        // Enter with nothing typed on an unprotected share is a no-op, not a "remove".
        onAccepted: {
          if (text === "" && !(row.share && row.share.has_passcode)) root.cancelPasscodeEditor()
          else passpage.setPasscode(row.share, text)
        }
        Keys.onEscapePressed: root.cancelPasscodeEditor()
        onVisibleChanged: {
          if (visible) Qt.callLater(forceActiveFocus)
          else text = ""
        }
      }

      PanelActionButton {
        id: applyButton
        anchors.right: cancelButton.left
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰄬"
        tooltipText: passField.text === "" && row.share && row.share.has_passcode ? "Remove passcode" : "Apply"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !row.isBusy && (passField.text !== "" || (row.share && row.share.has_passcode))
        onClicked: passpage.setPasscode(row.share, passField.text)
      }

      PanelActionButton {
        id: cancelButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅖"
        tooltipText: "Cancel"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.cancelPasscodeEditor()
      }
    }
  }
}
