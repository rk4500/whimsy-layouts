import QtQuick
import qs.Commons

// Overview card: CPU usage ring + CPU temp + battery wattage in one glass
// card, sized like the vinyl turntable music widget. Values are sampled by
// the shared sys-monitor.py daemon (see SystemWidget's pollInterval) so the
// numbers displayed here already update on their own slow cadence.
Item {
  id: root

  property real widgetScale: 1
  property color fgColor: Color.foreground
  property color accentColor: Color.accent

  property real cpuPct: 0
  property real cpuTemp: 0
  property bool batteryAvail: false
  property real batteryWatts: 0
  property bool batteryCharging: false

  // Eases toward each new sample instead of snapping, since samples only
  // arrive every pollInterval seconds (see SystemWidget.pollInterval).
  property real animatedCpuPct: cpuPct
  Behavior on animatedCpuPct {
    NumberAnimation { duration: 900; easing.type: Easing.OutCubic }
  }

  width: Style.space(310) * widgetScale
  height: Style.space(116) * widgetScale

  Rectangle {
    id: cardRoot
    anchors.fill: parent
    radius: Style.space(16)
    color: Util.alpha(Color.popups.background, 0.85)
    border.width: 1
    border.color: Util.alpha(root.fgColor, 0.14)

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(10) * root.widgetScale
      spacing: Style.space(14) * root.widgetScale

      // ---- CPU ring dial (left deck, turntable-proportioned) --------------
      Item {
        width: Style.space(96) * root.widgetScale
        height: Style.space(96) * root.widgetScale
        anchors.verticalCenter: parent.verticalCenter

        Canvas {
          id: ringCanvas
          anchors.fill: parent
          antialiasing: true

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var cx = width / 2
            var cy = height / 2
            var r = width * 0.42

            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, Math.PI * 2, false)
            ctx.lineWidth = 4 * root.widgetScale
            ctx.strokeStyle = "rgba(255, 255, 255, 0.08)"
            ctx.stroke()

            var val = Math.max(0, Math.min(100, root.animatedCpuPct)) / 100.0
            if (val > 0) {
              ctx.beginPath()
              ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * val, false)
              ctx.lineWidth = 4 * root.widgetScale
              ctx.strokeStyle = root.animatedCpuPct > 85 ? "#ef4444" : root.accentColor
              ctx.lineCap = "round"
              ctx.stroke()
            }
          }

          Connections {
            target: root
            function onAnimatedCpuPctChanged() { ringCanvas.requestPaint() }
          }
        }

        Column {
          anchors.centerIn: parent
          spacing: 0
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Math.round(root.animatedCpuPct)
            color: root.animatedCpuPct > 85 ? "#ef4444" : root.fgColor
            font.family: "JetBrainsMono NF"
            font.pixelSize: Style.space(18) * root.widgetScale
            font.weight: Font.Bold
            renderType: Text.QtRendering
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "% CPU"
            color: Util.alpha(root.fgColor, 0.5)
            font.family: "JetBrainsMono NF"
            font.pixelSize: Style.space(8) * root.widgetScale
            renderType: Text.QtRendering
          }
        }
      }

      // ---- stat rows (right side) ------------------------------------------
      Column {
        width: parent.width - Style.space(110) * root.widgetScale
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10) * root.widgetScale

        // CPU temp row
        Row {
          width: parent.width
          Text {
            width: parent.width * 0.55
            text: "TEMP"
            color: Util.alpha(root.fgColor, 0.55)
            font.family: "JetBrainsMono NF"
            font.pixelSize: Style.space(10) * root.widgetScale
            font.weight: Font.Bold
            renderType: Text.QtRendering
          }
          Text {
            text: root.cpuTemp > 0 ? (Math.round(root.cpuTemp) + "°C") : "--"
            color: root.cpuTemp > 75 ? "#ef4444" : root.accentColor
            font.family: "JetBrainsMono NF"
            font.pixelSize: Style.space(12) * root.widgetScale
            font.weight: Font.Bold
            renderType: Text.QtRendering
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(root.fgColor, 0.1)
        }

        // Battery wattage row
        Row {
          width: parent.width
          spacing: Style.space(4) * root.widgetScale
          Text {
            width: parent.width * 0.55 - Style.space(4) * root.widgetScale
            text: "POWER"
            color: Util.alpha(root.fgColor, 0.55)
            font.family: "JetBrainsMono NF"
            font.pixelSize: Style.space(10) * root.widgetScale
            font.weight: Font.Bold
            renderType: Text.QtRendering
          }
          Text {
            text: root.batteryAvail
              ? ((root.batteryCharging ? "+" : "-") + root.batteryWatts.toFixed(1) + "W")
              : "--"
            color: root.batteryCharging ? root.accentColor : root.fgColor
            font.family: "JetBrainsMono NF"
            font.pixelSize: Style.space(12) * root.widgetScale
            font.weight: Font.Bold
            renderType: Text.QtRendering
          }
        }
      }
    }
  }
}
