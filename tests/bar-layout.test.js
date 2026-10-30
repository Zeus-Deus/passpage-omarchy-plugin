// Native sizing regression against the installed Quattro kit (no live shell,
// credentials or network). Run PASSPAGE_NATIVE_TESTS=1 node --test tests/bar-layout.test.js.
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")

const sdk = process.env.OMARCHY_SHELL_DIR || "/usr/share/omarchy/shell"

// Extract the shipped button, not a second implementation of its layout.
function block(source, type, id) {
  const start = source.indexOf(`  ${type} {\n    id: ${id}\n`)
  assert.notEqual(start, -1, `${type} ${id} exists`)
  const end = source.indexOf("\n  }", start)
  assert.notEqual(end, -1, `${type} ${id} closes`)
  return source.slice(start, end + 4)
}

test("bar count stays readable and does not shrink the icon", {
  skip: process.env.PASSPAGE_NATIVE_TESTS !== "1"
}, () => {
  const dir = fs.mkdtempSync(path.join(process.env.PASSPAGE_TEST_ARTIFACT_DIR || os.tmpdir(), "passpage-bar-"))
  for (const name of ["home", "run", "config", "cache", "data"]) {
    fs.mkdirSync(path.join(dir, name), { mode: 0o700 })
  }
  for (const name of ["Ui", "Commons"]) fs.symlinkSync(path.join(sdk, name), path.join(dir, name))
  const panel = fs.readFileSync(path.join(__dirname, "../Panel.qml"), "utf8")
  fs.writeFileSync(path.join(dir, "Panel.snapshot.txt"), panel)
  fs.writeFileSync(path.join(dir, "shell.qml"), `
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
FloatingWindow {
  id: window
  implicitWidth: 240
  implicitHeight: 100
  color: "#202020"
  Item {
    id: root
    property var bar: null
    property string countText: "40"
    property string heroMeta: "Synthetic sizing fixture"
    property string fontFamily: Style.font.family
    property color barForeground: "white"
    property color urgent: "red"
    property bool attention: false
    function toggle() {}
    width: button.implicitWidth
    height: button.implicitHeight
    anchors.centerIn: parent
    QtObject { id: passpage; function refresh() {} }
${block(panel, "TextMetrics", "countMetrics")}
${block(panel, "BarIconButton", "button")}
  }
  property var counts: ["", "1", "40", "500"]
  property var sizes: [12, 18, 24]
  property int sample: 0
  function texts(item, value, result) {
    if (item instanceof Text && item.visible && item.text === value) result.push(item)
    for (var i = 0; i < item.children.length; i++) texts(item.children[i], value, result)
  }
  Timer {
    interval: 150
    running: true
    repeat: true
    onTriggered: {
      var count = window.counts[window.sample % window.counts.length]
      var size = window.sizes[Math.floor(window.sample / window.counts.length)]
      if (root.countText !== count || Style.fontBaseSize !== size) {
        root.countText = count
        Style.fontBaseSize = size
        return
      }
      var glyphs = [], labels = []
      window.texts(root, "󰈙", glyphs)
      if (count !== "") window.texts(root, count, labels)
      var glyph = glyphs[0]
      var label = labels[0]
      var p0 = glyph ? glyph.mapToItem(root, 0, 0) : Qt.point(0, 0)
      var p1 = glyph ? glyph.mapToItem(root, 1, 1) : Qt.point(0, 0)
      var l0 = label ? label.mapToItem(root, 0, 0) : Qt.point(0, 0)
      var l1 = label ? label.mapToItem(root, 1, 1) : Qt.point(0, 0)
      console.log("BAR_SAMPLE " + JSON.stringify({ count: count, baseSize: size,
        glyphScale: p1.x - p0.x, glyphCount: glyphs.length,
        countScale: label ? l1.x - l0.x : null, countCount: labels.length,
        countFont: label ? label.font.pixelSize : null,
        countLeft: label ? l0.x : null,
        countRight: label ? label.mapToItem(root, label.width, 0).x : null,
        width: root.width, height: root.height,
        iconSize: Style.bar.iconSize }))
      window.sample++
      if (window.sample === window.counts.length * window.sizes.length) Qt.quit()
    }
  }
}
`)
  const runtime = fs.mkdtempSync(path.join(os.tmpdir(), "pb-"))
  const env = {
    LANG: "C.UTF-8",
    PATH: "/usr/bin", HOME: path.join(dir, "home"),
    XDG_RUNTIME_DIR: runtime, XDG_CONFIG_HOME: path.join(dir, "config"),
    XDG_CACHE_HOME: path.join(dir, "cache"), XDG_DATA_HOME: path.join(dir, "data"),
    TMPDIR: dir, QT_QPA_PLATFORM: "offscreen", QT_QUICK_BACKEND: "software",
    QML_DISABLE_DISK_CACHE: "1"
  }
  const run = spawnSync("/usr/bin/qs", ["-p", dir, "--no-color"], {
    env, encoding: "utf8", timeout: 15000
  })
  fs.rmSync(runtime, { recursive: true, force: true })
  const output = (run.stdout || "") + (run.stderr || "")
  fs.writeFileSync(path.join(dir, "run.log"), output)
  assert.equal(run.status, 0, output)
  assert.doesNotMatch(output, /(?:TypeError|ReferenceError|Unable to load configuration|Binding loop)/, output)
  const samples = [...output.matchAll(/BAR_SAMPLE (\{[^\n]+\})/g)].map(m => JSON.parse(m[1]))
  assert.equal(samples.length, 12, output)
  console.log(JSON.stringify(samples))
  for (const size of [12, 18, 24]) {
    const group = samples.filter(s => s.baseSize === size)
    const withoutCount = group.find(s => s.count === "")
    for (const sample of group) {
      assert.equal(sample.glyphCount, 1)
      assert.ok(Math.abs(sample.glyphScale - withoutCount.glyphScale) < 0.01,
        `icon shrank with count ${sample.count} at base ${size}: ${sample.glyphScale} vs ${withoutCount.glyphScale}`)
      if (sample.count !== "") {
        assert.equal(sample.countCount, 1)
        assert.ok(Math.abs(sample.countScale - 1) < 0.01,
          `count ${sample.count} was scaled to ${sample.countScale}`)
        assert.ok(sample.countFont >= 10 * size / 12, "readable theme-scaled count")
        assert.ok(sample.countLeft >= 0 && sample.countRight <= sample.width, "count fits the slot")
      }
    }
  }
})
