import QtQuick
import "Registry.js" as Reg

// Loaded lazily by a cooperating background plugin (see archer.background) so
// that plugin has no hard import of whimsy. notify() reports that the
// wallpaper reveal animation just started.
QtObject {
  function notify() {
    var service = Reg.get()
    if (service && service.wallpaperRevealStarted) service.wallpaperRevealStarted()
  }
}
