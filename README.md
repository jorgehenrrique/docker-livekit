# docker-livekit

Self-hosted [LiveKit](https://livekit.io) SFU for WebRTC voice/video — a thin
wrapper over `livekit/livekit-server`. Railway builds this Dockerfile from
GitHub (no image registry publish). Also runs on any VPS with UDP.

**Scope:** LiveKit + Redis. No Egress / recording. Use it with any LiveKit
client or backend that mints JWTs and connects over `wss://`.

Repo: https://github.com/jorgehenrrique/docker-livekit

## Deploy with one click (Railway)

**Before clicking Deploy:** generate the two required credentials on your machine
(step 1 below). The template asks for them up front — you cannot finish deploy
without `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`.

**Official template:**

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/livekit-midiawebrtcrealtime?referralCode=gandalf&utm_medium=integration&utm_source=template&utm_campaign=generic)

After the service is up: attach a public domain on port **7880** and a
**TCP Proxy** on **7881**, then redeploy. Full steps in [RAILWAY.MD](./RAILWAY.MD).

## Connect any LiveKit app

| Field | Value |
| --- | --- |
| Server URL | `wss://<your-public-domain>` (must be `ws://` or `wss://`, **not** `https://`) |
| API Key | Same value as `LIVEKIT_API_KEY` on this service |
| API Secret | Same value as `LIVEKIT_API_SECRET` on this service |

Your backend mints participant JWTs with that key/secret and may call RoomService
over HTTPS (`wss://` → `https://`). Browsers use `livekit-client` /
`room.connect`. Rooms are auto-created on join (`auto_create: true`) — clients
need not call `createRoom`.

One SFU can serve **many** apps if they share the same URL + keys. Isolate
tenants with room name prefixes.

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
candidates, so clients usually work **without** client-side `forceTcp`.

---

## Deploy on Railway (start to finish)

Prefer the **one-click template** (button above). Manual GitHub deploy works
too. Do these steps **in order**. Keys come **first** (required on the template
form). The first boot may still fail until the TCP proxy exists — that is
expected.

### 1. Generate the LiveKit API key pair (on your machine) — required first

LiveKit does **not** create keys in the Railway UI. Run this **on your computer**
(macOS/Linux Terminal or Windows PowerShell) — **not** inside Railway — **before**
you open the template Deploy form.

1. Open **Terminal** (or PowerShell).
2. Make sure **Docker Desktop** is running.
3. Run:

```bash
docker run --rm livekit/livekit-server generate-keys
```

Example output (yours will differ):

```text
API Key: APIxxxxxxxxxxxxxxxxxxxx
API Secret: secretsecretrandomstringatleast32chars
```

- Keep both values. You paste them into the **template Deploy form** (or
  Variables) and later into your LiveKit app.
- Prefer a secret **≥ 32 characters** (what `generate-keys` already prints).
- Without Docker, any strong random key + secret ≥ 32 chars works, but
  `generate-keys` is the supported path.

### 2. Create the Railway project (paste the keys from step 1)

