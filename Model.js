.pragma library

var zoneNames = ["left", "center", "right", "lightbar"]

var zoneOptions = [
  { value: "left", label: "Left" },
  { value: "center", label: "Center" },
  { value: "right", label: "Right" },
  { value: "lightbar", label: "Light bar" }
]

var presets = [
  { name: "White", rgb: [255, 255, 255] },
  { name: "Red", rgb: [255, 40, 40] },
  { name: "Orange", rgb: [255, 96, 0] },
  { name: "Amber", rgb: [255, 170, 0] },
  { name: "Yellow", rgb: [255, 220, 0] },
  { name: "Green", rgb: [0, 220, 70] },
  { name: "Cyan", rgb: [0, 210, 255] },
  { name: "Blue", rgb: [40, 120, 255] },
  { name: "Purple", rgb: [150, 50, 255] },
  { name: "Magenta", rgb: [255, 0, 170] }
]

var effects = [
  { value: "static", label: "Solid" },
  { value: "breathe", label: "Breathe" },
  { value: "cycle", label: "Cycle" },
  { value: "wave", label: "Wave" },
  { value: "dance", label: "Dance" },
  { value: "flash", label: "Flash" },
  { value: "tempo", label: "Tempo" },
  { value: "random", label: "Random" }
]

function clampChannel(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(255, n))
}

function clampRgb(rgb) {
  if (!rgb || rgb.length < 3) return [40, 120, 255]
  return [clampChannel(rgb[0]), clampChannel(rgb[1]), clampChannel(rgb[2])]
}

function sameRgb(a, b) {
  var left = clampRgb(a)
  var right = clampRgb(b)
  return left[0] === right[0] && left[1] === right[1] && left[2] === right[2]
}

function defaultState() {
  return {
    available: false,
    enabled: true,
    brightness: 160,
    mode: "static",
    linked: true,
    activeZone: "left",
    zones: {
      left: [40, 120, 255],
      center: [40, 120, 255],
      right: [40, 120, 255],
      lightbar: [40, 120, 255]
    }
  }
}

function parseState(raw) {
  var base = defaultState()
  var data = raw
  if (typeof raw === "string") {
    if (!raw || raw.trim().length === 0) return base
    try {
      data = JSON.parse(raw)
    } catch (e) {
      return base
    }
  }
  if (!data || typeof data !== "object") return base

  base.available = data.available === true
  base.enabled = data.enabled !== false
  base.brightness = clampChannel(data.brightness === undefined ? 160 : data.brightness)
  base.mode = typeof data.mode === "string" ? data.mode : "static"
  base.linked = data.linked !== false
  base.activeZone = zoneNames.indexOf(data.activeZone) >= 0 ? data.activeZone : "left"
  var incoming = data.zones || {}
  for (var i = 0; i < zoneNames.length; i++) {
    var name = zoneNames[i]
    if (incoming[name]) base.zones[name] = clampRgb(incoming[name])
  }
  return base
}

function cloneZones(zones) {
  var copy = {}
  for (var i = 0; i < zoneNames.length; i++) {
    var name = zoneNames[i]
    copy[name] = clampRgb(zones[name])
  }
  return copy
}

function withColor(state, rgb) {
  var next = cloneZones(state.zones)
  var color = clampRgb(rgb)
  if (state.linked) {
    for (var i = 0; i < zoneNames.length; i++) next[zoneNames[i]] = color.slice()
  } else {
    next[state.activeZone] = color
  }
  return next
}

function statePayload(state) {
  return JSON.stringify({
    enabled: !!state.enabled,
    brightness: clampChannel(state.brightness),
    mode: state.mode,
    linked: !!state.linked,
    activeZone: state.activeZone,
    zones: cloneZones(state.zones)
  })
}

function percent(brightness) {
  return Math.round(clampChannel(brightness) * 100 / 255)
}

function fromPercent(value) {
  return clampChannel(Number(value) * 255 / 100)
}

function effectLabel(mode) {
  for (var i = 0; i < effects.length; i++) {
    if (effects[i].value === mode) return effects[i].label
  }
  return "Solid"
}

function heroMeta(state) {
  if (!state.available) return "Driver not loaded"
  if (!state.enabled) return "Off"
  var level = percent(state.brightness) + "%"
  if (state.mode === "static") return level
  return effectLabel(state.mode) + "  ·  " + level
}

function sectionIds(linked) {
  if (linked) return ["power", "brightness", "link", "color", "effect"]
  return ["power", "brightness", "link", "zone", "color", "effect"]
}

function sectionIndex(linked, id) {
  var ids = sectionIds(linked)
  var index = ids.indexOf(id)
  return index >= 0 ? index : 0
}
