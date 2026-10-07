import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import qs.Commons

// Per-screen layer that hosts all whimsy desktop widgets. One full-screen
// bottom-layer surface per monitor; every widget card is a plain child placed
// at root coordinates, so many widgets share a single surface (full-screen
// surfaces would stack on the bottom layer and only the top one could be
// hovered or dragged). Renders behind all normal windows, above the wallpaper.
PanelWindow {
  id: layer

  required property var service
  required property string screenName
  property var cards: ({})
  // Which card currently shows its chrome (dotted box, resize dot, remove ✕).
  // Clicking empty desktop clears it; clicking a card selects it.
  property string selectedId: ""
  // Set true by editable widgets (e.g. StickyNote) while keyboard is needed.
  property bool keyboardActive: false
  property Component cardComponent: Qt.createComponent(
    Qt.resolvedUrl("DesktopCard.qml"), Component.PreferSynchronous)

  visible: true
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  screen: service ? service.screenByName(screenName) : null

  WlrLayershell.namespace: "whimsy-widget"
  WlrLayershell.layer: WlrLayer.Bottom
  WlrLayershell.keyboardFocus: layer.keyboardActive ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

  // ---- wallpaper-synced wipe ----------------------------------------------
  // Mirrors the background plugin's reveal (same slanted wipe, 420ms
  // InOutCubic) so a layout change reads as part of the wallpaper change.
  // Leaving cards live in leaveGroup (visible outside the wipe), entering
  // cards in enterGroup (visible inside it); shared cards glide in place.
  readonly property int wipeDuration: 420
  property bool wiping: false
  property real wipe: 1
  property var _leavingCards: []
  property var _enteringCards: []

  function beginWipe(leavingIds) {
    finishWipe()
    for (var i = 0; i < leavingIds.length; i++) {
      var card = layer.cards[leavingIds[i]]
      if (!card) continue
      delete layer.cards[leavingIds[i]]
      if (layer.selectedId === leavingIds[i]) layer.selectedId = ""
      card.enabled = false
      card.parent = leaveGroup
      layer._leavingCards.push(card)
    }
    layer.wipe = 0
    layer.wiping = true
    wipeAnim.restart()
  }

  function finishWipe() {
    wipeAnim.stop()
    for (var i = 0; i < layer._leavingCards.length; i++) layer._leavingCards[i].destroy()
    for (var j = 0; j < layer._enteringCards.length; j++) {
      if (layer._enteringCards[j]) layer._enteringCards[j].parent = layer.contentItem
    }
    layer._leavingCards = []
    layer._enteringCards = []
    layer.wipe = 1
    layer.wiping = false
  }

  NumberAnimation {
    id: wipeAnim
    target: layer
    property: "wipe"
    from: 0
    to: 1
    duration: layer.wipeDuration
    easing.type: Easing.InOutCubic
    onFinished: layer.finishWipe()
  }

  Item {
    id: wipeMask
    anchors.fill: parent
    visible: false
    layer.enabled: true

    readonly property real slant: -0.18
    readonly property real centerTop: width / 2 - slant * height / 2
    readonly property real centerBottom: width / 2 + slant * height / 2
    readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
    readonly property real spread: reach * layer.wipe

    Shape {
      anchors.fill: parent
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        fillColor: "white"
        strokeColor: "transparent"
        startX: wipeMask.centerTop - wipeMask.spread; startY: 0
        PathLine { x: wipeMask.centerTop + wipeMask.spread; y: 0 }
        PathLine { x: wipeMask.centerBottom + wipeMask.spread; y: wipeMask.height }
        PathLine { x: wipeMask.centerBottom - wipeMask.spread; y: wipeMask.height }
        PathLine { x: wipeMask.centerTop - wipeMask.spread; y: 0 }
      }
    }
  }

  Item {
    id: leaveGroup
    anchors.fill: parent
    layer.enabled: layer.wiping
    layer.effect: MultiEffect {
      maskEnabled: true
      maskInverted: true
      maskSource: wipeMask
      maskThresholdMin: 0.5
      maskSpreadAtMin: 0.02
    }
  }

  Item {
    id: enterGroup
    anchors.fill: parent
    layer.enabled: layer.wiping
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: wipeMask
      maskThresholdMin: 0.5
      maskSpreadAtMin: 0.02
    }
  }

  // First declared child — cards created later stack above it. Any press that
  // does NOT land on a card lands here and clears the selection.
  MouseArea {
    id: clearSelectArea
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: layer.selectedId = ""
  }

  onSelectedIdChanged: {
    for (var id in layer.cards)
      layer.cards[id].selected = (id === layer.selectedId)
  }

  function setSelected(id) {
    layer.selectedId = id
  }

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  function addWidget(entry) {
    if (!entry || layer.cards[entry.id]) return
    if (layer.cardComponent.status !== Component.Ready) {
      console.warn("whimsy: DesktopWidget component not ready:",
        layer.cardComponent.errorString())
      return
    }
    var card = layer.cardComponent.createObject(layer.wiping ? enterGroup : layer.contentItem, {
      service: layer.service,
      desktop: layer,
      widgetId: entry.id,
      styleId: entry.style,
      screen: layer.screen,
      startX: entry.x,
      startY: entry.y,
      textScale: Number(entry.scale || 1),
      locked: entry.locked === true,
      startRotation: Number(entry.rotation) || 0,
      centerOnStart: entry.center === true
    })
    if (!card) {
      console.warn("whimsy: DesktopWidget createObject failed")
      return
    }
    layer.cards[entry.id] = card
    if (layer.wiping) layer._enteringCards.push(card)
    // A freshly placed widget appears selected so its handles are visible.
    if (entry.center === true) layer.setSelected(entry.id)
  }

  function updateWidget(entry) {
    var card = layer.cards[entry.id]
    if (!card) return
    card.styleId = entry.style
    card.textScale = Number(entry.scale || 1)
    card.locked = entry.locked === true
    card.rotation = Number(entry.rotation) || 0
    card.x = entry.x
    card.y = entry.y
  }

  function removeCard(id) {
    var card = layer.cards[id]
    if (card) {
      card.destroy()
      delete layer.cards[id]
    }
    if (layer.selectedId === id) layer.selectedId = ""
  }
}