**Option A — template (recommended):** open
[Deploy LiveKit SFU](https://railway.com/deploy/livekit-midiawebrtcrealtime?referralCode=gandalf&utm_medium=integration&utm_source=template&utm_campaign=generic)
→ fill **`LIVEKIT_API_KEY`** and **`LIVEKIT_API_SECRET`** with the values from
step 1 → Deploy. Redis and the other env vars come pre-wired. You cannot
complete the template deploy without those two fields.

**Option B — from GitHub:**

1. Open [Railway](https://railway.app) → **New Project**.
2. **Deploy from GitHub repo** → select **`jorgehenrrique/docker-livekit`**
   (or your fork). Authorize GitHub if asked.
3. Railway creates a service and starts a build from the `Dockerfile`.
4. Add the variables in step 3 and Redis in step 4 yourself.

Leave the canvas open — the first deploy may crash until step 5 (TCP proxy).

### 3. Set variables on the LiveKit service

**Template path:** you already entered the two keys on the Deploy form — skip
adding them again unless you need to rotate. Confirm `PORT=7880` and
`LIVEKIT_FORCE_TCP=auto` are present.

**GitHub / manual path:** LiveKit service → **Variables** → add:

| Variable | Value |
| --- | --- |
| `LIVEKIT_API_KEY` | the **API Key** from step 1 |
| `LIVEKIT_API_SECRET` | the **API Secret** from step 1 |
| `PORT` | `7880` |
| `LIVEKIT_FORCE_TCP` | `auto` |

Do **not** invent `RAILWAY_TCP_PROXY_*` — Railway injects those after step 5.

### 4. Add Redis (recommended) and wire it

**Template path:** Redis is already included — skip to step 5 unless the refs
are missing.

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

Still on the **LiveKit** service → **Settings** → **Networking**.

You need **two** separate things. They are easy to confuse in the Railway UI:

| What in the UI | Port | Purpose |
| --- | --- | --- |
| **Domain** (`….up.railway.app`) under Public Networking | **7880** | HTTPS signalling + RoomService (`wss://` / `https://`) |
| **+ TCP Proxy** (separate button, not the domain port) | **7881** | WebRTC media over TCP |

**Correct screen looks like:**

- Domain: `your-service.up.railway.app` → Port **7880**
- TCP Proxy: `something.proxy.rlwy.net:NNNNN` → **:7881**

**Wrong (common mistake):** pointing the HTTP domain at **7881** and never
clicking **+ TCP Proxy**. That does **not** create `RAILWAY_TCP_PROXY_*`.
The entrypoint then logs `FATAL: … no TCP proxy` and exits in a loop.

Steps:

1. **Public Networking** → **Generate Domain** (or custom domain).
   - Set / edit the domain target port to **7880** (not 7881).
2. Click **+ TCP Proxy** → application / container port **7881** → confirm.
   - Railway shows a host like `….proxy.rlwy.net` and a random public port.
   - Do **not** paste that host into your app. The entrypoint reads
     `RAILWAY_TCP_PROXY_DOMAIN` / `RAILWAY_TCP_PROXY_PORT` automatically.
3. **Redeploy** the LiveKit service (Deployments → Redeploy).
   Proxy env vars only appear on a **new** boot after the proxy exists.

If you skip the TCP proxy (or only change the domain port to 7881), the
container logs `FATAL: … no TCP proxy` and exits.

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

### 7. Configure your app

1. Point your backend / client at `wss://<your-railway-domain>`  
   Example: `wss://something.up.railway.app`  
   Must start with `wss://` (not `https://`, no trailing path required).
2. Use the **same** API Key / API Secret from step 1 / Railway vars when minting
   JWTs and calling RoomService.
3. Connect two clients (e.g. browsers with `livekit-client`) and confirm audio.

### If something fails

| Symptom | Likely cause |
| --- | --- |
| Deploy exits immediately, log mentions TCP proxy | No **+ TCP Proxy** on **7881**, domain pointed at 7881 instead, or no redeploy after adding the proxy |
| Domain works on 7881 but logs still say no TCP proxy | HTTP domain ≠ TCP Proxy. Add **+ TCP Proxy** → 7881 and set the domain back to **7880** |
| `GET /` is OK but call has no audio/video | TCP proxy missing/wrong port, or redeploy skipped |
| Join fails / unauthorized | Key/secret in the app ≠ Railway vars |
| RoomService issues | Backend cannot reach `https://<domain>` (same host as `wss://`) |

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

## E2E checklist

1. LiveKit health `GET /` → `OK`.
2. Railway TCP proxy on **7881** exists; service redeployed after creating it.
3. App URL is exactly `wss://<public-domain>` (not `https://`).
4. Key/secret in the app **match** the LiveKit service envs.
5. Two clients: join the same room → both hear audio (and optional cam/screen).
6. RoomService works from your backend (can reach the HTTPS host).

## Multi-server

Point any number of LiveKit apps at the same `wss://` URL and the same API
key/secret. Isolate tenants with room name prefixes; media always goes
client ↔ this SFU.

## License

LiveKit is Apache-2.0. This wrapper is provided as-is.
