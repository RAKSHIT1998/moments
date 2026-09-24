# MOMENT relay

MOMENT has no central server. Phones sync directly over Wi‑Fi/Bluetooth (mesh), and — for people who
aren't in the same room — through **relays**: dumb, open WebSocket servers that anyone can run.
This is the reference one: ~120 lines, one dependency.

```sh
cd relay && npm install && npm start      # ws://localhost:7447
```

Add `ws://your-host:7447` under **Settings → Network → Relays** in the app. A phone can list several
relays; events are published to all of them and deduplicated on arrival.

## What a relay can and cannot do

- **Can:** store signed events, serve them by filter, drop expired NOW posts, enforce retention.
- **Cannot:** forge or alter an event (every event is signed with the author's Curve25519 key and
  addressed by its SHA‑256), read a non‑public Moment (its content is AES‑GCM ciphertext; the key
  only travels inside the invite link/QR), or learn a person's location (only 0.1° geo cells of
  *public* Moments are in the clear).
- **Doesn't collect:** accounts, emails, phone numbers, device IDs. There is no sign‑up; a person
  *is* their key.

## Protocol

JSON arrays over WebSocket:

| Direction | Frame | Meaning |
|---|---|---|
| client → relay | `["EVENT", event]` | publish |
| client → relay | `["REQ", id, filter]` | subscribe: stored matches, then live |
| client → relay | `["CLOSE", id]` | unsubscribe |
| relay → client | `["EVENT", event]` | a match |
| relay → client | `["EOSE", id]` | stored events for `id` are exhausted |
| relay → client | `["OK", eventId, accepted, message]` | publish ack |

`filter = { kinds?, authors?, moments?, geo?, since?, tags? }` — any listed field must match.

`event = { id, kind, author, createdAt, tags, content, sig }` where
`id = sha256("v1|kind|author|createdAt|k=v&k=v|content")`, `sig = ed25519(author, same bytes)`.

## Running it for real

Put it behind TLS (Caddy/nginx → `wss://`), set `DATA=/var/lib/moment/events.jsonl` and
`RETAIN_DAYS`. It's stateless apart from that file, so run as many as you like.

## Operator console

Set `ADMIN_TOKEN` and the relay also serves a console on `127.0.0.1:7448`:

```
ADMIN_TOKEN=$(openssl rand -hex 24) DATA=/var/lib/moment/events.jsonl node server.js
```

It is **off unless the token is set**, and bound to localhost unless you change `ADMIN_HOST` — reach it
over an SSH tunnel (`ssh -L 7448:127.0.0.1:7448 you@relay`) rather than opening it to the internet.
Every API call needs `Authorization: Bearer <token>`; the page itself is not secret, the calls are.

What it is for:

- **Reports.** The app's Report button publishes a signed `report` event. This is the only thing that
  reads them, and somebody has to — an App Store review will ask how reported content gets handled.
  Repeat targets are counted, so a pattern shows up as a pattern.
- **What this relay is carrying** — event counts by kind, storage, retention, connected peers.
- **Money that crossed this relay.** `vaultBuy` and `subscribe` carry their amounts in the clear, which
  is how a platform fee can be worked out at all without a server holding the content. Web rail only:
  App Store purchases never pass through a relay, and a phone that synced over the mesh may never have
  told this relay anything.
- **Refusing to carry** an author or an event, here. Dropped from storage immediately and refused on
  arrival afterwards; the list is kept in `refused.json` next to the event log.

What it deliberately cannot do, because no relay can: delete anything from the network, ban a person
globally, or read a paid set. Refusing an author stops *this* relay being a party to their content —
it still exists on every other relay and on the phones that hold it. The console says so on its face,
because an operator who believes otherwise will make bad decisions with it.
