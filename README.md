# docker-livekit

Self-hosted [LiveKit](https://livekit.io) SFU for **Pro Ticket** team-chat calls.
Thin wrapper over `livekit/livekit-server` — Railway builds this Dockerfile from
GitHub (no image registry publish). Also runs on any VPS with UDP.

**Scope:** LiveKit + Redis. No Egress / recording.

Repo: https://github.com/jorgehenrrique/docker-livekit

## How Pro Ticket connects

| Setting (Settings → Team chat → Voice and video calls) | Value |
| --- | --- |
| URL | `wss://<your-public-domain>` (must be `ws://` or `wss://`, **not** `https://`) |
| API Key | Same value as `LIVEKIT_API_KEY` on this service |
| API Secret | Same value as `LIVEKIT_API_SECRET` on this service |
| Enable calls | on |
| Bot env | `AI_MASTER_KEY` must be set on the Pro Ticket bot so Settings can encrypt secrets |

The bot mints JWTs and calls RoomService over HTTPS (`wss://` → `https://`).
The panel uses `livekit-client` (`room.connect`). Rooms are auto-created on join
(`auto_create: true`) — Pro Ticket never calls `createRoom`.

One SFU can serve **many** Pro Ticket bots if they share the same URL + keys.
Room names are `tc_{chatId}_{callId}` (isolated).

## Transport: `LIVEKIT_FORCE_TCP`

| Value | Behaviour |
| --- | --- |
| `auto` (default) | Railway TCP proxy present → TCP-only + socat. Elsewhere → UDP preferred + ICE TCP fallback. |
| `true` | Always TCP-only (still needs the Railway TCP proxy when hosted there). |
| `false` | UDP preferred + `allow_tcp_fallback`. **Refused on Railway** (no inbound UDP). |

On Railway, a TCP proxy on container port **7881** is **mandatory**. The process
**exits on boot** if it is missing — for every `LIVEKIT_FORCE_TCP` value — so you
never get a deploy that looks healthy while every room stays silent.

Railway does **not** route inbound UDP. Media must use ICE/TCP via a TCP proxy
on container port **7881**. With `force_tcp: true` the SFU only advertises TCP
candidates, so the Pro Ticket panel works **without** client-side `forceTcp`.

---

## Deploy on Railway (start to finish)

Do these steps **in order**. The first GitHub deploy often fails until keys +
TCP proxy exist — that is expected.

### 1. Create the Railway project from GitHub

1. Open [Railway](https://railway.app) → **New Project**.
2. **Deploy from GitHub repo** → select **`jorgehenrrique/docker-livekit`**
   (or your fork). Authorize GitHub if asked.
3. Railway creates a service and starts a build from the `Dockerfile`.
4. Leave the canvas open — the first deploy may crash until step 5 (TCP proxy).

### 2. Generate the LiveKit API key pair (on your machine)

LiveKit does **not** create keys in the Railway UI. Generate them once locally
(Docker required):

```bash
docker run --rm livekit/livekit-server generate-keys
```

Example output (yours will differ):

```text
API Key: APIxxxxxxxxxxxxxxxxxxxx
API Secret: secretsecretrandomstringatleast32chars
```

- Keep both values. You will paste them into **Railway** and into **Pro Ticket**.
- Prefer a secret **≥ 32 characters** (what `generate-keys` already prints).
- Without Docker, any strong random key + secret ≥ 32 chars works, but
  `generate-keys` is the supported path.

### 3. Set variables on the LiveKit service

In Railway → click the **LiveKit / docker-livekit** service → **Variables** →
add:

| Variable | Value |
| --- | --- |
| `LIVEKIT_API_KEY` | the **API Key** from step 2 |
| `LIVEKIT_API_SECRET` | the **API Secret** from step 2 |
| `PORT` | `7880` |
| `LIVEKIT_FORCE_TCP` | `auto` |

Do **not** invent `RAILWAY_TCP_PROXY_*` — Railway injects those after step 5.

### 4. Add Redis (recommended) and wire it

1. On the project canvas: **+ New** → **Database** → **Add Redis**
   (or Redis from the template marketplace).
2. Wait until Redis is online.
3. Back on the **LiveKit** service → **Variables**, add **reference** variables
   (use the variable picker so the service name matches yours — often `Redis`):

| Variable on LiveKit | Reference (typical Railway Redis plugin) |
| --- | --- |
| `LIVEKIT_REDIS_HOST` | `${{Redis.REDISHOST}}` |
| `LIVEKIT_REDIS_PORT` | `${{Redis.REDISPORT}}` |
| `LIVEKIT_REDIS_PASSWORD` | `${{Redis.REDIS_PASSWORD}}` or `${{Redis.REDISPASSWORD}}` |

Notes:

- Official plugin names are `REDISHOST` / `REDISPORT` / `REDISPASSWORD` /
  `REDIS_PASSWORD` — **not** `REDIS_HOST`.
- Use the **private** host (`*.railway.internal`). Do **not** expose Redis
  publicly for this setup.
- Click the eye icon on the Redis service to confirm the resolved values.
- Redis is recommended (shared room state / restarts). The SFU can run without
  it for a quick test; omit these three vars in that case.

### 5. Networking (HTTPS domain + TCP proxy) — required

Still on the **LiveKit** service → **Settings** → **Networking**:

1. **Public Networking** → **Generate Domain** (or add a custom domain).
   - This gives HTTPS for signalling + RoomService, e.g.
     `something.up.railway.app`.
2. **TCP Proxy** → add proxy → target / application port **`7881`**.
   - Railway shows a public host like `….proxy.rlwy.net` and a random public
     port. You do **not** paste that into Pro Ticket; the entrypoint reads
     `RAILWAY_TCP_PROXY_DOMAIN` / `RAILWAY_TCP_PROXY_PORT` automatically.
3. **Redeploy** the LiveKit service (Deployments → Redeploy, or push an empty
   change). The entrypoint only sees the proxy env vars on a **new** boot.

If you skip the TCP proxy, the container logs `FATAL: … no TCP proxy` and exits.

### 6. Confirm the deploy is healthy

1. Open the latest deployment **Logs**. You should see something like:
   - `mode=tcp (Railway proxy) ICE/TCP advertised as …`
   - `redis: distributed mode via …` (if Redis was wired)
   - LiveKit starting without FATAL
2. In a browser or with curl:

   ```bash
   curl -sS "https://<your-railway-domain>/"
   ```

   Expected body: `OK`
3. Copy the public hostname (no path), e.g. `something.up.railway.app`.

### 7. Configure Pro Ticket

1. On the **Pro Ticket bot** host, ensure `AI_MASTER_KEY` is set and the bot was
   restarted after setting it. Without it, Settings returns `MASTER_KEY_MISSING`
   when saving LiveKit secrets.
2. Open the panel → **Settings → Team chat → Voice and video calls**.
3. Fill:
   - **LiveKit URL:** `wss://<your-railway-domain>`  
     Example: `wss://something.up.railway.app`  
     Must start with `wss://` (not `https://`, no trailing path required).
   - **API Key** / **API Secret:** the **same** pair from step 2 / Railway vars.
   - Turn **Enable calls** on → save toggle and URL → save each secret.
4. Open **Tickets → Team** inbox → start a call with two staff browsers and
   confirm audio.

### If something fails

| Symptom | Likely cause |
| --- | --- |
| Deploy exits immediately, log mentions TCP proxy | Step 5 missing or no redeploy after adding the proxy |
| `GET /` is OK but call has no audio/video | TCP proxy not on **7881**, or redeploy skipped |
| Settings cannot save key/secret | `AI_MASTER_KEY` missing on the bot |
| `VALIDATION` on URL | Used `https://` instead of `wss://` |
| Join fails / unauthorized | Key/secret in Pro Ticket ≠ Railway vars |
| RoomService / leave-end weirdness | Bot cannot reach `https://<domain>` (same host as `wss://`) |

---

### Railway env reference

| Variable | Required | Notes |
| --- | --- | --- |
| `LIVEKIT_API_KEY` | yes | From `generate-keys` |
| `LIVEKIT_API_SECRET` | yes | From `generate-keys` (≥ 32 chars recommended) |
| `PORT` | yes | `7880` |
| `LIVEKIT_FORCE_TCP` | no | Default `auto` |
| `LIVEKIT_REDIS_HOST` | recommended | `${{Redis.REDISHOST}}` |
| `LIVEKIT_REDIS_PORT` | no | `${{Redis.REDISPORT}}` (default `6379`) |
| `LIVEKIT_REDIS_PASSWORD` | if Redis auth | `${{Redis.REDIS_PASSWORD}}` |
| `LIVEKIT_REDIS_USERNAME` | rare | Only if your Redis ACL needs it |
| `LIVEKIT_LOG_LEVEL` | no | Default `info` |
| `LIVEKIT_NODE_IP` | rare | Override proxy DNS resolution |
| `LIVEKIT_BRIDGE_TARGET_IP` | rare | Override socat target interface IP |

`RAILWAY_TCP_PROXY_DOMAIN` / `RAILWAY_TCP_PROXY_PORT` /
`RAILWAY_TCP_APPLICATION_PORT` are injected by Railway when the TCP proxy
exists — do not set them by hand.

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

## Multi-server

Point any number of Pro Ticket installations at the same `wss://` URL and the
same API key/secret. Presence stays in each bot’s Mongo; media always goes
browser ↔ this SFU.

## License

LiveKit is Apache-2.0. This wrapper is provided as-is for use with Pro Ticket.
