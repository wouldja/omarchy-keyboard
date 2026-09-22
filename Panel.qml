import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.wouldja.keyboard"
  ipcTarget: "io.github.wouldja.keyboard"

  property bool available: false
  property bool enabled: true
  property int brightness: 160
  property string mode: "static"
  property bool linked: true
  property string activeZone: "left"
  property var zones: ({
    left: [40, 120, 255],
    center: [40, 120, 255],
    right: [40, 120, 255],
    lightbar: [40, 120, 255]
  })
  property bool loaded: false

  property real wheelAccumulator: 0
  property bool persistQueued: false
  property bool liveQueued: false
  property var pendingPayload: ({})

  property string focusSection: "brightness"
  property int selectedIndex: -1
  property bool cursorActive: false

  readonly property var previewRgb: Model.clampRgb(root.zones[root.linked ? "left" : root.activeZone])
  readonly property color previewColor: Qt.rgba(root.previewRgb[0] / 255, root.previewRgb[1] / 255, root.previewRgb[2] / 255, 1)
  readonly property int brightnessPercent: Model.percent(root.brightness)
  readonly property string iconGlyph: "\uf11c"
  readonly property string applyBin: {
    var url = String(Qt.resolvedUrl("apply.py"))
    return url.indexOf("file://") === 0 ? url.slice(7) : url
  }

  function currentState() {
    return {
      enabled: root.enabled,
      brightness: root.brightness,
      mode: root.mode,
      linked: root.linked,
      activeZone: root.activeZone,
      zones: root.zones
    }
  }

  function applyParsed(parsed) {
    if (!parsed) return
    root.available = parsed.available === true
    root.enabled = parsed.enabled !== false
    root.brightness = parsed.brightness
    root.mode = parsed.mode || "static"
    root.linked = parsed.linked !== false
    root.activeZone = parsed.activeZone || "left"
    root.zones = parsed.zones
    root.loaded = true
  }

  function applyPath() {
    var path = root.applyBin
    if (path.indexOf("%") !== -1) {
      try { path = decodeURIComponent(path) } catch (e) {}
    }
    return path
  }

  function refresh() {
    if (getProc.running) return
    getProc.command = ["python3", applyPath(), "get"]
    getProc.running = true
  }

  function queueApply(mode) {
    root.pendingPayload = currentState()
    if (mode === "live") root.liveQueued = true
    else root.persistQueued = true
    if (!setProc.running) flushApply()
  }

  function flushApply() {
    if (!root.persistQueued && !root.liveQueued) return
    root.persistQueued = false
    root.liveQueued = false
    setProc.command = ["python3", applyPath(), "set", Model.statePayload(root.pendingPayload)]
    setProc.running = true
  }

  function restore() {
    if (restoreProc.running) return
    restoreProc.command = ["python3", applyPath(), "restore"]
    restoreProc.running = true
  }

  function setEnabled(on) {
    root.enabled = !!on
    queueApply("apply")
  }

  function setBrightness(value) {
    root.brightness = Model.clampChannel(value)
    queueApply("live")
  }

  function commitBrightness(value) {
    root.brightness = Model.clampChannel(value)
    queueApply("apply")
    showBrightnessOsd()
  }

  function setBrightnessFromPercent(value) {
    setBrightness(Model.fromPercent(value))
  }

  function commitBrightnessFromPercent(value) {
    commitBrightness(Model.fromPercent(value))
  }

  function nudgeBrightness(steps) {
    commitBrightness(root.brightness + steps * 8)
  }

  function applyColor(rgb, live) {
    root.mode = "static"
    root.zones = Model.withColor(currentState(), rgb)
    queueApply(live ? "live" : "apply")
  }

  function applyPreset(rgb) {
    applyColor(rgb, false)
  }

  function setChannel(index, value, live) {
    var rgb = Model.clampRgb(root.previewRgb).slice()
    rgb[index] = Model.clampChannel(value)
    applyColor(rgb, live)
  }

  function setLinked(on) {
    root.linked = !!on
    if (root.linked) root.zones = Model.withColor(currentState(), root.zones[root.activeZone] || root.previewRgb)
    queueApply("apply")
  }

  function setActiveZone(zone) {
    root.activeZone = zone
    queueApply("apply")
  }

  function setMode(mode) {
    root.mode = mode
    queueApply("apply")
  }

  function showBrightnessOsd() {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: root.iconGlyph,
      value: root.brightnessPercent
    }))
  }

  function moveCursor(delta) {
    var ids = Model.sectionIds(root.linked)
    var index = ids.indexOf(root.focusSection)
    if (index < 0 && (root.focusSection === "red" || root.focusSection === "green" || root.focusSection === "blue"))
      index = ids.indexOf("color")
    if (index < 0) index = 0
    index += delta
    index = Math.max(0, Math.min(ids.length - 1, index))
    root.focusSection = ids[index]
    root.selectedIndex = root.focusSection === "brightness" ? -1 : 0
    if (root.focusSection === "zone") root.selectedIndex = Math.max(0, Model.zoneNames.indexOf(root.activeZone))
    if (root.focusSection === "effect") {
      var effectIndex = 0
      for (var i = 0; i < Model.effects.length; i++) {
        if (Model.effects[i].value === root.mode) effectIndex = i
      }
      root.selectedIndex = effectIndex
    }
  }

  function moveCursorH(delta) {
    if (root.focusSection === "brightness") {
      nudgeBrightness(delta)
      return
    }
    if (root.focusSection === "color") {
      var count = Model.presets.length
      root.selectedIndex = (root.selectedIndex + delta + count) % count
      applyPreset(Model.presets[root.selectedIndex].rgb)
      return
    }
    if (root.focusSection === "effect") {
      var effects = Model.effects.length
      root.selectedIndex = (root.selectedIndex + delta + effects) % effects
      setMode(Model.effects[root.selectedIndex].value)
      return
    }
    if (root.focusSection === "zone") {
      var zones = Model.zoneNames
      var current = Math.max(0, zones.indexOf(root.activeZone))
      current = (current + delta + zones.length) % zones.length
      root.selectedIndex = current
      setActiveZone(zones[current])
    }
  }

  function activateCursor() {
    if (root.focusSection === "power") setEnabled(!root.enabled)
    else if (root.focusSection === "link") setLinked(!root.linked)
    else if (root.focusSection === "color" && root.selectedIndex >= 0) applyPreset(Model.presets[root.selectedIndex].rgb)
    else if (root.focusSection === "effect" && root.selectedIndex >= 0) setMode(Model.effects[root.selectedIndex].value)
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin) flick.contentY = bottom + margin - flick.height
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: restore()

  onOpenedChanged: {
    if (opened) {
      refresh()
      focusSection = "brightness"
      selectedIndex = -1
      cursorActive = false
    }
  }

  Process {
    id: getProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyParsed(Model.parseState(text))
    }
  }

  Process {
    id: restoreProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyParsed(Model.parseState(text))
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseState(text)
        if (parsed) root.available = parsed.available === true
      }
    }
    onRunningChanged: {
      if (running) return
      if (root.persistQueued || root.liveQueued) root.flushApply()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconGlyph
    tooltipText: root.available ? (root.enabled ? "Keyboard  " + root.brightnessPercent + "%" : "Keyboard off") : "Keyboard"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.setEnabled(!root.enabled)
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.nudgeBrightness(wheel.steps)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: "Keyboard"
            meta: Model.heroMeta({
              available: root.available,
              enabled: root.enabled,
              brightness: brightnessSection.dragging ? brightnessSection.liveValue : root.brightness,
              mode: root.mode
            })
            detail: root.loaded && !root.available ? "No driver" : ""
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            iconComponent: heroIcon
          }

          Row {
            width: parent.width
            spacing: root.linked ? 0 : Style.space(4)
            height: Style.space(8)

            Repeater {
              model: root.linked ? ["left"] : Model.zoneNames
              Rectangle {
                required property string modelData
                width: root.linked
                  ? parent.width
                  : (parent.width - Style.space(4) * 3) / 4
                height: parent.height
                radius: height / 2
                color: {
                  var rgb = Model.clampRgb(root.zones[modelData])
                  return Qt.rgba(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, root.enabled ? 1 : 0.35)
                }
              }
            }
          }

          Text {
            visible: root.loaded && !root.available
            width: parent.width
            wrapMode: Text.Wrap
            text: "The keyboard driver is not loaded, so these controls cannot reach the lights yet."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { foreground: root.bar.foreground }

          Toggle {
            width: parent.width
            label: "Backlight"
            description: "Turn the keyboard and light bar off without forgetting the color."
            foreground: root.bar.foreground
            accent: Color.accent
            fontFamily: root.bar.fontFamily
            checked: root.enabled
            hasCursor: root.cursorActive && root.focusSection === "power"
            onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
            onHovered: function(h) {
              if (!h) return
              root.cursorActive = true
              root.focusSection = "power"
              root.selectedIndex = 0
            }
            onClicked: root.setEnabled(!root.enabled)
          }

          PanelSeparator { foreground: root.bar.foreground }

          SliderSection {
            id: brightnessSection
            width: parent.width
            sectionId: "brightness"
            title: "BRIGHTNESS"
            minimum: 0
            maximum: 255
            step: 1
            value: root.brightness
            valueText: (dragging ? Model.percent(liveValue) : root.brightnessPercent) + "%"
            onMoved: function(v) { root.setBrightness(v) }
            onReleased: function(v) { root.commitBrightness(v) }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Toggle {
            width: parent.width
            label: "Same color everywhere"
            description: "Left, center, right, and the front light bar share one color."
            foreground: root.bar.foreground
            accent: Color.accent
            fontFamily: root.bar.fontFamily
            checked: root.linked
            hasCursor: root.cursorActive && root.focusSection === "link"
            onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
            onHovered: function(h) {
              if (!h) return
              root.cursorActive = true
              root.focusSection = "link"
              root.selectedIndex = 0
            }
            onClicked: root.setLinked(!root.linked)
          }

          ChoiceSection {
            visible: !root.linked
            width: parent.width
            sectionId: "zone"
            title: "ZONE"
            options: Model.zoneOptions
            value: root.activeZone
            onActivated: function(v) { root.setActiveZone(v) }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Column {
            id: colorSection
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "COLOR"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Grid {
              id: swatchGrid
              width: parent.width
              columns: 5
              spacing: Style.spacing.xs
              readonly property real cell: columns > 0 ? (width - spacing * (columns - 1)) / columns : 0

              Repeater {
                model: Model.presets

                Rectangle {
                  id: swatch
                  required property var modelData
                  required property int index
                  width: swatchGrid.cell
                  height: swatchGrid.cell
                  radius: Math.min(Style.cornerRadius, width / 2)
                  color: Qt.rgba(modelData.rgb[0] / 255, modelData.rgb[1] / 255, modelData.rgb[2] / 255, 1)
                  border.width: Model.sameRgb(root.previewRgb, modelData.rgb) ? Math.max(2, Style.space(2)) : 0
                  border.color: root.cursorActive && root.focusSection === "color" && root.selectedIndex === index
                    ? Color.accent
                    : root.bar.foreground

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: {
                      root.cursorActive = true
                      root.focusSection = "color"
                      root.selectedIndex = index
                    }
                    onClicked: root.applyPreset(modelData.rgb)
                  }
                }
              }
            }

            SliderSection {
              width: parent.width
              sectionId: "red"
              title: "RED"
              minimum: 0
              maximum: 255
              step: 1
              value: root.previewRgb[0]
              valueText: String(dragging ? Math.round(liveValue) : root.previewRgb[0])
              onMoved: function(v) { root.setChannel(0, v, true) }
              onReleased: function(v) { root.setChannel(0, v, false) }
            }

            SliderSection {
              width: parent.width
              sectionId: "green"
              title: "GREEN"
              minimum: 0
              maximum: 255
              step: 1
              value: root.previewRgb[1]
              valueText: String(dragging ? Math.round(liveValue) : root.previewRgb[1])
              onMoved: function(v) { root.setChannel(1, v, true) }
              onReleased: function(v) { root.setChannel(1, v, false) }
            }

            SliderSection {
              width: parent.width
              sectionId: "blue"
              title: "BLUE"
              minimum: 0
              maximum: 255
              step: 1
              value: root.previewRgb[2]
              valueText: String(dragging ? Math.round(liveValue) : root.previewRgb[2])
              onMoved: function(v) { root.setChannel(2, v, true) }
              onReleased: function(v) { root.setChannel(2, v, false) }
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          ChoiceSection {
            width: parent.width
            sectionId: "effect"
            title: "EFFECT"
            options: Model.effects
            value: root.mode
            onActivated: function(v) { root.setMode(v) }
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  Component {
    id: heroIcon
    Text {
      textFormat: Text.PlainText
      text: root.iconGlyph
      color: root.enabled && root.available ? root.previewColor : root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.display
    }
  }

  component SliderSection: Column {
    id: sliderSection
    required property string sectionId
    required property string title
    required property string valueText
    property real value: 0
    property real minimum: 0
    property real maximum: 255
    property real step: 1
    property alias dragging: slider.dragging
    property alias liveValue: slider.liveValue
    signal moved(real value)
    signal released(real value)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(header.implicitHeight, valueLabel.implicitHeight)

      PanelSectionHeader {
        id: header
        text: sliderSection.title
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: valueLabel
        textFormat: Text.PlainText
        text: sliderSection.valueText
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    CursorSurface {
      id: sliderRow
      width: parent.width
      height: slider.implicitHeight + Style.spacing.controlGap
      hasCursor: root.cursorActive && root.focusSection === sliderSection.sectionId && root.selectedIndex === -1
      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sliderRow)
      foreground: root.bar.foreground
      outline: true

      PanelSlider {
        id: slider
        bar: root.bar
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        minimum: sliderSection.minimum
        maximum: sliderSection.maximum
        step: sliderSection.step
        integer: true
        value: sliderSection.value
        onMoved: function(v) { sliderSection.moved(v) }
        onReleased: function(v) { sliderSection.released(v) }
      }

      HoverHandler {
        onHoveredChanged: if (hovered) {
          root.cursorActive = true
          root.focusSection = sliderSection.sectionId
          root.selectedIndex = -1
        }
      }
    }
  }

  component ChoiceSection: Column {
    id: choiceSection
    required property string sectionId
    required property string title
    required property var options
    required property string value
    signal activated(string value)

    spacing: Style.space(10)

    PanelSectionHeader {
      text: choiceSection.title
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    Grid {
      id: choiceRow
      width: parent.width
      columns: Math.min(4, choiceSection.options.length)
      spacing: Style.spacing.xs
      readonly property real cellWidth: columns > 0
        ? (width - spacing * (columns - 1)) / columns
        : 0

      Repeater {
        model: choiceSection.options

        Button {
          required property var modelData
          required property int index
          width: choiceRow.cellWidth
          text: modelData.label
          fontSize: Style.font.caption
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          selected: choiceSection.value === modelData.value
          hasCursor: root.cursorActive && root.focusSection === choiceSection.sectionId && root.selectedIndex === index
          onClicked: choiceSection.activated(modelData.value)
          onHovered: function(isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.focusSection = choiceSection.sectionId
            root.selectedIndex = index
          }
        }
      }
    }
  }
}
