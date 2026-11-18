import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Lofi Girl stream chooser. Wraps the `lofi` script that ships beside it (bin/lofi):
//   lofi list    -> [{id,title}]  live streams, cached 1h
//   lofi status  -> {running,playing,id,title}   running = player exists,
//                                                 playing = and is not paused
//   lofi play ID / lofi stop
// Play/pause is deliberately not here: mpv speaks MPRIS, so the stock
// omarchy.media widget owns that. This widget only chooses and stops.
// Left click: stream list. Right click: stop, resume if paused, or start the last stream.
// Middle click: stop. While stopped she takes the headphones off.
// SUPER+CTRL+G (bindings.lua -> `omarchy-shell shell toggle interslice.lofi`) opens
// the same list keyboard-first: arrows or j/k move, Space/Enter play or stop
// the cursor row, Escape closes. open/close/opened is Bar.findPanelWidget's
// contract, which is what summon/toggle/hide route to.
// The icon is a 16-unit silhouette (front view, cans, headband) drawn as
// Shape paths; fills track the bar's foreground, the rims that separate cans
// and headband from the hair track the bar's background, so themes just work.
BarWidget {
  id: root
  moduleName: "interslice.lofi"

  // The script ships next to this file (bin/lofi), so resolve it relative to
  // the plugin folder: `omarchy plugin add` then needs no PATH setup, and
  // QProcess does no shell expansion anyway.
  readonly property string lofiBin: Qt.resolvedUrl("bin/lofi").toString().replace(/^file:\/\//, "")

  property var streams: []
  property bool running: false
  // running = the player exists; playing = it is not paused. A paused player
  // (media key, headphones off) still exists, and she takes her headphones off.
  property bool playing: false
  property string currentId: ""
  property string currentTitle: ""
  property bool popupOpen: false

  readonly property color fg: bar ? bar.barForeground : Color.bar.text
  readonly property color dimFg: Qt.rgba(fg.r, fg.g, fg.b, 0.55)

  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function toggle() { popupOpen ? close() : open() }

  // ---- MacroPad section ---------------------------------------------------
  // Shown only on a desk that runs the macropad daemon
  // (github.com/interslice-systems/macropad). Its `macropad status` says what
  // each of the pad's twelve blank keys holds, which is what this section
  // draws as a legend, plus a picker for the pad's screen.
  //
  // Asked once when the list opens, then every two seconds only while the list
  // stays open AND the daemon answered. Without the pad that is one failed
  // spawn per open, and nothing while the list is closed.
  property var pad: null          // the last status, or null when nothing answers
  property bool padSeen: false    // the ask in flight has been answered
  readonly property var padViz: pad ? pad.visualizers : []
  property string padText: ""     // its raw text, to skip rebuilding an unchanged legend
  readonly property color padFg: bar ? bar.foreground : Color.foreground
  readonly property color dimText: Qt.rgba(padFg.r, padFg.g, padFg.b, 0.55)

  function checkPad() {
    if (padProc.running) return
    padSeen = false
    padProc.running = true
  }
  function setViz(name) {
    if (padAct.running || padViz.indexOf(name) < 0) return
    padAct.command = ["macropad", "viz", name]
    padAct.running = true
  }
  function nextViz() {
    if (!pad || !padViz.length) return
    setViz(padViz[(padViz.indexOf(pad.viz) + 1) % padViz.length])
  }
  // "lofi hip hop radio [emoji] beats to relax/study to" -> "lofi hip hop radio":
  // every Lofi Girl title puts its name before the first emoji.
  function shortTitle(t) {
    var s = String(t || "").slice(0, 80)
    var cut = s.replace(/[^\x20-\x7e].*$/, "").replace(/[\s\-]+$/, "")
    return cut.length ? cut : s
  }
  function keyLabel(k) {
    if (k.kind === "prev") return k.n + "  previous station"
    if (k.kind === "next") return k.n + "  next station"
    if (k.kind === "viz") return k.n + "  next screen"
    if (!k.title) return k.n + "  empty"
    var state = k.playing ? " \u00b7 playing" : (k.live ? "" : " \u00b7 off air")
    return k.n + "  " + shortTitle(k.title) + state
  }
  function keyColor(c) {
    return /^#[0-9a-fA-F]{6}$/.test(String(c)) ? c : padFg
  }

  // One cursor walks the stations and then the pad's screen choices. Starts on
  // the playing stream (or the top), wraps.
  function moveCursor(dy) {
    var n = streams.length + padViz.length
    if (!n) return
    if (cursorIndex < 0) { cursorIndex = dy > 0 ? 0 : n - 1; return }
    cursorIndex = (cursorIndex + dy + n) % n
  }
  function activateCursor() {
    if (cursorIndex >= streams.length && cursorIndex < streams.length + padViz.length) {
      setViz(padViz[cursorIndex - streams.length])    // stays open: watch it change
      return
    }
    if (cursorIndex < 0 || cursorIndex >= streams.length) return
    var s = streams[cursorIndex]
    act(playing && s.id === currentId ? ["stop"] : ["play", s.id])
    popupOpen = false
  }
  function seedCursor() {
    var i = -1
    if (running) for (var k = 0; k < streams.length; k++) if (streams[k].id === currentId) { i = k; break }
    cursorIndex = i >= 0 ? i : (streams.length ? 0 : -1)
  }
  onStreamsChanged: if (popupOpen && cursorIndex < 0) seedCursor()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: [root.lofiBin, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let s
        try { s = JSON.parse(text || "{}") } catch (e) { return }
        root.running = !!s.running
        root.playing = !!s.playing
        root.currentId = s.id || ""
        root.currentTitle = s.title || ""
      }
    }
  }

  Process {
    id: listProc
    command: [root.lofiBin, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let l
        try { l = JSON.parse(text || "[]") } catch (e) { return }
        root.streams = l
      }
    }
  }

  // play/stop: command is set just before running; status refreshes on exit.
  Process {
    id: actionProc
    onExited: statusProc.running = true
  }

  Process {
    id: padProc
    command: ["macropad", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Unchanged since the last ask: answered, and nothing to redraw.
        if (root.pad !== null && text === root.padText) { root.padSeen = true; return }
        let s
        try { s = JSON.parse(text || "null") } catch (e) { return }
        if (!s || s.ok !== true || !Array.isArray(s.keys) || !Array.isArray(s.visualizers)) return
        // Bound what gets drawn or passed back as an argument.
        s.keys = s.keys.slice(0, 12)
        s.visualizers = s.visualizers.filter(function(n) {
          return typeof n === "string" && /^[a-z]{1,16}$/.test(n)
        }).slice(0, 8)
        root.padText = text
        root.pad = s
        root.padSeen = true
      }
    }
  }

  Process {
    id: padAct
    onExited: root.checkPad()
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.popupOpen && root.pad !== null
    onTriggered: {
      if (padProc.running) return
      if (root.padSeen) root.checkPad()
      else root.pad = null          // the last ask got no answer: the daemon is gone
    }
  }

  function act(args) {
    if (actionProc.running) return
    actionProc.command = [root.lofiBin].concat(args)
    actionProc.running = true
  }

  Timer {
    interval: 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }


  readonly property color ground: bar ? bar.background : Color.bar.background

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    tooltipText: root.playing ? root.currentTitle
      : root.running ? root.currentTitle + " (paused): right-click to resume"
      : "Lofi Girl: click for streams, right-click to resume"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.act(["stop"])
      else if (mouseButton === Qt.RightButton) root.act(["toggle"])
      else if (mouseButton === Qt.LeftButton) root.popupOpen = !root.popupOpen
    }
    iconComponent: Component {
      Item {
        Shape {
          id: shape
          width: 16
          height: 16
          transformOrigin: Item.TopLeft
          scale: parent.width / 16
          preferredRendererType: Shape.CurveRenderer

          // hair: a circle (centre 8,7.4 r 4.2) whose sides leave it at the exact
          // tangent points from the shoulder corners (2.8,12.7)/(13.2,12.7), so the
          // outline runs from curve into straight fall with no kink
          ShapePath {
            fillColor: root.fg; strokeColor: "transparent"
            PathSvg { path: "M3.864 6.670 A4.2 4.2 0 0 1 12.136 6.670 L13.2 12.7 L10.5 12.5 L10.3 9.2 L5.7 9.2 L5.5 12.5 L2.8 12.7 Z" }
          }
          // face
          ShapePath {
            fillColor: root.fg; strokeColor: "transparent"
            PathSvg { path: "M4.9 8.4 A3.1 3.1 0 1 0 11.1 8.4 A3.1 3.1 0 1 0 4.9 8.4 Z" }
          }
          // side-swept fringe
          ShapePath {
            fillColor: root.fg; strokeColor: "transparent"
            PathSvg { path: "M4.9 8.2 C 4.9 5.6, 6.4 4.3, 8.2 4.3 C 9.9 4.3, 11.1 5.5, 11.1 7.7 C 10.6 6.5, 9.7 6.2, 9.0 6.9 C 8.5 7.4, 7.9 7.2, 7.6 6.6 C 7.1 5.9, 6.0 6.2, 5.6 7.1 Z" }
          }
          // shoulders
          ShapePath {
            fillColor: root.fg; strokeColor: "transparent"
            PathSvg { path: "M6.7 11.4 L 9.3 11.4 L 9.6 12.5 C 11.8 12.9, 13.4 13.9, 13.6 15.2 L 2.4 15.2 C 2.6 13.9, 4.2 12.9, 6.4 12.5 Z" }
          }
          // headphones, painted only while a stream runs. Without them the hair
          // dome underneath is already whole: the "gap" was only these
          // background-colored strokes carving it.
          readonly property color phones: root.playing ? root.fg : "transparent"
          readonly property color phoneRim: root.playing ? root.ground : "transparent"

          // headband: an arc concentric with the head, background-colored gap under a foreground stroke
          ShapePath {
            fillColor: "transparent"; strokeColor: shape.phoneRim; strokeWidth: 2.0; capStyle: ShapePath.RoundCap
            PathSvg { path: "M3.2 6.6 A4.9 4.9 0 0 1 12.8 6.6" }
          }
          ShapePath {
            fillColor: "transparent"; strokeColor: shape.phones; strokeWidth: 1.0; capStyle: ShapePath.RoundCap
            PathSvg { path: "M3.2 6.6 A4.9 4.9 0 0 1 12.8 6.6" }
          }
          // cans, each with a background-colored rim so they read against the hair
          ShapePath {
            fillColor: shape.phoneRim; strokeColor: "transparent"
            PathSvg { path: "M2.9 6.4 H3.5 A1.3 1.3 0 0 1 4.8 7.7 V9.5 A1.3 1.3 0 0 1 3.5 10.8 H2.9 A1.3 1.3 0 0 1 1.6 9.5 V7.7 A1.3 1.3 0 0 1 2.9 6.4 Z M12.5 6.4 H13.1 A1.3 1.3 0 0 1 14.4 7.7 V9.5 A1.3 1.3 0 0 1 13.1 10.8 H12.5 A1.3 1.3 0 0 1 11.2 9.5 V7.7 A1.3 1.3 0 0 1 12.5 6.4 Z" }
          }
          ShapePath {
            fillColor: shape.phones; strokeColor: "transparent"
            PathSvg { path: "M3.0 6.8 H3.4 A1.0 1.0 0 0 1 4.4 7.8 V9.4 A1.0 1.0 0 0 1 3.4 10.4 H3.0 A1.0 1.0 0 0 1 2.0 9.4 V7.8 A1.0 1.0 0 0 1 3.0 6.8 Z M12.6 6.8 H13.0 A1.0 1.0 0 0 1 14.0 7.8 V9.4 A1.0 1.0 0 0 1 13.0 10.4 H12.6 A1.0 1.0 0 0 1 11.6 9.4 V7.8 A1.0 1.0 0 0 1 12.6 6.8 Z" }
          }
        }
      }
    }
  }

  // One cursor for the whole list (CursorSurface contract): mouse hover sets
  // it here at the root, rows only read it, so exactly one row is lit.
  property int cursorIndex: -1
  onPopupOpenChanged: {
    if (popupOpen) { if (!listProc.running) listProc.running = true; seedCursor(); checkPad() }
    else cursorIndex = -1
  }

  // KeyboardPanel, not PopupCard: an xdg-popup only receives keys after a
  // click routes focus through its parent, so a keyboard-summoned list needs
  // KeyboardPanel's focus prime (same reason as the workspace rename dialog).
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: keys
    contentWidth: popup.fittedContentWidth(Style.space(480))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTextKey: function(t, modifiers) { if (t === "v" && !modifiers) root.nextViz() }

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: root.streams.length ? "Lofi Girl live streams" : "Fetching streams..."
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        bottomPadding: Style.space(6)
      }

      Repeater {
        model: root.streams

        CursorSurface {
          id: row
          required property var modelData
          required property int index
          readonly property bool selected: root.running && modelData.id === root.currentId
          readonly property bool hovered: root.cursorIndex === index
          // The current station while it is audible. A paused current station
          // is still `selected`, but a click on it plays rather than stops.
          readonly property bool sounding: selected && root.playing

          width: column.width
          height: label.implicitHeight + Style.space(10)
          foreground: root.bar.foreground
          hasCursor: hovered
          current: selected

          Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: row.borderLeft + Style.space(8)
            anchors.rightMargin: row.borderRight + Style.space(8)
            spacing: Style.space(8)

            // playing row: play glyph; hovered playing row: stop glyph (click stops);
            // paused current row: pause glyph; any other hovered row: play glyph
            // (click plays); otherwise blank.
            Text {
              id: glyph
              textFormat: Text.PlainText
              width: Style.space(14)
              horizontalAlignment: Text.AlignHCenter
              anchors.verticalCenter: parent.verticalCenter
              text: row.sounding ? (row.hovered ? "\uf04d" : "\uf04b")
                    : row.hovered ? "\uf04b" : (row.selected ? "\uf04c" : "")
              color: row.selected ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              id: label
              textFormat: Text.PlainText
              width: parent.width - glyph.width - hint.width - parent.spacing * 2
              text: row.modelData.title
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: row.selected
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: hint
              textFormat: Text.PlainText
              text: row.hovered ? (row.sounding ? "stop" : "play") : ""
              width: implicitWidth
              color: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.cursorIndex = row.index
            onExited: if (root.cursorIndex === row.index) root.cursorIndex = -1
            onClicked: {
              root.act(row.sounding ? ["stop"] : ["play", row.modelData.id])
              root.popupOpen = false
            }
          }
        }
      }

      // ---- MacroPad: what the blank keys hold, and the pad's screen --------
      Item { visible: root.pad !== null; width: 1; height: Style.space(8) }
      PanelSeparator { visible: root.pad !== null; foreground: root.bar.foreground }
      Item { visible: root.pad !== null; width: 1; height: Style.space(6) }

      Text {
        visible: root.pad !== null
        textFormat: Text.PlainText
        text: root.pad && root.pad.link ? "MacroPad" : "MacroPad (not connected)"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        bottomPadding: Style.space(4)
      }

      // Laid out like the pad: three columns, four rows. Position is what
      // identifies a key; the swatch only repeats the colour of its light.
      Grid {
        id: legend
        visible: root.pad !== null
        columns: 3
        width: column.width
        columnSpacing: Style.space(8)
        rowSpacing: Style.space(2)

        Repeater {
          model: root.pad ? root.pad.keys : []

          Item {
            id: cell
            required property var modelData
            readonly property bool preset: modelData.kind === "preset"
            readonly property bool held: preset && !!modelData.title
            readonly property bool live: held && !!modelData.live
            readonly property bool sounding: held && !!modelData.playing

            width: (legend.width - legend.columnSpacing * 2) / 3
            height: Style.space(30)

            // Filled = the key holds a station; outline = empty or a plain
            // control key; faded = held, but that station is off the air.
            Rectangle {
              id: swatch
              width: Style.space(12)
              height: width
              radius: Style.space(3)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              color: cell.held ? root.keyColor(cell.modelData.color) : "transparent"
              opacity: cell.held && !cell.live ? 0.35 : 1
              border.width: 1
              border.color: root.dimText
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: swatch.right
              anchors.leftMargin: Style.space(6)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.keyLabel(cell.modelData)
              color: cell.live || !cell.preset ? root.bar.foreground : root.dimText
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: cell.sounding
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
          }
        }
      }

      Text {
        visible: root.pad !== null
        textFormat: Text.PlainText
        width: column.width
        text: "Tap a key to play it, tap again to stop. Hold a key about a second to save the station that is on."
        color: root.dimText
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        topPadding: Style.space(4)
        bottomPadding: Style.space(8)
      }

      Row {
        visible: root.pad !== null
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: "Screen"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          rightPadding: Style.space(4)
        }

        Repeater {
          model: root.padViz

          CursorSurface {
            id: chip
            required property string modelData
            required property int index
            // Cursor slots continue after the stations (see moveCursor).
            readonly property int slot: root.streams.length + index
            readonly property bool chosen: root.pad !== null && root.pad.viz === modelData

            width: chipLabel.implicitWidth + Style.space(20)
            height: chipLabel.implicitHeight + Style.space(10)
            foreground: root.bar.foreground
            hasCursor: root.cursorIndex === slot
            current: chosen
            bordered: true

            Text {
              id: chipLabel
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: chip.modelData
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: chip.chosen
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.cursorIndex = chip.slot
              onExited: if (root.cursorIndex === chip.slot) root.cursorIndex = -1
              onClicked: root.setViz(chip.modelData)
            }
          }
        }
      }

    }
    }
  }
}
