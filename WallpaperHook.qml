import QtQuick
import "Registry.js" as Reg

// Loaded lazily by a cooperating background plugin (see archer.background) so
// that plugin has no hard import of whimsy. notify() reports that the
// wallpaper reveal animation just started.
QtObject {
  // Called once when the background plugin loads: tells whimsy a reveal
  // signal will follow each wallpaper change.
  function announce() {
    Reg.markHook()
  }

  function notify() {
    Reg.markHook()
    var service = Reg.get()
    if (service && service.wallpaperRevealStarted) service.wallpaperRevealStarted()
  }
}
