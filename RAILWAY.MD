# Deploy and Host LiveKit SFU on Railway

Self-hosted [LiveKit](https://livekit.io) SFU for WebRTC voice/video. Works with **any** LiveKit app — including [Pro Ticket](https://github.com/jorgehenrrique/docker-discord-bot-pro-ticket) Team Chat calls. Thin wrapper over `livekit/livekit-server` + Redis. No Egress/recording. Source: [github.com/jorgehenrrique/docker-livekit](https://github.com/jorgehenrrique/docker-livekit)

## About Hosting LiveKit SFU

Railway does **not** route inbound UDP. This image detects Railway and runs **TCP-only** media through a **TCP Proxy** on container port **7881**, while signalling stays on **7880** (HTTPS / `wss://`). The template ships LiveKit plus Redis. **Generate** `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` on your machine **before** clicking Deploy — the template form requires both. After the service exists, attach a public domain on **7880** and a TCP Proxy on **7881**, then redeploy — without the proxy the process **exits on purpose**, so you never get a “healthy but silent” SFU. The same image runs on a VPS with real UDP via Docker Compose.

### Keep Auto Deploy enabled

After deploy: LiveKit service → **Settings → Source** → under the production branch, **Enable** Auto Deploy if it is off. Railway then pulls updates from `main` when the wrapper improves.

## Common Use Cases

- **Pro Ticket Team Chat** — Staff voice/video in the web panel (Settings → Team chat → Voice and video calls)
- **Any LiveKit client** — Mint JWTs with the same API key/secret; point `room.connect` at `wss://your-domain`
- **Shared SFU** — One deploy serves many apps / many Pro Ticket bots (same URL + keys; rooms isolated by name)
- **Local / VPS** — Same image via Docker Compose with UDP preferred (see Implementation Details)

## Dependencies for LiveKit SFU Hosting

- **Redis** — Included in this template (recommended; room state across restarts)
- **LIVEKIT_API_KEY** + **LIVEKIT_API_SECRET** — Generated on your machine (below). **Not** created by Railway
- **Public domain on port 7880** + **TCP Proxy on port 7881** — Configured after deploy
- Docker Desktop (optional) — only to run `generate-keys` once

Also need: a [Railway](https://railway.com) account. Optional: any LiveKit-capable app (Pro Ticket, custom backend, etc.).

### Deployment Dependencies

- [LiveKit docs](https://docs.livekit.io) — server, tokens, client SDKs
- [docker-livekit repo](https://github.com/jorgehenrrique/docker-livekit) — Dockerfile, entrypoint, Compose
- [Pro Ticket bot](https://github.com/jorgehenrrique/docker-discord-bot-pro-ticket) — optional consumer (Team Chat calls)
- [Pro Ticket install guide](https://prosystem.up.railway.app/en-US/install) — wiring calls in the panel
- [Railway](https://railway.com) — hosting; TCP Proxy required for media

### Implementation Details

#### Pre-Deploy: Generate API credentials

LiveKit does **not** create keys in the Railway UI. Run this **on your computer** (macOS / Linux / Windows with Docker Desktop) — **not** inside Railway:

```bash
docker run --rm livekit/livekit-server generate-keys
```

Example output (yours will differ):

```text
API Key: APIxxxxxxxxxxxxxxxxxxxx
API Secret: secretsecretrandomstringatleast32chars
```

- Save both values. Paste them into **Railway Variables** and into your app (e.g. Pro Ticket Settings).
- Prefer a secret **≥ 32 characters** (`generate-keys` already prints that).
- Without Docker, any strong random API key + secret ≥ 32 chars works; `generate-keys` is the supported path.

#### Deploy (this template)

Have the two values from **Pre-Deploy** ready. Open the template → fill the
required fields on the Deploy form → then Deploy. You cannot finish without them:

| Variable | Value |
| --- | --- |
| `LIVEKIT_API_KEY` | API Key from `generate-keys` |
| `LIVEKIT_API_SECRET` | API Secret from `generate-keys` |

Everything else is pre-configured by the template:

- `PORT` = `7880`
- `LIVEKIT_FORCE_TCP` = `auto` (TCP-only on Railway when the proxy exists)
- Redis via `LIVEKIT_REDIS_HOST` → `${{Redis.REDISHOST}}`, `LIVEKIT_REDIS_PORT` → `${{Redis.REDISPORT}}`, `LIVEKIT_REDIS_PASSWORD` → `${{Redis.REDIS_PASSWORD}}` (or `REDISPASSWORD`)

Do **not** invent `RAILWAY_TCP_PROXY_*` — Railway injects those after you add the TCP Proxy.

Wait for the first build. The service may crash in a loop until **Post-Deploy step 1** (TCP proxy) — that is expected.

#### Post-Deploy Steps (required)

**1 — Networking (two separate things)**

LiveKit service → **Settings → Networking**:

| What in the UI | Port | Purpose |
| --- | --- | --- |
| **Domain** (`….up.railway.app`) | **7880** | HTTPS signalling + RoomService (`wss://` / `https://`) |
| **+ TCP Proxy** (separate control, not the domain port) | **7881** | WebRTC media over TCP |

Correct:

- Domain → Port **7880**
- TCP Proxy → `….proxy.rlwy.net:NNNNN` → container **:7881**

Wrong (common): pointing the HTTP domain at **7881** and never clicking **+ TCP Proxy**. That does **not** create `RAILWAY_TCP_PROXY_*`. Logs show `FATAL: … no TCP proxy` and the container exits.

Steps:

1. **Generate Domain** (or custom domain) → target port **7880**
2. **+ TCP Proxy** → application port **7881** → confirm
3. **Redeploy** (Deployments → Redeploy). Proxy env vars only appear on a **new** boot.

Do **not** paste the `proxy.rlwy.net` host into your app. Clients use the **HTTPS domain** only; the entrypoint reads the proxy vars automatically.

**2 — Confirm healthy**

Logs should show something like `mode=tcp (Railway proxy)…` and Redis connected. Then:

```bash
curl -sS "https://YOUR_RAILWAY_DOMAIN/"
```

Expected body: `OK`

**3 — Connect your app**

Any LiveKit SDK / server:

| Field | Value |
| --- | --- |
| Server URL | `wss://YOUR_RAILWAY_DOMAIN` (must be `ws://` or `wss://`, **not** `https://`) |
| API Key | Same as `LIVEKIT_API_KEY` |
| API Secret | Same as `LIVEKIT_API_SECRET` |

Your backend mints participant JWTs with that key/secret. Browsers call `room.connect(wssUrl, token)`. RoomService HTTP uses the same host as `https://…`.

**Pro Ticket:** Panel → **Settings → Team chat → Voice and video calls** → paste URL + key + secret → enable calls. Bot needs `AI_MASTER_KEY` so secrets encrypt in Mongo.

**4 — Enable Auto Deploy** (Settings → Source) if disabled.

#### Key Features

- **Railway-ready TCP** — Auto `force_tcp` + socat bridge when `RAILWAY_TCP_PROXY_*` is present; refuses to boot mute without the proxy
- **Redis** — Distributed room state across restarts (template-included)
- **`auto_create` rooms** — Join creates the room (no mandatory `createRoom` call)
- **Multi-tenant friendly** — Share one SFU across apps; isolate with room name prefixes
- **Same image on VPS** — UDP preferred when not on Railway

##### Local / VPS (UDP)

```bash
git clone https://github.com/jorgehenrrique/docker-livekit.git
cd docker-livekit
cp .env.example .env   # fill LIVEKIT_API_KEY / LIVEKIT_API_SECRET from generate-keys
docker compose up --build
```

- Signalling: `ws://localhost:7880` (use `wss://` behind your TLS terminator in production)
- Open UDP `50000–50100` and TCP `7881`
- Compose sets `LIVEKIT_FORCE_TCP=false` (UDP preferred + ICE TCP fallback)

##### Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Deploy exits; log mentions TCP proxy | No **+ TCP Proxy** on **7881**, or domain pointed at 7881, or no redeploy after adding proxy |
| `GET /` is OK but no audio/video | TCP proxy missing/wrong; redeploy skipped |
| Join unauthorized | Key/secret in the app ≠ Railway vars |
| URL validation fails (Pro Ticket) | Used `https://` instead of `wss://` |

### Why Deploy LiveKit SFU on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying LiveKit SFU on Railway, you get a one-click WebRTC media server without UDP — TCP proxy path is built into the entrypoint — and the same repo still runs on Docker Compose or any VPS. Host your servers, databases, AI agents, and more on Railway.

[**Pro Ticket support Discord**](https://discord.gg/tEp2D7MbjZ) · [LiveKit docs](https://docs.livekit.io) · [Repo](https://github.com/jorgehenrrique/docker-livekit)
