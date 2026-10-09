import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar widget + popup for passpage.space. The bar shows a page glyph with
// the active-share count; the panel lists shares with copy / open / passcode
// / collaborate / delete, plus pages others invited you to edit,
// keyboard-driven like the first-party tailscale and network panels.
Panel {
  id: root
  moduleName: "space.passpage.shares"
  ipcTarget: "passpage"
  manageIpc: false

  // Cursor model: one highlight at a time across keyboard and mouse.
  property string focusSection: "header"
  property int activeIndex: 0
  property int expiredIndex: 0
  property int sharedIndex: 0
  property bool cursorActive: false

  // Inline passcode editor + confirmations own the keys while open. The
  // collab pane does not: its shortcuts (t/i/n/v) ride the normal catcher.
  property string editingSlug: ""
  property string collabSlug: ""
  property var pendingDelete: null
  property var pendingRemove: null   // { slug, title, user_id, name }
  readonly property bool overlayOpen: pendingDelete !== null || pendingRemove !== null
  readonly property bool editorOpen: editingSlug !== ""
  readonly property bool collabOpen: collabSlug !== ""

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Commons.Color.accent)
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  // No usable key (missing, unsafe, or invalid) hides share data and counts
  // entirely — nothing key-derived may look alive without a key behind it.
  readonly property bool keyUsable: !passpage.keyMissing && !passpage.keyInvalid && !passpage.keyUnsafe
  readonly property bool attention: passpage.keyMissing || passpage.keyInvalid || passpage.keyUnsafe || passpage.error !== ""
  readonly property bool showExpired: root.keyUsable && passpage.expired.length > 0
  readonly property bool showShared: root.keyUsable && passpage.sharedWithMe.length > 0
  readonly property string heroMeta: passpage.keyUnsafe
    ? "Key file is unsafe \u2014 check permissions"
    : passpage.keyInvalid ? "API key file looks invalid" : Model.heroMeta({
    keyMissing: passpage.keyMissing, error: passpage.error, loading: passpage.loading,
    activeCount: passpage.activeCount, expiredCount: passpage.expiredCount, soonCount: passpage.soonCount
  })
  readonly property string countText: passpage.loaded && root.keyUsable && passpage.activeCount > 0 ? String(passpage.activeCount) : ""
  readonly property string dashboardUrl: passpage.baseUrl + "/dashboard"
  // One wheel notch = three share rows: row padding plus the two text lines.
  readonly property int wheelStep: (Style.spacing.rowPaddingX + Style.space(38)) * 3

  function sectionLength(section) {
    if (section === "active") return passpage.active.length
    if (section === "shared") return showShared ? passpage.sharedWithMe.length : 0
    if (section === "expired") return showExpired ? passpage.expired.length : 0
    return 1
  }

  function sectionIndex(section) {
    return section === "active" ? activeIndex : section === "shared" ? sharedIndex : expiredIndex
  }

  function setSectionIndex(section, index) {
    if (section === "active") activeIndex = index
    else if (section === "shared") sharedIndex = index
    else if (section === "expired") expiredIndex = index
  }

  // Sections the cursor can visit, top to bottom.
  function cursorSections() {
    var out = ["header"]
    var all = ["active", "shared", "expired"]
    for (var i = 0; i < all.length; i++) if (sectionLength(all[i]) > 0) out.push(all[i])
    return out
  }

  function selectedShare() {
    if (focusSection === "header") return null
    var list = focusSection === "active" ? passpage.active
      : focusSection === "shared" ? passpage.sharedWithMe : passpage.expired
    return list[Math.max(0, Math.min(sectionIndex(focusSection), list.length - 1))] || null
  }

  function ensureCursor() {
    if (activeIndex >= passpage.active.length) activeIndex = Math.max(0, passpage.active.length - 1)
    if (sharedIndex >= passpage.sharedWithMe.length) sharedIndex = Math.max(0, passpage.sharedWithMe.length - 1)
    if (expiredIndex >= passpage.expired.length) expiredIndex = Math.max(0, passpage.expired.length - 1)
    if (focusSection !== "header" && sectionLength(focusSection) === 0) {
      var sections = cursorSections()
      focusSection = sections.length > 1 ? sections[1] : "header"
    }
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    var sections = cursorSections()
    var at = sections.indexOf(focusSection)
    var index = sectionIndex(focusSection)
    if (dy < 0) {
      if (focusSection !== "header" && index > 0) setSectionIndex(focusSection, index - 1)
      else if (at > 0) {
        focusSection = sections[at - 1]
        if (focusSection !== "header") setSectionIndex(focusSection, sectionLength(focusSection) - 1)
      }
    } else {
      if (focusSection !== "header" && index < sectionLength(focusSection) - 1) setSectionIndex(focusSection, index + 1)
      else if (at < sections.length - 1) {
        focusSection = sections[at + 1]
        setSectionIndex(focusSection, 0)
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

  // Expired links are dead, so copy/open only apply to live rows. A page
  // shared with you opens in its live view, where editing happens.
  function copySelected() {
    var share = selectedShare()
    if (share && (focusSection === "active" || focusSection === "shared")) passpage.copyLink(share)
  }

  function openSelected() {
    var share = selectedShare()
    if (!share) return
    if (focusSection === "active") passpage.openInBrowser(share)
    else if (focusSection === "shared") passpage.openLive(share.slug)
  }

  function toggleCollabSelected() {
    var share = selectedShare()
    if (share && focusSection === "active") toggleCollab(share)
  }

  // Pane shortcuts act on the open collab pane, wherever the cursor is.
  function collabPaneInfo() {
    var info = passpage.collabInfo
    return collabOpen && info && info.slug === collabSlug ? info : null
  }

  function toggleCollabEnabled() {
    var info = collabPaneInfo()
    if (info && passpage.collabBusy === "") passpage.setCollab(collabSlug, !info.enabled)
  }

  function copyInvite() {
    var info = collabPaneInfo()
    if (info && info.enabled) passpage.copyInvite()
  }

  function rotateInvite() {
    var info = collabPaneInfo()
    if (info && info.enabled && passpage.collabBusy === "") passpage.rotateInvite(collabSlug)
  }

  function openLiveView() {
    if (collabOpen) { passpage.openLive(collabSlug); return }
    var share = selectedShare()
    if (share && (focusSection === "shared" || (focusSection === "active" && share.collab_enabled))) passpage.openLive(share.slug)
  }

  function editPasscodeSelected() {
    var share = selectedShare()
    if (share && focusSection === "active") togglePasscodeEditor(share)
  }

  function requestDeleteSelected() {
    var share = selectedShare()
    if (share) requestDelete(share)
  }

  // One inline pane at a time: the collab pane and the passcode editor
  // replace each other.
  function toggleCollab(share) {
    if (!share || passpage.busySlug === share.slug) return
    editingSlug = ""
    collabSlug = collabSlug === share.slug ? "" : share.slug
    if (collabSlug !== "") passpage.loadCollab(collabSlug)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function closeCollab() {
    collabSlug = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function togglePasscodeEditor(share) {
    if (!share || passpage.busySlug === share.slug) return
    collabSlug = ""
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
    collabSlug = ""
    pendingDelete = share
    // Collab shares take their editors' access with them; fetch the count
    // so the confirmation can say how many people that is.
    if (share.collab_enabled) passpage.loadCollab(share.slug)
    // Default to Cancel: x → Enter must never delete without a deliberate
    // choice of the destructive option.
    confirm.selectedIndex = 0
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  function requestRemove(share, member) {
    if (!share || !member || passpage.collabBusy !== "") return
    pendingRemove = { slug: share.slug, title: Model.displayTitle(share), user_id: member.user_id, name: member.name }
    confirm.selectedIndex = 0
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  function closeConfirm() {
    pendingDelete = null
    pendingRemove = null
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
    var column = focusSection === "active" ? activeColumn : focusSection === "shared" ? sharedColumn : expiredColumn
    var index = sectionIndex(focusSection)
    if (column && index >= 0 && index < column.children.length) scrollItemIntoView(column.children[index])
  }

  function setRowCursor(section, index) {
    if (overlayOpen) return
    cursorActive = true
    focusSection = section
    setSectionIndex(section, index)
  }

  function setHeaderCursor() {
    if (overlayOpen) return
    cursorActive = true
    focusSection = "header"
  }

  function dismiss() {
    if (overlayOpen) { closeConfirm(); return }
    if (editorOpen) { cancelPasscodeEditor(); return }
    if (collabOpen) { closeCollab(); return }
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
      collabSlug = ""
      pendingDelete = null
      pendingRemove = null
    }
  }
  onActiveIndexChanged: scrollCursorIntoView()
  onExpiredIndexChanged: scrollCursorIntoView()
  onSharedIndexChanged: scrollCursorIntoView()

  Service {
    id: passpage
    settings: root.settings
    panelOpen: root.opened
    onSharesUpdated: {
      root.ensureCursor()
      if (root.collabSlug !== "") {
        var open = passpage.shareBySlug(root.collabSlug)
        if (!open || !Model.isActive(open, passpage.nowMs)) root.closeCollab()
      }
      if (root.pendingRemove && !passpage.shareBySlug(root.pendingRemove.slug)) root.closeConfirm()
      // A share can vanish under an open editor/dialog (refresh, delete
      // elsewhere) — orphaned overlay state would block keyboard input.
      if (root.editingSlug !== "" && !passpage.shareBySlug(root.editingSlug)) root.cancelPasscodeEditor()
      if (root.pendingDelete && !passpage.shareBySlug(root.pendingDelete.slug)) root.closeConfirm()
    }
    onActionFinished: function(kind, slug, ok) {
      if (ok && root.editingSlug === slug) root.cancelPasscodeEditor()
      if (root.pendingDelete && root.pendingDelete.slug === slug) root.closeConfirm()
    }
    onCollabFinished: function(kind, slug, ok) {
      if (kind === "remove" && root.pendingRemove && root.pendingRemove.slug === slug) root.closeConfirm()
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
    // Open (or close) the collab pane for one of your active shares.
    function collab(slug: string): string {
      var share = passpage.shareBySlug(slug)
      if (!share || !Model.isActive(share, passpage.nowMs)) return "not an active share"
      root.open()
      root.toggleCollab(share)
      var opened = root.collabSlug === slug
      // Opening resets the cursor; place it on the row once that has run.
      Qt.callLater(function() {
        // By slug: `active` keeps its old row objects when nothing changed,
        // so identity against a refreshed share would miss.
        for (var i = 0; i < passpage.active.length; i++) {
          if (passpage.active[i].slug === slug) { root.setRowCursor("active", i); break }
        }
        root.scrollCursorIntoView()
      })
      return opened ? "open" : "closed"
    }
    function status(): string {
      var info = passpage.collabInfo
      var collabOn = 0
      for (var i = 0; i < passpage.active.length; i++) if (passpage.active[i].collab_enabled) collabOn++
      return JSON.stringify({ loaded: passpage.loaded, active: passpage.activeCount, expired: passpage.expiredCount,
        expiringSoon: passpage.soonCount, error: passpage.error, keyMissing: passpage.keyMissing,
        keyInvalid: passpage.keyInvalid, keyUnsafe: passpage.keyUnsafe,
        collabOn: collabOn, sharedWithMe: passpage.sharedWithMe.length, collabPane: root.collabSlug,
        collabEnabled: info ? info.enabled : null, editors: info ? Model.editorsOf(info).length : null,
        collabBusy: passpage.collabBusy, collabError: passpage.collabError,
        cursor: root.cursorActive ? root.focusSection + ":" + root.sectionIndex(root.focusSection) : "" })
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
              borderSpec: Border.flat(Commons.Color.bar.background, 1)

              Text {
                anchors.centerIn: parent
                text: "!"
                color: Commons.Color.background
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
        else if (t === "s" || t === "S") root.toggleCollabSelected()
        else if (t === "v" || t === "V") root.openLiveView()
        else if (t === "t" || t === "T") root.toggleCollabEnabled()
        else if (t === "i" || t === "I") root.copyInvite()
        else if (t === "n" || t === "N") root.rotateInvite()
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

        // Flickable's built-in wheel handling is velocity-based: a notch
        // starts a tiny flick that decelerates at once, so a long share list
        // crawls compared to the rest of the desktop. Drive contentY directly
        // instead — one notch moves three rows, touchpads keep their own
        // pixel deltas, and Model clamps to the scrollable range.
        WheelHandler {
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: function(event) {
            panelFlick.cancelFlick()
            panelFlick.contentY = Model.wheelContentY(panelFlick.contentY, panelFlick.contentHeight,
                                                      panelFlick.height, event.pixelDelta.y,
                                                      event.angleDelta.y, root.wheelStep)
            event.accepted = true
          }
        }

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
            textFormat: Text.PlainText
            color: passpage.actionError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          // Setup guidance when there is no key to use.
          CursorSurface {
            visible: !root.keyUsable
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
                text: passpage.keyUnsafe
                  ? "The key file at ~/.config/passpage/key is unsafe to use"
                  : passpage.keyInvalid
                    ? "The key file at ~/.config/passpage/key is not a valid API key"
                    : "No API key at ~/.config/passpage/key"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                text: passpage.keyUnsafe
                  ? "Key file permissions are too open \u2014 run chmod 600 ~/.config/passpage/key. It must be a regular file you own, not a symlink."
                  : "Create a key in the passpage dashboard, then save it to that file (mode 600). The panel picks it up automatically."
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
            visible: root.keyUsable
            foreground: root.foreground
          }

          Column {
            visible: root.keyUsable
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
              textFormat: Text.PlainText
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
                // Delegates only exist while the panel is open — a closed
                // panel costs nothing even against a hostile 500-share list.
                // Bar count/badge stay live off Service state regardless.
                model: root.opened ? passpage.active : []
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
            visible: root.showShared
            foreground: root.foreground
          }

          Column {
            visible: root.showShared
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SHARED WITH YOU"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: sharedColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.opened ? passpage.sharedWithMe : []
                SharedRow {
                  required property var modelData
                  required property int index
                  width: sharedColumn.width
                  item: modelData
                  rowIndex: index
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
                model: root.opened ? passpage.expired : []
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

        // Takes hover from the row buttons underneath, so the tooltip of the
        // button that opened the dialog doesn't stay drawn over it.
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        ConfirmDialog {
          id: confirm
          anchors.fill: parent
          opened: root.overlayOpen
          // displayTitle is sanitized at ingestion; the extra pass keeps this
          // kit boundary (AutoText-capable) safe against future regressions.
          message: root.pendingRemove
            ? "Remove " + Model.sanitizeText(root.pendingRemove.name, 80) + " from “"
              + Model.sanitizeText(root.pendingRemove.title, 140) + "”? They lose edit access and the invite link is replaced."
            : root.pendingDelete ? Model.deleteMessage(root.pendingDelete, passpage.collabInfo) : ""
          confirmText: root.pendingRemove ? "Remove" : "Delete"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onCanceled: root.closeConfirm()
          onConfirmed: {
            if (root.pendingRemove) passpage.removeMember(root.pendingRemove.slug, root.pendingRemove.user_id)
            else passpage.deleteShare(root.pendingDelete)
          }
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
    readonly property bool collabOpen: root.collabSlug === slug && isActive
    readonly property bool collabOn: !!(share && share.collab_enabled)
    readonly property bool isBusy: passpage.busySlug === slug
    readonly property bool copied: passpage.copiedSlug === slug
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
      + (collabOpen ? collabPane.implicitHeight + Style.space(14) : 0)

    Behavior on implicitHeight { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setRowCursor(row.section, row.rowIndex)
      onClicked: if (!row.editing && !row.collabOpen && row.isActive) passpage.copyLink(row.share)
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
        id: leadingIcon
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
          textFormat: Text.PlainText
          color: row.textColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: row.detail
          textFormat: Text.PlainText
          color: row.soon ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: row.isActive
        iconText: row.copied ? "󰄬" : "󰆏"
        tooltipText: row.copied ? "Copied" : "Copy link (c)"
        foreground: row.copied ? Commons.Color.accent : root.foreground
        hoverColor: row.copied ? Commons.Color.accent : root.foreground
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

      // Accent while collaboration is on, so it reads at a glance.
      PanelActionButton {
        visible: row.isActive
        iconText: row.collabOn ? "󰀎" : "󰀏"
        tooltipText: row.collabOn ? "Collaboration on \u2014 invite, editors (s)" : "Collaborate (s)"
        foreground: row.collabOn ? Commons.Color.accent : root.foreground
        hoverColor: row.collabOn ? Commons.Color.accent : root.foreground
        fontFamily: root.fontFamily
        hasCursor: row.collabOpen
        enabled: !row.isBusy
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.toggleCollab(row.share)
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
        maximumLength: 256
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

    // Inline collaboration pane: on/off, invite link, editors. Mirrors the
    // dashboard's dialog; the live view itself stays in the browser.
    Column {
      id: collabPane
      visible: row.collabOpen
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: rowContent.bottom
      anchors.topMargin: Style.space(10)
      // Indented to the title column so the pane reads as part of this row.
      anchors.leftMargin: Style.space(10) + leadingIcon.width + Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      readonly property var info: passpage.collabInfo && passpage.collabInfo.slug === row.slug ? passpage.collabInfo : null
      readonly property bool on: info ? info.enabled : row.collabOn
      readonly property bool busy: passpage.collabBusy !== "" || !info
      readonly property var editors: info ? Model.editorsOf(info) : []

      RowLayout {
        width: parent.width
        spacing: Style.space(10)

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            Layout.fillWidth: true
            text: collabPane.on ? "Collaboration is on" : "Collaboration is off"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
          Text {
            Layout.fillWidth: true
            text: collabPane.on
              ? "Editors change files with their own agents. Every change can be restored."
              : "Invite teammates to edit with their agents. The view link stays view-only."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        ToggleSwitch {
          Layout.alignment: Qt.AlignTop
          Layout.rightMargin: Style.space(4)
          cursorRing: false
          checked: collabPane.on
          busy: collabPane.busy
          opacity: collabPane.busy ? 0.6 : 1.0
          foreground: root.foreground
          onToggled: root.toggleCollabEnabled()
        }
      }

      // Invite link. Shown masked: it is a join credential, and panels end
      // up in screenshots and screen shares. Copy puts the real one on the
      // clipboard.
      RowLayout {
        visible: collabPane.on && collabPane.info !== null && collabPane.info.invite_url !== ""
        width: parent.width
        spacing: Style.space(4)

        Text {
          text: "Invite"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }
        Text {
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(4)
          text: collabPane.info ? Model.maskedInvite(collabPane.info.invite_url) : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
          Layout.alignment: Qt.AlignVCenter
        }
        PanelActionButton {
          iconText: "󰆏"
          tooltipText: "Copy invite link (i)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !collabPane.busy
          Layout.alignment: Qt.AlignVCenter
          onClicked: root.copyInvite()
        }
        PanelActionButton {
          iconText: "󰑐"
          tooltipText: "New invite link \u2014 the old one stops working (n)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !collabPane.busy
          Layout.alignment: Qt.AlignVCenter
          onClicked: root.rotateInvite()
        }
        PanelActionButton {
          iconText: "󰖟"
          tooltipText: "Open live view (v)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          Layout.alignment: Qt.AlignVCenter
          onClicked: passpage.openLive(row.slug)
        }
      }

      Text {
        visible: collabPane.on && collabPane.info !== null
        width: parent.width
        text: Model.editorsText(collabPane.info)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: collabPane.on ? collabPane.editors : []
        RowLayout {
          required property var modelData
          width: collabPane.width
          spacing: Style.space(8)

          Text {
            text: "󰀄"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
            Layout.alignment: Qt.AlignVCenter
          }
          Text {
            Layout.fillWidth: true
            text: modelData.name
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            Layout.alignment: Qt.AlignVCenter
          }
          PanelActionButton {
            iconText: "󰀕"
            tooltipText: "Remove editor"
            foreground: root.foreground
            hoverColor: root.urgent
            fontFamily: root.fontFamily
            enabled: !collabPane.busy
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.requestRemove(row.share, modelData)
          }
        }
      }

      Text {
        visible: !collabPane.info && passpage.collabError === ""
        width: parent.width
        text: "Loading collaboration settings\u2026"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: passpage.collabError !== "" && passpage.collabWant === row.slug
        width: parent.width
        text: passpage.collabError
        textFormat: Text.PlainText
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  // A collab page someone else owns and invited you to edit. Not yours, so
  // no passcode / collaborate / delete: copy its link or open the live view.
  component SharedRow: CursorSurface {
    id: shared
    property var item: null
    property int rowIndex: 0
    readonly property bool copied: item ? passpage.copiedSlug === item.slug : false

    hasCursor: root.cursorActive && root.focusSection === "shared" && root.sharedIndex === rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: Style.spacing.rowPaddingX + sharedContent.implicitHeight

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setRowCursor("shared", shared.rowIndex)
      onClicked: passpage.copyLink(shared.item)
    }

    RowLayout {
      id: sharedContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.rowPaddingX / 2
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: "󰀎"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: Model.displayTitle(shared.item)
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          text: Model.sharedDetail(shared.item)
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: shared.copied ? "󰄬" : "󰆏"
        tooltipText: shared.copied ? "Copied" : "Copy link (c)"
        foreground: shared.copied ? Commons.Color.accent : root.foreground
        hoverColor: shared.copied ? Commons.Color.accent : root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: passpage.copyLink(shared.item)
      }

      PanelActionButton {
        iconText: "󰖟"
        tooltipText: "Open live view (o)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: passpage.openLive(shared.item.slug)
      }
    }
  }
}
