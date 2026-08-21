# passpage-omarchy-plugin

Omarchy (Quattro) shell plugin for [passpage.space](https://passpage.space) —
view and manage your passpages straight from the top bar instead of the
website dashboard.

## What it does

- `bar-widget`: passpage icon in the bar, with active-share count.
- `panel`: click to open — lists your shares (title, expiry, passcode status)
  with quick actions: copy link, open in browser, set/remove passcode, delete.

Publishing stays out of scope: pages are published via the passpage API by
agents, not from this plugin.

## Tech facts

- QML on Quickshell, running inside the Omarchy shell process (unsandboxed,
  no symlinks in the plugin folder, never spawn a second Quickshell).
- `manifest.json` at repo root (schemaVersion 1, unique id — must not use the
  `omarchy.*` prefix — name, version, author, license, description,
  kinds + entryPoints).
- Installed with `omarchy plugin add <git-url>`; lives in
  `~/.config/omarchy/plugins/<id>/` with live reload during development.
- Validate with `omarchy plugin validate .`.
- Auth: passpage API key (Bearer token) read from `~/.config/passpage/key`
  (mode 600, same file the local `passpage` CLI uses) — no browser session.
- Backend needs nothing new. Bearer-auth management endpoints are live on
  passpage.space (`backend/src/routes/shares.ts` in `../passpage`):
  - `GET /api/shares/_mine` → `ShareOut[]` (includes expired-but-unswept)
  - `PATCH /api/shares/<slug>/passcode/_api` `{"passcode": "x" | null}`
  - `DELETE /api/shares/<slug>/_api` → 204
  - `PATCH /api/shares/<slug>/title/_api` `{"title": "x" | null}`
  - Errors: `{"detail": "..."}`; 401 = missing/bad key.
  Bare paths (no `/_api`) are cookie-only and reject bearer tokens.
- `ShareOut`: `slug, url, title|null, has_passcode, expires_at|null,
  created_at, view_count, track_views, size_bytes, file_count, ...`.
  "Active" is not a field: `expires_at == null || expires_at > now`.
  No bearer `/api/auth/me`, so the plan's share cap is unknown to the plugin.

## Layout

- `manifest.json` — id `space.passpage.shares`, kind `bar-widget`, entry `Panel.qml`.
- `Panel.qml` — bar button + `KeyboardPanel`; cursor model, rows, inline
  passcode editor, delete `ConfirmDialog`, `IpcHandler` target `passpage`.
- `Service.qml` — key `FileView`, curl `Process`es, share state, polling.
- `PasspageIcon.qml` — the stamp mark drawn natively ("P" under 16px, "PP" above).
- `Model.js` + `tests/model.test.js` — pure helpers; `node --test tests/model.test.js`.

## Dev loop

Install once with `omarchy plugin add "$PWD" --yes --enable` (clones the repo),
then after each commit: `git -C ~/.config/omarchy/plugins/space.passpage.shares pull
&& omarchy-restart-shell`. Check with `omarchy-shell passpage status` and a
screenshot (`omarchy-shell passpage open; grim …`). Use `wtype` for key tests.
Publish throwaway shares for destructive tests — never delete the user's.

## Plugin conventions (from the shell + the installed gazelle plugin)

- Single `Panel.qml` as `entryPoints.barWidget`, built on `qs.Ui` `Panel` +
  `BarIconButton` + `KeyboardPanel` + `PanelKeyCatcher`; pure logic in
  `Model.js` (no Qt imports, Node-testable).
- HTTP via `Quickshell.Io.Process` + `curl` (+ `JSON.parse`); never pass the
  key or passcodes as argv — feed them over stdin.
- Colours/spacing from `qs.Commons` (`Color`, `Style`), never hard-coded.
- Clipboard: `wl-copy`; open URL: `omarchy-launch-browser`.
- Bind polling timers to `opened` so a closed panel costs nothing.
- Traps: no `escape()` method name, `h` can't be a shortcut,
  `KeyboardPanel` doesn't scroll (wrap in `Flickable`), `qmllint` can't parse
  `qs.Ui` imports — real gates are `omarchy plugin validate .` and
  `qs log -p /usr/share/omarchy/shell --tail 60`. `Panel.qml` edits need
  `omarchy-restart-shell`.

## References

- Passpage repo (API/backend): `../passpage`
- Shell runtime contract: https://github.com/basecamp/omarchy/blob/quattro/shell/README.md
- Built-in plugin examples: https://github.com/basecamp/omarchy/tree/quattro/shell/plugins
- Plugin dev guide: https://omarchyplugins.com/develop.html
