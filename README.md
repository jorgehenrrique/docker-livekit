# docker-livekit

Self-hosted [LiveKit](https://livekit.io) SFU for **Pro Ticket** team-chat calls.
Thin wrapper over `livekit/livekit-server` — Railway builds this Dockerfile from
GitHub (no image registry publish). Also runs on any VPS with UDP.

**Scope:** LiveKit + Redis. No Egress / recording.

## How Pro Ticket connects

| Setting (Settings → Team chat → Voice and video calls) | Value |
| --- | --- |
| URL | `wss://<your-public-domain>` (must be `ws://` or `wss://`) |
| API Key / Secret | Same pair as `LIVEKIT_API_*` on this service |
| enabled | on |
| Bot | `AI_MASTER_KEY` must be set so Settings can encrypt secrets |

The bot mints JWTs and calls RoomService over HTTPS (`wss://` → `https://`).
The panel uses `livekit-client` (`room.connect`). Rooms are auto-created on join
(`auto_create: true`) — Pro Ticket never calls `createRoom`.

One SFU can serve **many** Pro Ticket bots if they share the same URL + keys.
Room names are `tc_{chatId}_{callId}` (isolated).

## Transport: `LIVEKIT_FORCE_TCP`

| Value | Behaviour |
| --- | --- |
| `auto` (default) | Railway TCP proxy present → TCP-only + socat. On Railway **without** proxy → **FATAL**. Elsewhere → UDP preferred + ICE TCP fallback. |
| `true` | Always TCP-only. |
| `false` | Always UDP preferred + `allow_tcp_fallback`. |

Railway does **not** route inbound UDP. Media must use ICE/TCP via a TCP proxy
on container port **7881**. With `force_tcp: true` the SFU only advertises TCP
candidates, so the Pro Ticket panel works **without** client-side `forceTcp`.

## Deploy on Railway

1. **New Project** → Deploy from GitHub → this repo (`docker-livekit`).
2. **Add Redis** (plugin). Map variables on the LiveKit service, for example:
   - `LIVEKIT_REDIS_HOST=${{Redis.REDIS_HOST}}` (or private domain)
   - `LIVEKIT_REDIS_PORT=${{Redis.REDIS_PORT}}`
   - `LIVEKIT_REDIS_PASSWORD=${{Redis.REDIS_PASSWORD}}` if set
3. **Generate keys** (locally once):

   ```bash
   docker run --rm livekit/livekit-server generate-keys
   ```

   Set on the LiveKit service:
   - `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` (secret ≥ 32 chars recommended)
   - `PORT=7880`
   - `LIVEKIT_FORCE_TCP=auto`
4. **Networking**
   - Public HTTPS domain on the LiveKit service (signalling + RoomService).
   - **TCP Proxy** → application/container port **7881**.
   - **Redeploy** after creating/changing the TCP proxy (entrypoint reads
     `RAILWAY_TCP_PROXY_*` at boot). Without the proxy the process **exits**
     on Railway so you do not get a silent “OK but mute rooms” deploy.
5. **Health:** `GET https://<domain>/` → `OK`.
6. **Pro Ticket:** Settings → Team chat → Voice and video calls:
   - URL `wss://<domain>`
   - paste the same key + secret
   - enable

### Railway env reference

| Variable | Required | Notes |
| --- | --- | --- |
| `LIVEKIT_API_KEY` | yes | From `generate-keys` |
| `LIVEKIT_API_SECRET` | yes | From `generate-keys` |
| `PORT` | yes | `7880` |
| `LIVEKIT_FORCE_TCP` | no | Default `auto` |
| `LIVEKIT_REDIS_HOST` | recommended | Enables shared room state |
| `LIVEKIT_REDIS_PORT` | no | Default `6379` |
| `LIVEKIT_REDIS_USERNAME` / `PASSWORD` | if Redis auth | |
| `LIVEKIT_LOG_LEVEL` | no | Default `info` |
| `LIVEKIT_NODE_IP` | rare | Override proxy DNS resolution |
| `LIVEKIT_BRIDGE_TARGET_IP` | rare | Override socat target interface IP |

`RAILWAY_TCP_PROXY_DOMAIN` / `PORT` / `APPLICATION_PORT` are injected by Railway
when the TCP proxy exists — do not set them by hand.

## Local / VPS (UDP)

```bash
cp .env.example .env
# fill LIVEKIT_API_KEY / LIVEKIT_API_SECRET from generate-keys
docker compose up --build
```

- Signalling: `ws://localhost:7880` (use `wss://` behind your TLS terminator in prod).
- Open UDP `50000-50100` (compose maps a short range) and TCP `7881`.
- `LIVEKIT_FORCE_TCP=false` in compose.

On a non-Railway host with real UDP ports, leave `LIVEKIT_FORCE_TCP=auto` or
`false` — clients prefer UDP and fall back to TCP via ICE automatically.

## E2E checklist (Pro Ticket)

1. LiveKit health `GET /` → `OK`.
2. Railway TCP proxy on **7881** exists; service redeployed after creating it.
3. Bot has `AI_MASTER_KEY`; Settings saves key/secret without `MASTER_KEY_MISSING`.
4. Settings URL is exactly `wss://<public-domain>` (not `https://`).
5. Key/secret in Settings **match** the LiveKit service envs.
6. Calls toggle enabled → chat header shows calls available.
7. Two staff browsers: start call → both hear audio (and optional cam/screen).
8. End call clears presence; RoomService delete works (bot can reach HTTPS host).

If signalling connects but media is silent: missing/wrong TCP proxy, or
forgot redeploy after proxy change.

## Multi-server

Point any number of Pro Ticket installations at the same `wss://` URL and the
same API key/secret. Presence stays in each bot’s Mongo; media always goes
browser ↔ this SFU.

## License

LiveKit is Apache-2.0. This wrapper is provided as-is for use with Pro Ticket.
