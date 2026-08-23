// Pure helpers for the passpage panel. No Qt imports so `node --test tests/model.test.js`
// can exercise every branch. Keep anything that needs Quickshell in Service.qml.

var SOON_MS = 24 * 60 * 60 * 1000

// Ceilings on what we accept from the network. baseUrl is user-configurable,
// so a broken or hostile endpoint must not be able to grow the shell process:
// curl refuses bodies over MAX_RESPONSE_BYTES, Service.qml kills curl if its
// stdout/stderr exceed the caps while streaming, and normaliseShares bounds
// the array and every field before the data reaches QML bindings.
var MAX_RESPONSE_BYTES = 2 * 1024 * 1024   // ~40x a 100-share listing
var MAX_STDERR_BYTES = 16 * 1024
var MAX_SHARES = 500
var MAX_SLUG = 64
var MAX_URL = 2048
var MAX_TITLE = 140                          // the backend's own limit
var MAX_TIMESTAMP = 64
var MAX_PASSCODE = 256
var SLUG_RE = /^[A-Za-z0-9_-]+$/

// curl is invoked with `write-out = "\n%{http_code}"`, so the last line of
// stdout is the status and everything before it is the body.
function parseCurlOutput(raw) {
  var text = String(raw || "")
  var cut = text.lastIndexOf("\n")
  if (cut === -1) return { status: 0, body: text }
  var status = parseInt(text.slice(cut + 1).trim(), 10)
  if (!isFinite(status)) return { status: 0, body: text }
  return { status: status, body: text.slice(0, cut) }
}

function parseJson(body) {
  try { return JSON.parse(String(body || "")) } catch (e) { return null }
}

// The API's error envelope is {"detail": "..."}; fall back to a status-based
// message when the body is empty or not JSON (e.g. a proxy 502 page).
function errorMessage(status, body) {
  var data = parseJson(body)
  if (data && typeof data.detail === "string" && data.detail !== "") {
    var detail = sanitizeText(data.detail, 200)
    if (detail !== "") return detail
  }
  if (status === 0) return "Network error — is passpage.space reachable?"
  if (status === 413) return "Response too large — refused"
  if (status === 401) return "API key rejected"
  if (status === 404) return "Share not found"
  return "HTTP " + status
}

function expiresMs(share) {
  if (!share || share.expires_at === null || share.expires_at === undefined || share.expires_at === "") return null
  var ms = Date.parse(String(share.expires_at))
  return isFinite(ms) ? ms : null
}

// Mirrors the backend quota rule: expires_at IS NULL OR expires_at > now.
function isActive(share, nowMs) {
  var ms = expiresMs(share)
  return ms === null || ms > nowMs
}

function isExpiringSoon(share, nowMs) {
  var ms = expiresMs(share)
  return ms !== null && ms > nowMs && ms - nowMs <= SOON_MS
}

function boundedString(value, max) {
  if (typeof value !== "string") return ""
  return value.length > max ? value.slice(0, max) : value
}

