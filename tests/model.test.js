// Unit tests for Model.js — run with `node --test tests/model.test.js`.
// Fixture shapes mirror the real ShareOut wire format (packages/api-types in
// the passpage repo). Nothing here touches the network.

const test = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

const NOW = Date.parse("2026-08-21T12:00:00Z")
const share = (over) => Object.assign({
  id: "u", slug: "Ab3dEfGhIjKlMnOpQrStUv", url: "https://passpage.space/v/Ab3dEfGhIjKlMnOpQrStUv/",
  title: null, size_bytes: 10, file_count: 1, data_bytes: 0, has_passcode: false,
  expires_at: "2026-08-28T15:14:13.485Z", created_at: "2026-08-20T12:00:00Z",
  last_viewed_at: null, view_count: 0, track_views: false, first_viewed_at: null
}, over)

test("parseCurlOutput splits trailing status line", () => {
  assert.deepEqual(M.parseCurlOutput('[{"a":1}]\n200'), { status: 200, body: '[{"a":1}]' })
  assert.deepEqual(M.parseCurlOutput("\n204"), { status: 204, body: "" })
  assert.deepEqual(M.parseCurlOutput(""), { status: 0, body: "" })
  assert.equal(M.parseCurlOutput("garbage").status, 0)
})

test("errorMessage prefers the API detail envelope", () => {
  assert.equal(M.errorMessage(401, '{"detail":"bad api key"}'), "bad api key")
  assert.equal(M.errorMessage(401, ""), "API key rejected")
  assert.equal(M.errorMessage(0, ""), "Network error — is passpage.space reachable?")
  assert.equal(M.errorMessage(502, "<html>"), "HTTP 502")
})

test("isActive mirrors the backend quota rule", () => {
  assert.equal(M.isActive(share({ expires_at: null }), NOW), true)
  assert.equal(M.isActive(share(), NOW), true)
  assert.equal(M.isActive(share({ expires_at: "2026-08-21T11:59:59Z" }), NOW), false)
  assert.equal(M.isActive(share({ expires_at: "not a date" }), NOW), true, "unparseable treated as never")
})

test("isExpiringSoon is a 24h window, excluding already expired", () => {
  assert.equal(M.isExpiringSoon(share({ expires_at: "2026-08-22T11:00:00Z" }), NOW), true)
  assert.equal(M.isExpiringSoon(share({ expires_at: "2026-08-22T13:00:00Z" }), NOW), false)
  assert.equal(M.isExpiringSoon(share({ expires_at: "2026-08-21T11:00:00Z" }), NOW), false)
  assert.equal(M.isExpiringSoon(share({ expires_at: null }), NOW), false)
})

test("normaliseShares drops junk and sorts newest first", () => {
  const list = M.normaliseShares([
    share({ slug: "old", created_at: "2026-01-01T00:00:00Z", title: "Old" }),
    { nope: true }, null,
    share({ slug: "new", created_at: "2026-08-01T00:00:00Z", title: 7 })
  ])
  assert.deepEqual(list.map(s => s.slug), ["new", "old"])
  assert.equal(list[0].title, "", "non-string title coerced to empty")
  assert.equal(M.normaliseShares("nope").length, 0)
})

test("partition and counts", () => {
  const list = [share({ slug: "a" }), share({ slug: "b", expires_at: "2026-08-21T00:00:00Z" }),
    share({ slug: "c", expires_at: "2026-08-21T20:00:00Z" })]
  const p = M.partition(list, NOW)
  assert.deepEqual(p.active.map(s => s.slug), ["a", "c"])
  assert.deepEqual(p.expired.map(s => s.slug), ["b"])
  assert.equal(M.countExpiringSoon(p.active, NOW), 1)
})

test("displayTitle falls back to the slug", () => {
  assert.equal(M.displayTitle(share({ title: "  Q3 deck " })), "Q3 deck")
  assert.equal(M.displayTitle(share()), "Ab3dEfGhIjKlMnOpQrStUv")
  assert.equal(M.displayTitle(null), "")
})

test("durationText uses the two largest units", () => {
  const H = 3600000, D = 24 * H
  assert.equal(M.durationText(3 * D + 4 * H), "3d 4h")
  assert.equal(M.durationText(2 * D), "2d")
  assert.equal(M.durationText(5 * H + 12 * 60000), "5h 12m")
  assert.equal(M.durationText(45 * 60000), "45m")
  assert.equal(M.durationText(20000), "<1m")
})

test("expiryText / rowDetail", () => {
  assert.equal(M.expiryText(share({ expires_at: null }), NOW), "never expires")
  assert.equal(M.expiryText(share({ expires_at: "2026-08-21T10:00:00Z" }), NOW), "expired 2h ago")
  assert.equal(M.expiryText(share({ expires_at: "2026-08-23T12:00:00Z" }), NOW), "expires in 2d")
  assert.equal(M.rowDetail(share({ expires_at: null }), NOW), "never expires · 1d old")
  assert.equal(M.rowDetail(share({ expires_at: null, track_views: true, view_count: 1 }), NOW),
    "never expires · 1 view · 1d old")
})

test("heroMeta states", () => {
  assert.equal(M.heroMeta({ keyMissing: true }), "No API key found")
  assert.equal(M.heroMeta({ error: "API key rejected" }), "API key rejected")
  assert.equal(M.heroMeta({ loading: true, activeCount: 0, expiredCount: 0 }), "Loading shares")
  assert.equal(M.heroMeta({ activeCount: 0, expiredCount: 0 }), "Nothing shared yet")
  assert.equal(M.heroMeta({ activeCount: 0, expiredCount: 2 }), "No active shares")
  assert.equal(M.heroMeta({ activeCount: 1, soonCount: 0 }), "1 active share")
  assert.equal(M.heroMeta({ activeCount: 11, soonCount: 2 }), "11 active shares · 2 expiring soon")
})

test("curlConfig keeps secrets off argv and escapes quotes", () => {
  const cfg = M.curlConfig({ url: M.passcodeUrl("https://passpage.space/", "a-b"), key: 'pp_k"ey',
    method: "PATCH", json: { passcode: 'hun"ter\\2' } })
  assert.match(cfg, /^url = "https:\/\/passpage\.space\/api\/shares\/a-b\/passcode\/_api"\n/)
  assert.match(cfg, /header = "Authorization: Bearer pp_k\\"ey"\n/)
  assert.match(cfg, /request = "PATCH"\n/)
  // JSON escapes first ("→\", \→\\), then the curl-config escape doubles them.
  assert.ok(cfg.includes('data = "{\\"passcode\\":\\"hun\\\\\\"ter\\\\\\\\2\\"}"\n'), cfg)
  assert.ok(cfg.includes('write-out = "\\\\n%{http_code}"\n'), cfg)
  assert.doesNotMatch(M.curlConfig({ url: "u", key: "k" }), /request|data =|Content-Type/)
})

test("urls", () => {
  assert.equal(M.listUrl(""), "https://passpage.space/api/shares/_mine")
  assert.equal(M.deleteUrl("http://127.0.0.1:8000", "x/y"), "http://127.0.0.1:8000/api/shares/x%2Fy/_api")
  assert.equal(M.trimBaseUrl("https://a.b///"), "https://a.b")
})
