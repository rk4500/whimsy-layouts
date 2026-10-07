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

// A cooperating background plugin (io.github.rk4500.synced-background) announces itself so
// whimsy knows whether to wait for its "reveal started" signal or apply a
// layout change straight away. Kept here, in the shared singleton, so it
// doesn't matter which plugin loaded first.
var _hookPresent = false

function markHook() {
  _hookPresent = true
}

function hookPresent() {
  return _hookPresent
}
