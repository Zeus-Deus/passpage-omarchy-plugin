import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Talks to the passpage API with the bearer key from ~/.config/passpage/key.
// Every request is one curl run that reads its arguments from a config file
// on stdin, so the key and passcodes never reach argv. State here is plain
// JSON snapshots — rows bind to `active` / `expired`, never to live objects.
Item {
  id: root

  property var settings: ({})

  // Wire state
  property var shares: []
  property var active: []
  property var expired: []
  property int soonCount: 0
  property bool loaded: false
  property bool loading: false
  property string error: ""          // sticky list error (401, network, …)
  property string actionStatus: ""   // transient feedback: "Link copied", …
  property string actionError: ""    // transient action failure
  property string busySlug: ""       // share with an in-flight delete/passcode
  property string copiedSlug: ""     // row whose copy button briefly shows a check

  // Key state
  property string apiKey: ""
  property bool keyChecked: false
  readonly property bool keyMissing: keyChecked && apiKey === ""
  readonly property string keyPath: Quickshell.env("HOME") + "/.config/passpage/key"

  readonly property string baseUrl: Model.trimBaseUrl(setting("baseUrl", "https://passpage.space"))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 30, 3600)
  readonly property bool busy: listProcess.running || actionProcess.running
  readonly property int activeCount: active.length
  readonly property int expiredCount: expired.length

  // Ticks once a minute so "expires in 45m" stays honest without a refetch.
  property double nowMs: Date.now()

  signal sharesUpdated()
  signal actionFinished(string kind, string slug, bool ok)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function recompute() {
    nowMs = Date.now()
    var parts = Model.partition(shares, nowMs)
    active = parts.active
    expired = parts.expired
    soonCount = Model.countExpiringSoon(parts.active, nowMs)
  }

  function shareBySlug(slug) {
    for (var i = 0; i < shares.length; i++) if (shares[i].slug === slug) return shares[i]
    return null
  }

  function refresh() {
    if (listProcess.running) return
    keyFile.reload()
    if (apiKey === "") {
      keyChecked = true
      loading = false
      return
    }
    loading = true
    listProcess.config = Model.curlConfig({ url: Model.listUrl(baseUrl), key: apiKey })
    listProcess.running = true
  }

  function showStatus(text) {
    actionError = ""
    actionStatus = text
    statusTimer.restart()
  }

  function showActionError(text) {
    actionStatus = ""
    actionError = text
    statusTimer.restart()
  }

  function copyLink(share) {
    if (!share || !share.url) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(share.url) + " | wl-copy"])
    // Feedback lives on the row's copy button (it turns into a check), not in
    // the status line — less noise for the most common action.
    copiedSlug = share.slug
    copiedTimer.restart()
  }

  function openInBrowser(share) {
    if (!share || !share.url) return
    Quickshell.execDetached(["omarchy-launch-browser", share.url])
  }

  function deleteShare(share) {
    if (!share || actionProcess.running || apiKey === "") return
    startAction("delete", share.slug, Model.curlConfig({
      url: Model.deleteUrl(baseUrl, share.slug), key: apiKey, method: "DELETE"
    }))
  }

  // Empty passcode removes protection (the API treats "" and null the same).
  function setPasscode(share, passcode) {
    if (!share || actionProcess.running || apiKey === "") return
    var value = String(passcode || "")
    startAction(value === "" ? "unlock" : "lock", share.slug, Model.curlConfig({
      url: Model.passcodeUrl(baseUrl, share.slug), key: apiKey, method: "PATCH",
      json: { passcode: value === "" ? null : value }
    }))
  }

  function startAction(kind, slug, config) {
    actionProcess.kind = kind
    actionProcess.slug = slug
    actionProcess.config = config
    busySlug = slug
    actionProcess.running = true
  }

  function finishList(exitCode, output, stderr) {
    loading = false
    var result = Model.parseCurlOutput(output)
    if (result.status === 200) {
      var data = Model.parseJson(result.body)
      if (data instanceof Array) {
        shares = Model.normaliseShares(data)
        recompute()
        loaded = true
        error = ""
        sharesUpdated()
        return
      }
      error = "Unexpected response from passpage"
      return
    }
    error = Model.errorMessage(result.status, result.status === 0 ? "" : result.body)
    if (result.status === 0 && String(stderr || "").trim() !== "") error = "Network error — " + String(stderr).trim()
  }

  function finishAction(kind, slug, output) {
    busySlug = ""
    var result = Model.parseCurlOutput(output)
    var ok = result.status >= 200 && result.status < 300
    var share = shareBySlug(slug)
    var label = share ? Model.displayTitle(share) : slug
    if (!ok) {
      showActionError(Model.errorMessage(result.status, result.body))
      actionFinished(kind, slug, false)
      return
    }
    if (kind === "delete") {
      var next = []
      for (var i = 0; i < shares.length; i++) if (shares[i].slug !== slug) next.push(shares[i])
      shares = next
      showStatus("Deleted " + label)
    } else {
      var updated = Model.parseJson(result.body)
      var replaced = []
      for (var j = 0; j < shares.length; j++) {
        var s = shares[j]
        if (s.slug === slug && updated) replaced.push(Model.normaliseShares([updated])[0] || s)
        else replaced.push(s)
      }
      shares = replaced
      showStatus((kind === "lock" ? "Passcode set on " : "Passcode removed from ") + label)
    }
    recompute()
    sharesUpdated()
    actionFinished(kind, slug, true)
  }

  FileView {
    id: keyFile
    path: root.keyPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var wasMissing = root.apiKey === ""
      root.apiKey = String(text() || "").replace(/\s+/g, "")
      root.keyChecked = true
      if (root.apiKey !== "" && (wasMissing || root.error !== "")) Qt.callLater(root.refresh)
    }
    onLoadFailed: {
      root.apiKey = ""
      root.keyChecked = true
    }
  }

  Process {
    id: listProcess
    property string config: ""
    command: ["curl", "--config", "-"]
    stdinEnabled: true
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onStarted: {
      write(config)
      config = ""
      // curl keeps reading stdin until EOF; closing it is what lets it run.
      stdinEnabled = false
      stdinEnabled = true
    }
    onExited: function(exitCode) { root.finishList(exitCode, listOut.text, listErr.text) }
  }

  Process {
    id: actionProcess
    property string kind: ""
    property string slug: ""
    property string config: ""
    command: ["curl", "--config", "-"]
    stdinEnabled: true
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) config = ""
    onStarted: {
      write(config)
      config = ""
      stdinEnabled = false
      stdinEnabled = true
    }
    onExited: function(exitCode) { root.finishAction(kind, slug, actionOut.text) }
  }

  Timer {
    id: copiedTimer
    interval: 1400
    onTriggered: root.copiedSlug = ""
  }

  Timer {
    id: statusTimer
    interval: 4000
    onTriggered: { root.actionStatus = ""; root.actionError = "" }
  }

  // Background poll keeps the bar count honest while the panel is closed.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.recompute()
  }

  // The first FileView read can race shell startup; one delayed retry covers it.
  Timer {
    interval: 1500
    running: true
    onTriggered: if (!root.loaded && !listProcess.running) root.refresh()
  }
}
