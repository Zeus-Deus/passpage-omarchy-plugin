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
  property bool keyInvalid: false    // file exists but is not one printable token
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
    // URL as a positional arg ($1), never interpolated into the script text —
    // no quoting to get wrong even though share.url is endpoint-controlled.
    Quickshell.execDetached(["bash", "-c", "printf %s \"$1\" | wl-copy", "wl-copy", share.url])
    // Feedback lives on the row's copy button (it turns into a check), not in
    // the status line — less noise for the most common action.
    copiedSlug = share.slug
    copiedTimer.restart()
  }

  function openInBrowser(share) {
    var url = share ? Model.boundedUrl(share.url) : ""
    if (url === "") return   // https?:// only — blocks file:, a leading '-', etc.
    Quickshell.execDetached(["omarchy-launch-browser", url])
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

  // Accept the PATCH response only if it re-describes the same slug we acted on;
  // a hostile endpoint must not repaint a row with a different share's data.
  function updateForSlug(body, slug) {
    var norm = Model.normaliseShares([Model.parseJson(body)])
    return norm.length > 0 && norm[0].slug === slug ? norm[0] : null
  }

  function startAction(kind, slug, config) {
    actionProcess.kind = kind
    actionProcess.slug = slug
    actionProcess.config = config
    busySlug = slug
    actionProcess.running = true
  }

  // head closing the pipe kills curl with SIGPIPE (141) under pipefail; 63 is
  // curl's own max-filesize. The length check is a belt-and-braces fallback.
  function oversized(exitCode, output) {
    return exitCode === 141 || exitCode === 63 || String(output || "").length >= Model.MAX_RESPONSE_BYTES
  }

  function finishList(exitCode, output, stderr) {
    loading = false
    if (oversized(exitCode, output)) { error = Model.errorMessage(413, ""); return }
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

  function finishAction(kind, slug, exitCode, output) {
    busySlug = ""
    if (oversized(exitCode, output)) {
      showActionError(Model.errorMessage(413, ""))
      actionFinished(kind, slug, false)
      return
    }
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
      var updated = updateForSlug(result.body, slug)
      var replaced = []
      for (var j = 0; j < shares.length; j++) {
        var s = shares[j]
        replaced.push(s.slug === slug && updated ? updated : s)
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
      // A real key is ~46 chars; anything large is not ours (and guards against
      // a huge/garbage file at the fixed key path growing the shell).
      var raw = String(text() || "")
      if (raw.length > 4096) raw = ""
      root.apiKey = Model.sanitizeKey(raw)
      root.keyInvalid = root.apiKey === "" && raw.trim() !== ""
      root.keyChecked = true
      if (root.apiKey !== "" && (wasMissing || root.error !== "")) Qt.callLater(root.refresh)
    }
    onLoadFailed: {
      root.apiKey = ""
      root.keyInvalid = false
      root.keyChecked = true
    }
  }

  // The response ceiling lives outside the shell process: curl's stdout and
  // stderr each pass through `head -c`, so the bytes that reach Quickshell
  // physically cannot exceed the caps. When head closes early, curl dies on
  // SIGPIPE and the trailing status line never arrives — finish*() treats a
  // body at the cap as "too large". (curl's own max-filesize in the config
  // only helps when the server announces a length; a chunked stream walks
  // straight past it, and Qt-side parsers buffer before they emit.)
  // `-q` must be curl's first argument: it stops ~/.curlrc from being read,
  // where an inherited `url`, `upload-file` or `insecure` line would receive
  // our bearer header, exfiltrate files, or weaken TLS.
  //
  // stdout/stderr each pass through `head -c` so the bytes reaching the shell
  // are capped at the producer. With `pipefail`, when head hits the cap and
  // closes the pipe curl dies on SIGPIPE and the pipeline exits 141 (or 63 if
  // curl's own max-filesize tripped first) — that is how finish*() detects an
  // oversized response, independent of the body's character encoding.
  readonly property var curlCommand: ["bash", "-c",
    "set -o pipefail; exec 2> >(head -c " + Model.MAX_STDERR_BYTES + " >&2); exec curl -q --config - | head -c " + Model.MAX_RESPONSE_BYTES]

  Process {
    id: listProcess
    property string config: ""
    command: root.curlCommand
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
    command: root.curlCommand
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
    onExited: function(exitCode) { root.finishAction(kind, slug, exitCode, actionOut.text) }
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
