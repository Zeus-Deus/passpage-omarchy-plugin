# Passpage for Omarchy

Your [passpage.space](https://passpage.space) shares in the Omarchy bar.

![Passpage panel in the Omarchy bar](preview.png)

The bar shows a page glyph with the number of active shares. Click it for a
panel that lists every share with its expiry, passcode state and view count,
plus quick actions: copy link, open in browser, set / change / remove
passcode, delete. Shares expiring within 24 h are highlighted; expired but
not-yet-swept shares sit in a dimmed **Expired** section so you can delete
them early.

Publishing is intentionally not here — pages are published by agents or the
`passpage` CLI through the API. This plugin is for seeing and managing what
is live.

## Install

```bash
omarchy plugin add https://github.com/Zeus-Deus/passpage-omarchy-plugin --enable
```

Then give it an API key. Create one at passpage.space → Dashboard → API keys
and save it to `~/.config/passpage/key` (the same file the `passpage` CLI uses):

```bash
mkdir -p ~/.config/passpage && chmod 700 ~/.config/passpage
printf %s 'pp_…' > ~/.config/passpage/key && chmod 600 ~/.config/passpage/key
```

The panel watches that file and picks the key up without a restart. While it
is missing or rejected the bar glyph shows a `!` badge and the panel says why.

### Dependencies

Everything is already present on a stock Omarchy install:

- `curl` — all API calls
- `wl-copy` (wl-clipboard) — copy link
- `omarchy-launch-browser` — open share / dashboard

No background services, installers, elevated privileges, or remote builds.
The plugin never writes outside the shell's own `shell.json` settings (and
only when Omarchy asks it to).

## Usage

| Action | Mouse | Key |
|---|---|---|
| Copy link | click row or 󰆏 | `Enter` / `c` |
| Open in browser | 󰖟 | `o` |
| Set / change / remove passcode | 󰌿 / 󰌾 | `p` |
| Delete (with confirmation) | 󰆴 | `x` |
| Refresh | 󰑐 or middle-click the bar icon | `r` |
| Open passpage dashboard | — | `d` |

`j`/`k` or arrows move the cursor, `Esc` closes (or cancels an open editor /
dialog), `Tab` switches to the neighbouring bar panel.

Passcode editor: type and press `Enter` to set; leave it empty and press
`Enter` to remove an existing passcode.

IPC:

```bash
omarchy-shell passpage toggle | open | close | refresh | status
```

`status` returns JSON, e.g.
`{"active":11,"expired":0,"expiringSoon":1,"error":"","keyMissing":false}`.

## Configure

Settings live inline on the bar entry in `~/.config/omarchy/shell.json`
(Omarchy's plugin settings UI edits the same keys):

```json
{ "id": "space.passpage.shares", "refreshIntervalSec": 300 }
```

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `300` | Background refresh of the bar count (30–3600). The panel always refreshes when opened. |
| `baseUrl` | `https://passpage.space` | Only for a self-hosted passpage. |

## Remove

```bash
omarchy plugin remove space.passpage.shares
```

This deletes the plugin folder and its bar entry. Your API key file
(`~/.config/passpage/key`) is yours and is left alone.

## Security notes

- The API key and any passcode you type are handed to `curl` through a config
  file on stdin — never on the command line, so they are not visible in `/proc`.
- curl runs with `-q` (never reads `~/.curlrc`), so no inherited option can
  redirect the request, weaken TLS, or attach the key to another URL.
- Remote strings (titles, error details) are stripped of markup and control
  characters before display, and rendered as plain text.
- Responses are bounded at the source: curl's stdout and stderr pass through
  `head -c` (2 MiB / 16 KiB) before they reach the shell, so an oversized
  body is cut off and reported as an error rather than buffered. The share
  list is then clamped (≤500 entries, every field length-checked) before it
  reaches the UI. A broken or hostile `baseUrl` cannot grow the shell process.
- Only bearer-token endpoints are used: `GET /api/shares/_mine`,
  `PATCH /api/shares/<slug>/passcode/_api`, `DELETE /api/shares/<slug>/_api`.
  The plugin cannot create keys or publish pages.
- Like every Omarchy shell plugin, it runs unsandboxed inside the shell process.

## Development

```bash
node --test tests/model.test.js           # pure logic: expiry, formatting, curl config
omarchy plugin validate .                 # manifest + folder rules
omarchy plugin add "$PWD" --yes --enable  # install a local clone
git -C ~/.config/omarchy/plugins/space.passpage.shares pull && omarchy-restart-shell
qs log -p /usr/share/omarchy/shell --tail 60
```

## License

MIT — see [LICENSE](LICENSE).