// For remote text that ends up in QML Text items (directly or through kit
// components whose Text defaults to AutoText): strip control characters and
// markup-significant ones so a hostile endpoint cannot smuggle rich text —
// AutoText would otherwise render `<img src=…>` and fetch it, bypassing the
// curl caps. Also strips bidi overrides/isolates and zero-width characters
// (U+200B–200F, U+202A–202E, U+2066–2069, U+FEFF) so a title can't visually
// spoof what the user copies or deletes (e.g. RLO reversing "exe.gpj").
// Display-only; never applied to values sent back to the API.
function sanitizeText(value, max) {
  return boundedString(value, max)
    .replace(/[<>&\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, " ")
    .replace(/\s+/g, " ").trim()
}

// The API key travels into an HTTP header: exactly one printable token. Only
// surrounding whitespace is trimmed — internal whitespace means the file is
// not a key, so reject it rather than silently rewrite it into a different key.
function sanitizeKey(value) {
  var key = String(value || "").trim()
  return key.length > 0 && key.length <= 512 && /^[\x21-\x7e]+$/.test(key) ? key : ""
}

function boundedCount(value) {
  return typeof value === "number" && isFinite(value) && value > 0 ? Math.floor(value) : 0
}

function boundedUrl(value) {
  var url = boundedString(value, MAX_URL)
  // No whitespace, control characters (including NUL and newlines), bidi
  // overrides or zero-width characters — these URLs are handed to wl-copy
  // and the browser as argv and must read as they act.
  if (/[\s\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/.test(url)) return ""
  return /^https?:\/\//.test(url) ? url : ""
}

// Normalise the wire list into what the rows need, newest first. Anything
// malformed is dropped or clamped; the output is always safe to bind to.
function normaliseShares(list) {
  if (!(list instanceof Array)) return []
  var out = []
  // Slugs key all row state (editor, busy, delete), so a hostile list must
  // not repeat one. Object.create(null): "__proto__" is a valid slug.
  var seen = Object.create(null)
  for (var i = 0; i < list.length && out.length < MAX_SHARES; i++) {
    var s = list[i]
    if (!s || typeof s !== "object") continue
    var slug = typeof s.slug === "string" ? s.slug : ""
    if (slug === "" || slug.length > MAX_SLUG || !SLUG_RE.test(slug)) continue
    if (seen[slug]) continue
    seen[slug] = true
    var expires = boundedString(s.expires_at, MAX_TIMESTAMP)
    out.push({
      slug: slug,
      url: boundedUrl(s.url),
      title: sanitizeText(s.title, MAX_TITLE),
      has_passcode: s.has_passcode === true,
      expires_at: expires === "" ? null : expires,
      created_at: boundedString(s.created_at, MAX_TIMESTAMP),
      view_count: boundedCount(s.view_count),
      track_views: s.track_views === true,
      file_count: boundedCount(s.file_count),
      size_bytes: boundedCount(s.size_bytes)
    })
  }
  out.sort(function(a, b) {
    var ta = Date.parse(a.created_at) || 0
    var tb = Date.parse(b.created_at) || 0
    return tb - ta
  })
  return out
}

// Field-wise equality of two normalised share lists (same shares, same
// order, same displayed fields). Service.qml uses this to skip reassigning
// the `active`/`expired` row models when nothing changed — an assignment
// resets the Repeater and rebuilds every row delegate, which would destroy
// an open passcode editor and churn objects on every minute tick / poll.
var SHARE_FIELDS = ["slug", "url", "title", "has_passcode", "expires_at",
  "created_at", "view_count", "track_views", "file_count", "size_bytes"]

function sameShareLists(a, b) {
  if (!(a instanceof Array) || !(b instanceof Array) || a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) {
    var x = a[i], y = b[i]
    if (x === y) continue
    if (!x || !y) return false
    for (var j = 0; j < SHARE_FIELDS.length; j++) {
      if (x[SHARE_FIELDS[j]] !== y[SHARE_FIELDS[j]]) return false
    }
  }
  return true
}

function partition(shares, nowMs) {
  var active = [], expired = []
  for (var i = 0; i < shares.length; i++) {
    (isActive(shares[i], nowMs) ? active : expired).push(shares[i])
  }
  return { active: active, expired: expired }
}

function countExpiringSoon(shares, nowMs) {
  var n = 0
  for (var i = 0; i < shares.length; i++) if (isExpiringSoon(shares[i], nowMs)) n++
  return n
}

// Untitled shares fall back to the slug; rows elide it if space runs out.
function displayTitle(share) {
  if (!share) return ""
  var title = String(share.title || "").trim()
  return title !== "" ? title : String(share.slug || "")
}

function plural(n, word) {
  return n + " " + word + (n === 1 ? "" : "s")
}

// "3d 4h", "5h 12m", "45m", "<1m". Largest two units, no seconds.
function durationText(ms) {
  var total = Math.max(0, Math.round(ms / 60000))
  var days = Math.floor(total / 1440)
  var hours = Math.floor((total % 1440) / 60)
  var mins = total % 60
  if (days > 0) return hours > 0 ? days + "d " + hours + "h" : days + "d"
  if (hours > 0) return mins > 0 ? hours + "h " + mins + "m" : hours + "h"
  if (mins > 0) return mins + "m"
  return "<1m"
}

function expiryText(share, nowMs) {
  var ms = expiresMs(share)
  if (ms === null) return "never expires"
  if (ms <= nowMs) return "expired " + durationText(nowMs - ms) + " ago"
  return "expires in " + durationText(ms - nowMs)
}

function ageText(share, nowMs) {
  var ms = Date.parse(String(share && share.created_at || ""))
  if (!isFinite(ms)) return ""
  return durationText(Math.max(0, nowMs - ms)) + " old"
}

function viewsText(share) {
  if (!share || !share.track_views) return ""
  return plural(share.view_count || 0, "view")
}

// Second line of a row: expiry · views · age, skipping empty parts.
function rowDetail(share, nowMs) {
  var parts = [expiryText(share, nowMs)]
  var views = viewsText(share)
  if (views !== "") parts.push(views)
  var age = ageText(share, nowMs)
  if (age !== "") parts.push(age)
  return parts.join(" · ")
}

function heroMeta(state) {
  if (state.keyMissing) return "No API key found"
  // error is sanitized at ingestion already; a second pass here keeps the
  // display boundary safe even if a future assignment forgets to.
  if (state.error) return sanitizeText(String(state.error), 200)
  if (state.loading && state.activeCount === 0 && state.expiredCount === 0) return "Loading shares"
  if (state.activeCount === 0) return state.expiredCount > 0 ? "No active shares" : "Nothing shared yet"
  var text = plural(state.activeCount, "active share")
  if (state.soonCount > 0) text += " · " + state.soonCount + " expiring soon"
  return text
}

// curl reads its arguments from a config file on stdin so the bearer token
// and any passcode never appear in argv (which is world-readable in /proc).
// Double-quoted config values take backslash escapes, so escape those.
function curlQuote(value) {
  return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
}

function curlConfig(opts) {
  var lines = [
    "url = " + curlQuote(opts.url),
    "header = " + curlQuote("Authorization: Bearer " + opts.key),
    "header = " + curlQuote("Accept: application/json"),
    // Loopback requests must never transit an http(s)_proxy from the
    // environment — the Bearer header would cross it in cleartext. Remote
    // https requests still honour any configured proxy.
    "noproxy = " + curlQuote("localhost,127.0.0.1,::1"),
    "silent",
    "show-error",
    "max-time = " + (opts.timeoutSec || 15),
    "max-filesize = " + MAX_RESPONSE_BYTES,
    "write-out = " + curlQuote("\\n%{http_code}")
  ]
  if (opts.method && opts.method !== "GET") lines.push("request = " + curlQuote(opts.method))
  if (opts.json !== undefined) {
    lines.push("header = " + curlQuote("Content-Type: application/json"))
    lines.push("data = " + curlQuote(JSON.stringify(opts.json)))
  }
  return lines.join("\n") + "\n"
}

// Validate the configured base URL to a single plain http(s) endpoint, or ""
// if unusable (callers fail closed). Defends several things at once:
//  - no whitespace/newline  -> can't inject extra curl-config directives
//  - no { } [ ]             -> curl globbing can't fan one request into many
//                              (which would send the bearer token to each host)
//  - http only for loopback -> credentials never cross the network in cleartext
//  - http(s) scheme only    -> no file:/javascript: smuggling
//  - no ? or #              -> a query/fragment would make the API paths we
//                              append (/api/shares/...) land in the wrong part
//                              of the URL
function validatedBaseUrl(url) {
  var s = String(url || "").trim()
  while (s.length > 0 && s[s.length - 1] === "/") s = s.slice(0, -1)
  var m = /^(https?):\/\/([^\/\s{}\[\]?#]+)(\/[^\s{}\[\]?#]*)?$/.exec(s)
  if (!m) return ""
  var host = m[2].toLowerCase().replace(/:\d+$/, "")
  var isLoopback = host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]"
  if (m[1] === "http" && !isLoopback) return ""
  return s
}

function apiUrl(baseUrl, path) {
  return String(baseUrl || "") + path
}

function listUrl(baseUrl) { return apiUrl(baseUrl, "/api/shares/_mine") }
function deleteUrl(baseUrl, slug) { return apiUrl(baseUrl, "/api/shares/" + encodeURIComponent(slug) + "/_api") }
function passcodeUrl(baseUrl, slug) { return apiUrl(baseUrl, "/api/shares/" + encodeURIComponent(slug) + "/passcode/_api") }

// Allow Node tests to import this file; QML ignores the block.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    parseCurlOutput: parseCurlOutput, parseJson: parseJson, errorMessage: errorMessage,
    isActive: isActive, isExpiringSoon: isExpiringSoon, normaliseShares: normaliseShares,
    partition: partition, countExpiringSoon: countExpiringSoon, displayTitle: displayTitle,
    durationText: durationText, expiryText: expiryText, ageText: ageText, viewsText: viewsText,
    rowDetail: rowDetail, heroMeta: heroMeta, curlQuote: curlQuote, curlConfig: curlConfig,
    sameShareLists: sameShareLists,
    listUrl: listUrl, deleteUrl: deleteUrl, passcodeUrl: passcodeUrl, validatedBaseUrl: validatedBaseUrl,
    sanitizeText: sanitizeText, sanitizeKey: sanitizeKey,
    MAX_RESPONSE_BYTES: MAX_RESPONSE_BYTES, MAX_STDERR_BYTES: MAX_STDERR_BYTES, MAX_SHARES: MAX_SHARES,
    MAX_TITLE: MAX_TITLE, MAX_PASSCODE: MAX_PASSCODE, boundedUrl: boundedUrl
  }
}
