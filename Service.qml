import QtQuick
import Quickshell
import Quickshell.Io
import "Registry.js" as Reg

// Singleton host for placed desktop widgets. The shell loads this once
// (whimsy is listed in shell.json plugins[]); every bar instance reaches
// it through Registry.js or bar.shell.serviceFor("whimsy"). It owns the
// widgets.json state file and materializes one full-screen bottom-layer
// surface per monitor (all cards of that screen live inside it).
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string statePath: home + "/.local/state/omarchy/whimsy/widgets.json"
  readonly property string settingsPath: home + "/.local/state/omarchy/whimsy/settings.json"
  readonly property string layoutsPath: home + "/.local/state/omarchy/whimsy/layouts.json"
  readonly property string stateHome: home + "/.local/state"
  readonly property string wallpaperLink: home + "/.local/state/omarchy/current/background"

  // Persisted shape: [{ id, style, screen, x, y, scale? }]
  property var widgets: []
  // When true, placed cards hide their edit chrome (drag/resize/rotate/lock/
  // remove) and stop intercepting clicks for selection — a widget's own
  // controls (e.g. media play/pause) keep working either way, since they're
  // separate MouseAreas the card's handlers never touch.
  property bool editLocked: false
  property bool _settingsInitialized: false
  // Per-screen bottom-layer surfaces: { screenName: DesktopWidget }
  property var _layers: ({})
  // Never write state before the file has been read at least once: a shell
  // that loads late would otherwise wipe persisted widgets with its empty
  // in-memory list.
  property bool _initialized: false

  // Per-wallpaper layouts: { "<resolved wallpaper path>": [entry, ...] }.
  // `widgets` is always the live layout of the current wallpaper; this map
  // holds every wallpaper's saved copy. Three distinct states per wallpaper:
  //   key absent / null -> never visited: copy the current layout on arrival
  //   []                -> deliberately empty: show nothing, don't copy
  //   [entries]         -> restore exactly
  property var layouts: ({})
  property bool _layoutsLoaded: false
  property string currentWallpaper: ""
  // Wallpaper whose layout `widgets` currently represents ("" until synced).
  property string _activeWallpaper: ""
  // Layout for the new wallpaper, waiting for the reveal to start.
  property var _pendingList: null

  readonly property int widgetCount: widgets.length

  Component.onCompleted: {
    Reg.set(root)
    wallpaperProc.running = true
    console.log("[whimsy] service online; state=",
      "component=", root._layerComponent.status,
      root._layerComponent.errorString())
  }

  IpcHandler {
    target: "whimsy.service"

    function status(): string {
      var layers = []
      for (var name in root._layers) {
        var l = root._layers[name]
        var ids = []
        for (var id in l.cards) {
          var c = l.cards[id]
          ids.push({
            id: id,
            x: Math.round(c.x),
            y: Math.round(c.y),
            w: Math.round(c.width),
            h: Math.round(c.height),
            scale: c.textScale,
            locked: !!c.locked
          })
        }
        layers.push({ screen: name, cards: ids, wiping: l.wiping })
      }
      return JSON.stringify({
        compStatus: root._layerComponent.status,
        compError: root._layerComponent.errorString(),
        widgets: root.widgets,
        layers: layers,
        editLocked: root.editLocked
      })
    }

    function place(style: string): string {
      root.placeWidget(style, root.primaryScreenName())
      return "ok"
    }

    function remove(id: string): string {
      root.removeWidget(id)
      return "ok"
    }

    function setEditLocked(locked: string): string {
      root.setEditLocked(locked === "true" || locked === "1")
      return "ok"
    }
  }

  function setEditLocked(v) {
    v = !!v
    if (v === root.editLocked) return
    root.editLocked = v
    root.saveSettings()
  }

  function screenByName(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && screens[i].name === name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function primaryScreenName() {
    var screens = Quickshell.screens
    return screens.length > 0 && screens[0] ? screens[0].name : ""
  }

  function generateId() {
    return "w" + Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36)
  }

  // Place a widget at the center of the screen. The exact centered position
  // is computed by the card once its real size is known, then reported back
  // via cardMoved() so the persisted x/y match the visible card.
  function placeWidget(styleId, screenName) {
    var entry = {
      id: generateId(),
      style: String(styleId || "big-day"),
      screen: String(screenName || root.primaryScreenName()),
      x: 0,
      y: 0,
      scale: 1,
      locked: false,
      rotation: 0,
      center: true
    }
    var list = root.widgets.slice()
    list.push(entry)
    root.widgets = list
    materializeEntry(entry)
    save()
  }

  // Called by a card after it finished moving (drag drop or centering):
  // persist its position.
  function cardMoved(id, nx, ny) {
    var list = root.widgets.slice()
    var changed = false
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        list[i].x = Math.round(nx)
        list[i].y = Math.round(ny)
        delete list[i].center
        changed = true
      }
    }
    if (!changed) return
    root.widgets = list
    save()
  }

  function cardResized(id, scale) {
    scale = Math.max(0.4, Math.min(3, Number(scale) || 1))
    var list = root.widgets.slice()
    var changed = false
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === id && Number(list[i].scale || 1) !== scale) {
        list[i].scale = scale
        changed = true
      }
    }
    if (!changed) return
    root.widgets = list
    save()
  }

  function cardRotated(id, angle) {
    angle = Number(angle) || 0
    var list = root.widgets.slice()
    var changed = false
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        list[i].rotation = angle
        changed = true
      }
    }
    if (!changed) return
    root.widgets = list
    save()
  }

  function cardLocked(id, locked) {
    var list = root.widgets.slice()
    var changed = false
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === id && !!list[i].locked !== !!locked) {
        list[i].locked = !!locked
        changed = true
      }
    }
    if (!changed) return
    root.widgets = list
    save()
  }

  function removeWidget(id) {
    var list = []
    for (var i = 0; i < root.widgets.length; i++) {
      if (root.widgets[i].id !== id) list.push(root.widgets[i])
    }
    if (list.length === root.widgets.length) return
    root.widgets = list
    for (var name in root._layers) root._layers[name].removeCard(id)
    save()
  }

  // ---- layer lifecycle -----------------------------------------------------

  property Component _layerComponent: Qt.createComponent(
    Qt.resolvedUrl("DesktopWidget.qml"), Component.PreferSynchronous)

  function ensureLayer(screenName) {
    var name = String(screenName || root.primaryScreenName())
    var existing = root._layers[name]
    if (existing) return existing
    if (root._layerComponent.status !== Component.Ready) {
      console.warn("whimsy: DesktopWidget component not ready:",
        root._layerComponent.errorString())
      return null
    }
    var layer = root._layerComponent.createObject(null, {
      service: root,
      screenName: name
    })
    if (!layer) {
      console.warn("whimsy: DesktopWidget createObject failed")
      return null
    }
    root._layers[name] = layer
    return layer
  }

  function materializeEntry(entry) {
    if (!entry) return
    var layer = root.ensureLayer(entry.screen)
    if (!layer) return
    if (layer.cards[entry.id]) layer.updateWidget(entry)
    else layer.addWidget(entry)
  }

  function dropLayer(name) {
    var layer = root._layers[name]
    if (layer) layer.destroy()
    delete root._layers[name]
  }

  // ---- persistence ----------------------------------------------------------

  function canonical() {
    return JSON.stringify(root.widgets)
  }

  function loadFromText(text) {
    var raw = String(text || "").trim()
    // An empty/partial read is the classic startup race (FileView vs the
    // shell's own first write). Never replace in-memory widgets with nothing
    // based on a blank read — otherwise lives clobber persisted state.
    if (raw === "") {
      if (root._initialized) return
      root._initialized = true
      root.widgets = []
      root._syncWallpaper()
      return
    }

    var parsed = []
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      parsed = []
    }
    if (!Array.isArray(parsed)) parsed = []

    var list = []
    for (var i = 0; i < parsed.length; i++) {
      var e = parsed[i]
      if (!e || !e.id || !e.style) continue
      if (!isFinite(Number(e.x)) || !isFinite(Number(e.y))) continue
      list.push({
        id: String(e.id),
        style: String(e.style),
        screen: String(e.screen || ""),
        x: Number(e.x),
        y: Number(e.y),
        scale: Math.max(0.4, Math.min(3, Number(e.scale || 1))),
        locked: e.locked === true,
        rotation: Number(e.rotation) || 0
      })
      if (e.center === true) list[list.length - 1].center = true
    }

    // Skip redundant reloads triggered by our own writes.
    if (root.canonical() === JSON.stringify(list)) {
      root._initialized = true
      root._syncWallpaper()
      return
    }

    root._initialized = true
    root.applyList(list)
    // External edit of widgets.json: mirror it into this wallpaper's layout.
    if (root._activeWallpaper !== "") root.save()
    root._syncWallpaper()
  }

  // Make `list` the live layout: drop cards that vanished, create/update
  // the rest.
  // `animate` plays the wallpaper-synced wipe (layout change from a
  // wallpaper switch); everything else swaps instantly.
  function applyList(list, animate) {
    var changed = animate && root.canonical() !== JSON.stringify(list)
    for (var name in root._layers) {
      var layer = root._layers[name]
      var leaving = []
      for (var id in layer.cards) {
        var still = false
        for (var k = 0; k < list.length; k++) {
          if (list[k].id === id && list[k].screen === name) {
            still = true
            break
          }
        }
        if (!still) leaving.push(id)
      }
      if (changed) layer.beginWipe(leaving)
      else leaving.forEach(function(lid) { layer.removeCard(lid) })
    }

    root.widgets = list
    list.forEach(function(entry) {
      if (changed) root.materializeEntry(entry)
      else Qt.callLater(function() { root.materializeEntry(entry) })
    })
  }

  function cloneList(list) {
    return JSON.parse(JSON.stringify(list || []))
  }

  // ---- per-wallpaper layouts ------------------------------------------------

  // Switch `widgets` to the layout belonging to the current wallpaper. The
  // layout being left is already stored: save() mirrors every change into
  // layouts[_activeWallpaper] as it happens.
  function _syncWallpaper() {
    if (!root._initialized || !root._layoutsLoaded || root.currentWallpaper === "") return
    var wp = root.currentWallpaper
    if (wp === root._activeWallpaper) return

    var saved = root.layouts[wp]
    // Only a live switch animates; the first sync at startup applies instantly.
    var wasSynced = root._activeWallpaper !== ""
    root._activeWallpaper = wp
    if (Array.isArray(saved)) {
      if (wasSynced && Reg.hookPresent()) {
        // Hold the swap until the wallpaper reveal actually starts (the
        // background plugin calls wallpaperRevealStarted); the timer covers
        // switches that never animate.
        root._pendingList = root.cloneList(saved)
        revealFallback.restart()
      } else if (wasSynced) {
        // No cooperating background plugin: swap right away, wiping on our own.
        root.applyList(root.cloneList(saved), true)
        saveTimer.restart()
      } else {
        root.applyList(root.cloneList(saved), false)
        saveTimer.restart()
      }
    } else {
      // First visit (absent or null): inherit the layout we're leaving.
      root.layouts[wp] = root.cloneList(root.widgets)
      root.saveLayouts()
    }
  }

  // Called by io.github.rk4500.archer-background the moment its reveal animation starts.
  function wallpaperRevealStarted() {
    root._applyPending()
  }

  function _applyPending() {
    revealFallback.stop()
    if (root._pendingList === null) return
    var list = root._pendingList
    root._pendingList = null
    root.applyList(list, true)
    saveTimer.restart()
  }

  Timer {
    id: revealFallback
    interval: 1200
    onTriggered: root._applyPending()
  }

  function loadLayoutsFromText(text) {
    var raw = String(text || "").trim()
    var parsed = {}
    if (raw !== "") {
      try {
        parsed = JSON.parse(raw)
      } catch (e) {
        // Corrupt file: leave per-wallpaper layouts off this session rather
        // than overwrite it.
        console.warn("whimsy: layouts.json unreadable; per-wallpaper layouts disabled")
        return
      }
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}
    root.layouts = parsed
    root._layoutsLoaded = true
    root._syncWallpaper()
  }

  function saveLayouts() {
    if (!root._layoutsLoaded) return
    layoutsSaveTimer.restart()
  }

  function flushLayouts() {
    if (layoutsSaveProc.running) {
      layoutsSaveTimer.restart()
      return
    }
    layoutsSaveProc.command = ["sh", "-c",
      'd=$(dirname -- "$1"); mkdir -p -- "$d"; printf "%s" "$2" > "$1"',
      "whimsy-layouts-save", root.layoutsPath, JSON.stringify(root.layouts)]
    layoutsSaveProc.running = true
  }

  function save() {
    if (!root._initialized) return
    if (root._activeWallpaper !== "" && root._pendingList === null) {
      root.layouts[root._activeWallpaper] = root.cloneList(root.widgets)
      root.saveLayouts()
    }
    if (saveTimer.running) return
    saveTimer.restart()
  }

  function flushSave() {
    if (saveProc.running) {
      saveTimer.restart()
      return
    }
    // The payload is passed as an argument ("$2"), never interpolated into
    // the script, so arbitrary JSON is safe through the shell.
    saveProc.command = ["sh", "-c",
      'd=$(dirname -- "$1"); mkdir -p -- "$d"; printf "%s" "$2" > "$1"',
      "whimsy-save", root.statePath, root.canonical()]
    saveProc.running = true
  }

  Timer {
    id: saveTimer
    interval: 200
    onTriggered: root.flushSave()
  }

  Timer {
    id: layoutsSaveTimer
    interval: 200
    onTriggered: root.flushLayouts()
  }

  Process {
    id: layoutsSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("whimsy: layouts save failed via:", root.layoutsPath)
    }
  }

  FileView {
    id: layoutsFile
    path: root.layoutsPath
    printErrors: false
    onLoaded: root.loadLayoutsFromText(text())
    onLoadFailed: {
      root.layouts = ({})
      root._layoutsLoaded = true
      root._syncWallpaper()
    }
  }

  // The wallpaper symlink is replaced (ln -nsf), so a watch on the link itself
  // would go stale with the old inode. Watch its directory instead and re-read
  // the resolved target when the link is recreated.
  Process {
    id: wallpaperProc
    // Key = "<theme>/<file>" for theme wallpapers (current/theme is a copy of
    // the active theme, so its path alone can't tell two themes' same-named
    // files apart); the full path for anything else.
    command: ["sh", "-c",
      'p=$(readlink -f "$1") || exit 0; case "$p" in "$2"/*) printf "%s/%s" "$(cat "$3" 2>/dev/null)" "${p##*/}";; *) printf "%s" "$p";; esac',
      "whimsy-wallpaper", root.wallpaperLink,
      root.stateHome + "/omarchy/current/theme/backgrounds",
      root.stateHome + "/omarchy/current/theme.name"]
    stdout: StdioCollector {
      onStreamFinished: {
        var p = String(text || "").trim()
        if (p === "" || p === root.currentWallpaper) return
        root.currentWallpaper = p
        root._syncWallpaper()
      }
    }
  }

  Process {
    id: wallpaperWatcher
    running: true
    command: ["inotifywait", "-m", "-q", "-e", "create,moved_to",
      "--format", "%f", root.stateHome + "/omarchy/current"]
    stdout: SplitParser {
      onRead: function(name) {
        if (name === "background" && !wallpaperProc.running) wallpaperProc.running = true
      }
    }
  }

  Process {
    id: saveProc
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("whimsy: state save failed via:", root.statePath)
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadFromText(text())
    onLoadFailed: {
      // First run (or file temporarily unreadable): start with an empty list
      // but mark initialized so user placements still persist.
      root._initialized = true
      root.widgets = []
      root._syncWallpaper()
    }
  }

  // ---- edit-lock settings persistence --------------------------------------

  function saveSettings() {
    if (!root._settingsInitialized) return
    settingsSaveProc.command = ["sh", "-c",
      'd=$(dirname -- "$1"); mkdir -p -- "$d"; printf "%s" "$2" > "$1"',
      "whimsy-settings-save", root.settingsPath,
      JSON.stringify({ editLocked: root.editLocked })]
    settingsSaveProc.running = true
  }

  Process {
    id: settingsSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("whimsy: settings save failed via:", root.settingsPath)
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(String(text() || "").trim())
        root.editLocked = parsed && parsed.editLocked === true
      } catch (e) {
        root.editLocked = false
      }
      root._settingsInitialized = true
    }
    onLoadFailed: {
      root.editLocked = false
      root._settingsInitialized = true
    }
  }

  // First read can race shell startup; one delayed reload self-corrects.
  Timer {
    interval: 1200
    running: true
    onTriggered: {
      stateFile.reload()
      settingsFile.reload()
    }
  }
}