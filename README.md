# Passpage for Omarchy

Your [passpage.space](https://passpage.space) shares in the Omarchy bar.

The bar shows the passpage stamp with the number of active shares. Click it
(or `omarchy-shell passpage toggle`) for a panel that lists every share with
its expiry, passcode state and view count, plus quick actions:

| Action | Mouse | Key |
|---|---|---|
| Copy link | click row or 󰆏 | `Enter` / `c` |
| Open in browser | 󰖟 | `o` |
| Set / change / remove passcode | 󰌿 / 󰌾 | `p` |
| Delete (with confirmation) | 󰆴 | `x` |
| Refresh | 󰑐 | `r` |
| Open dashboard | — | `d` |

`j`/`k` or arrows move the cursor, `Esc` closes, `Tab` switches to the
neighbouring bar panel. Shares expiring within 24 h are highlighted; shares
that have expired but not yet been swept sit in a dimmed **Expired** section
so you can delete them early.

Publishing is intentionally not here — pages are published by agents or the
`passpage` CLI through the API; this plugin is for seeing and managing what
is live.

## Install

```bash
omarchy plugin add https://github.com/Zeus-Deus/passpage-omarchy-plugin --enable
```

Put a passpage API key (Dashboard → API keys) in `~/.config/passpage/key`:

```bash
mkdir -p ~/.config/passpage && chmod 700 ~/.config/passpage
printf %s 'pp_…' > ~/.config/passpage/key && chmod 600 ~/.config/passpage/key
```

The panel watches that file and picks the key up without a restart. If the
file is missing the bar glyph gets a `!` badge and the panel explains what to do.

## Settings

Set inline on the bar entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "space.passpage.shares", "refreshIntervalSec": 300 }
```

- `refreshIntervalSec` (30–3600, default 300): background refresh of the bar
  count. The panel always refreshes when opened.
- `baseUrl` (default `https://passpage.space`): only for self-hosted setups.

## IPC

```bash
omarchy-shell passpage toggle | open | close | refresh | status
```

`status` returns JSON: `{"active":11,"expired":0,"expiringSoon":1,"error":"","keyMissing":false}`.

## Security notes

- The API key and any passcode you type are handed to `curl` through a config
  file on stdin — never on the command line, so they are not visible in `/proc`.
- The plugin only ever calls the bearer-token endpoints (`/api/shares/_mine`,
  `…/passcode/_api`, `…/_api` delete). It cannot create keys or publish.

## Development

```bash
node --test tests/model.test.js     # pure logic (expiry, formatting, curl config)
omarchy plugin validate .           # manifest + folder rules
omarchy plugin add "$PWD" --yes --enable   # install a local clone
git -C ~/.config/omarchy/plugins/space.passpage.shares pull && omarchy-restart-shell
qs log -p /usr/share/omarchy/shell --tail 60
```
