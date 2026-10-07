.pragma library
// Registry.js — engine-wide bridge. `.pragma library` makes this module a
// true engine-wide singleton; without it, each importing QML file gets its
// own private copy and never sees another file's set().
var _service = null

function set(inst) {
  _service = inst
}

function get() {
  return _service
}