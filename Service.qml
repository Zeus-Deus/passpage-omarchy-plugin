import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Talks to the passpage API with the bearer key from ~/.config/passpage/key.
// Every request is one curl run that reads its arguments from a config file
// on stdin, so the key and passcodes never reach argv. State here is plain
// JSON snapshots — rows bind to `active` / `expired`, never to live objects.
//
// Threat model: baseUrl is user-configurable, so the whole HTTP response is
// treated as attacker-controlled, and so is a maliciously-pointed endpoint.
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
  property bool keyUnsafe: false     // file exists but fails a safety guard (perms/owner/type)

  readonly property bool keyMissing: keyChecked && apiKey === "" && !keyInvalid && !keyUnsafe

  // baseUrl is validated to a single plain http(s) URL (https required unless
  // the host is loopback). An empty result means the configured value is
  // unusable — we fail closed rather than silently talk to production.
  // A blank or whitespace-only setting is treated like unset (fall back to
  // the default) rather than half-classified as an invalid URL.
  readonly property string baseUrlSetting: {
    var v = String(setting("baseUrl", "https://passpage.space"))
    return v.trim() === "" ? "https://passpage.space" : v
  }
  readonly property string baseUrl: Model.validatedBaseUrl(baseUrlSetting)
  readonly property bool baseUrlInvalid: baseUrl === ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 30, 3600)
  readonly property bool busy: keyProcess.running || listProcess.running || actionProcess.running
  readonly property int activeCount: active.length
  readonly property int expiredCount: expired.length

  // Bumped whenever credentials, target, or server-side state change, so a
  // list response that started under stale conditions is discarded instead of
  // overwriting newer local state (e.g. a delete that already happened).
  property int generation: 0

  // Ticks once a minute so "expires in 45m" stays honest without a refetch.
  property double nowMs: Date.now()

  signal sharesUpdated()
  signal actionFinished(string kind, string slug, bool ok)

  // Target changed: stale rows from the old server must never drive delete or
  // passcode actions against the new one. generation++ also discards any
  // in-flight response that started under the old target.
  onBaseUrlChanged: {
    generation++
    clearShares()
    Qt.callLater(root.refresh)
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // Reassign the row models only when membership or a displayed field really
  // changed: an assignment resets the Repeater and rebuilds every ShareRow
  // delegate, which would churn QML objects on every minute tick / poll and
  // destroy an open passcode editor (silently wiping typed input). soonCount
  // is a plain int and may always update.
  function recompute() {
    nowMs = Date.now()
    var parts = Model.partition(shares, nowMs)
    if (!Model.sameShareLists(parts.active, active)) active = parts.active
    if (!Model.sameShareLists(parts.expired, expired)) expired = parts.expired
    soonCount = Model.countExpiringSoon(parts.active, nowMs)
  }

  // Drop all share-derived state — used when the credential or target
  // changes, so stale rows can never feed actions in the new context.
  function clearShares() {
    shares = []
    active = []
    expired = []
    soonCount = 0
    loaded = false
    error = ""
    sharesUpdated()
  }

  function shareBySlug(slug) {
    for (var i = 0; i < shares.length; i++) if (shares[i].slug === slug) return shares[i]
    return null
  }

  // Re-read the key (bounded, guarded) then list. The key read replaces a
  // FileView so a hostile file at the fixed path can't be slurped whole.
  function refresh() {
    if (keyProcess.running || listProcess.running) return
    if (baseUrlInvalid) {
      loading = false
      error = "Configured passpage URL is invalid"
      return
    }
    keyProcess.pendingList = true
    keyProcess.running = true
  }

  function startList() {
    if (apiKey === "") { loading = false; return }
    loading = true
    listProcess.generation = generation
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
    var url = share ? Model.boundedUrl(share.url) : ""
    if (url === "") return
    // URL as a positional arg ($1), never interpolated into the script text —
    // no quoting to get wrong even though share.url is endpoint-controlled.
    Quickshell.execDetached(["bash", "-c", "printf %s \"$1\" | wl-copy", "wl-copy", url])
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
    if (value.length > Model.MAX_PASSCODE) value = value.slice(0, Model.MAX_PASSCODE)
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
    actionProcess.generation = generation
    actionProcess.config = config
    busySlug = slug
    actionProcess.running = true
  }

  // head closing the pipe makes curl fail its write (exit 23) under pipefail;
  // 63 is curl's own max-filesize, 141 a raw SIGPIPE. The length check is a
  // best-effort fallback only: it counts UTF-16 chars against a byte cap, so
  // it under-counts multibyte text — the exit codes (backed by max-filesize
  // and the head -c producer cap) are the real gates.
  function oversized(exitCode, output) {
    return exitCode === 23 || exitCode === 63 || exitCode === 141
      || String(output || "").length >= Model.MAX_RESPONSE_BYTES
  }

  function networkError(stderr) {
    var text = Model.sanitizeText(String(stderr || ""), 160)
    return text === "" ? Model.errorMessage(0, "") : "Network error — " + text
  }

  function finishList(exitCode, output, stderr, requestGeneration) {
    loading = false
    // Conditions changed while this was in flight — success or failure, the
    // result is stale and must not touch state (not even the sticky error
    // line, which now describes the new target); redo instead.
    if (requestGeneration !== generation) { Qt.callLater(root.refresh); return }
    if (oversized(exitCode, output)) { error = Model.errorMessage(413, ""); return }
    // Any other non-zero exit = truncated/failed transfer; never trust a
    // partial body (a timed-out `[` must not read as an empty list).
    if (exitCode !== 0) { error = networkError(stderr); return }
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
  }

  function finishAction(kind, slug, exitCode, output, stderr, requestGeneration) {
    busySlug = ""
    // The action started under an old baseUrl/key (in flight up to 15 s): its
    // outcome belongs to the old target and must not mutate rows, show a
    // status, or bump generation under the new one. Reconcile by refetching.
    if (requestGeneration !== generation) { Qt.callLater(root.refresh); return }
    if (oversized(exitCode, output)) {
      showActionError(Model.errorMessage(413, ""))
      actionFinished(kind, slug, false)
      return
    }
    if (exitCode !== 0) {
      showActionError(networkError(stderr))
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
    // The server state changed; invalidate any in-flight list.
    generation++
    if (kind === "delete") {
      var next = []
      for (var i = 0; i < shares.length; i++) if (shares[i].slug !== slug) next.push(shares[i])
      shares = next
      showStatus("Deleted " + label)
    } else {
      var updated = updateForSlug(result.body, slug)
      if (updated) {
        var replaced = []
        for (var j = 0; j < shares.length; j++) {
          var s = shares[j]
          replaced.push(s.slug === slug ? updated : s)
        }
        shares = replaced
      } else {
        // Success server-side but the body wasn't usable — reconcile by refetch.
        Qt.callLater(root.refresh)
      }
      showStatus((kind === "lock" ? "Passcode set on " : "Passcode removed from ") + label)
    }
    recompute()
    sharesUpdated()
    actionFinished(kind, slug, true)
  }

  // Guarded key read: regular file, not a symlink, owned by us, mode exactly
  // 600 or 400 (anything else — group/other bits, write-only 200 — rejects
  // the file rather than reading nothing), first 4 KiB only, and the read
  // itself runs under `timeout 2` so a file swapped for a blocking special
  // file between check and read can never hang this process (which would
  // permanently block refresh()). The first output line is a marker —
  // "ok" / "unsafe" / "missing" — so the UI can tell a missing file from an
  // unsafe one; the key bytes follow only after "ok". The path is fixed and
  // secrets travel over stdout only, never argv.
  Process {
    id: keyProcess
    property bool pendingList: false
    command: ["bash", "-c",
      "f=\"$HOME/.config/passpage/key\"; if [ ! -e \"$f\" ] && [ ! -L \"$f\" ]; then echo missing; exit 0; fi; if [ -f \"$f\" ] && [ ! -L \"$f\" ] && [ -O \"$f\" ]; then m=$(stat -c %a -- \"$f\" 2>/dev/null); case \"$m\" in 600|400) echo ok; timeout 2 head -c 4096 -- \"$f\";; *) echo unsafe;; esac; else echo unsafe; fi"]
    stdout: StdioCollector { id: keyOut; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(keyOut.text || "")
      var nl = out.indexOf("\n")
      var marker = (nl === -1 ? out : out.slice(0, nl)).trim()
      var raw = nl === -1 ? "" : out.slice(nl + 1)
      var next = ""
      if (marker === "ok") {
        root.keyUnsafe = false
        next = Model.sanitizeKey(raw)
        root.keyInvalid = next === "" && raw.trim() !== ""
      } else {
        // "missing", "unsafe", or anything unexpected (script failure):
        // no usable key. Unknown output fails closed as unsafe.
        root.keyUnsafe = marker !== "missing"
        root.keyInvalid = false
      }
      if (next !== root.apiKey) {
        // Credential changed (including to none): stale rows must never
        // drive actions under the new credential. In-flight list responses
        // are additionally discarded by the generation bump.
        root.apiKey = next
        root.generation++
        root.clearShares()
      }
      root.keyChecked = true
      if (pendingList) {
        pendingList = false
        if (root.apiKey !== "") root.startList()
        else { root.loading = false; root.error = "" }
      }
    }
  }

  // The response ceiling lives outside the shell process. `-q` (first arg)
  // ignores ~/.curlrc; `--globoff` stops `{}`/`[]` in a hostile baseUrl from
  // fanning one request into many (which would send the bearer token to every
  // globbed host). stdout/stderr each pass through `head -c`, so with pipefail
  // an oversized body makes curl fail its write and the pipeline exits 23/141.
  readonly property var curlCommand: ["bash", "-c",
    "set -o pipefail; exec 2> >(head -c " + Model.MAX_STDERR_BYTES + " >&2); exec curl -q --globoff --config - | head -c " + Model.MAX_RESPONSE_BYTES]

  Process {
    id: listProcess
    property string config: ""
    property int generation: 0
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
    onExited: function(exitCode) { root.finishList(exitCode, listOut.text, listErr.text, generation) }
  }

  Process {
    id: actionProcess
    property string kind: ""
    property string slug: ""
    property string config: ""
    property int generation: 0
    command: root.curlCommand
    stdinEnabled: true
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onRunningChanged: if (!running) config = ""
    onStarted: {
      write(config)
      config = ""
      stdinEnabled = false
      stdinEnabled = true
    }
    onExited: function(exitCode) { root.finishAction(kind, slug, exitCode, actionOut.text, actionErr.text, generation) }
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

  // Background poll keeps the bar count honest while the panel is closed, and
  // re-reads the key so a freshly-saved key is picked up within one interval.
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
}
