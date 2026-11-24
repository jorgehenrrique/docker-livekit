#!/bin/sh
# LiveKit SFU entrypoint — Railway TCP-only or UDP-preferring multi-host.
#
# LIVEKIT_FORCE_TCP:
#   auto (default) — Railway TCP proxy present → force_tcp + socat bridge.
#                    On Railway without proxy → FATAL (do not boot "almost working").
#                    Elsewhere → UDP preferred + allow_tcp_fallback.
#   true           — always TCP-only.
#   false          — always UDP preferred + TCP ICE fallback.
#
# Railway maps a random *public* TCP port onto a fixed *container* port (7881).
# LiveKit advertises the port it binds, so we bind ICE/TCP on the public port
# number and socat-bridge the container port onto it. Bridge target must be the
# container interface IP — never 127.0.0.1 (pion TCP mux indexes by local IP).
set -eu

log() { printf 'entrypoint: %s\n' "$*" >&2; }
# Escape a value for a double-quoted YAML scalar.
yesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

: "${PORT:=7880}"
: "${LIVEKIT_FORCE_TCP:=auto}"
CONFIG_DIR=/etc/livekit
CONFIG="$CONFIG_DIR/config.yaml"
mkdir -p "$CONFIG_DIR"

# ------------------------------------------------------------------ API keys
if [ -z "${LIVEKIT_API_KEY:-}" ] || [ -z "${LIVEKIT_API_SECRET:-}" ]; then
  log "FATAL: LIVEKIT_API_KEY and LIVEKIT_API_SECRET must both be set."
  log "FATAL: generate with: docker run --rm livekit/livekit-server generate-keys"
  exit 1
fi
if [ "${#LIVEKIT_API_SECRET}" -lt 32 ]; then
  log "WARNING: LIVEKIT_API_SECRET is under 32 characters; LiveKit recommends 32+."
fi

# ----------------------------------------------------------- transport mode
FORCE_MODE="$(printf '%s' "$LIVEKIT_FORCE_TCP" | tr '[:upper:]' '[:lower:]')"
HAS_RAILWAY_PROXY=0
if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ]; then
  HAS_RAILWAY_PROXY=1
fi
ON_RAILWAY=0
if [ -n "${RAILWAY_PROJECT_ID:-}" ] || [ -n "${RAILWAY_ENVIRONMENT:-}" ] || [ -n "${RAILWAY_ENVIRONMENT_ID:-}" ]; then
  ON_RAILWAY=1
fi

USE_FORCE_TCP=0
case "$FORCE_MODE" in
  true|1|yes)
    USE_FORCE_TCP=1
    ;;
  false|0|no)
    USE_FORCE_TCP=0
    ;;
  auto|"")
    if [ "$HAS_RAILWAY_PROXY" -eq 1 ]; then
      USE_FORCE_TCP=1
    elif [ "$ON_RAILWAY" -eq 1 ]; then
      log "FATAL: running on Railway but no TCP proxy is configured."
      log "FATAL: Settings → Networking → TCP Proxy → container port 7881, then redeploy."
      log "FATAL: without it signalling may look healthy while every room stays silent."
      exit 1
    else
      USE_FORCE_TCP=0
    fi
    ;;
  *)
    log "FATAL: LIVEKIT_FORCE_TCP must be auto|true|false (got: $LIVEKIT_FORCE_TCP)"
    exit 1
    ;;
esac

# -------------------------------------------------------------- ICE / RTC
ICE_TCP_PORT=""
NODE_IP=""
BRIDGE_FROM=""
RTC_BLOCK=""

if [ "$USE_FORCE_TCP" -eq 1 ]; then
  if [ "$HAS_RAILWAY_PROXY" -eq 1 ]; then
    ICE_TCP_PORT="$RAILWAY_TCP_PROXY_PORT"
    NODE_IP="${LIVEKIT_NODE_IP:-}"
    if [ -z "$NODE_IP" ]; then
      NODE_IP=$(dig +short +timeout=3 A "$RAILWAY_TCP_PROXY_DOMAIN" 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)
    fi
    if [ -z "$NODE_IP" ]; then
      NODE_IP=$(getent ahostsv4 "$RAILWAY_TCP_PROXY_DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}' || true)
    fi
    if [ -z "$NODE_IP" ]; then
      log "FATAL: could not resolve $RAILWAY_TCP_PROXY_DOMAIN to an IPv4 address."
      log "FATAL: set LIVEKIT_NODE_IP to the proxy's address to override."
      exit 1
    fi
    BRIDGE_FROM="${RAILWAY_TCP_APPLICATION_PORT:-7881}"
    log "mode=tcp (Railway proxy) ICE/TCP advertised as ${NODE_IP}:${ICE_TCP_PORT} (${RAILWAY_TCP_PROXY_DOMAIN})"
    RTC_BLOCK=$(printf '%s\n' \
      "  tcp_port: ${ICE_TCP_PORT}" \
      "  force_tcp: true" \
      "  use_external_ip: false" \
      "  node_ip: \"$(yesc "$NODE_IP")\"")
  else
    # force_tcp outside Railway (or proxy not injected): bind stock 7881.
    ICE_TCP_PORT="${LIVEKIT_TCP_PORT:-7881}"
    log "mode=tcp (force) tcp_port=${ICE_TCP_PORT}"
    RTC_BLOCK=$(printf '%s\n' \
      "  tcp_port: ${ICE_TCP_PORT}" \
      "  force_tcp: true" \
      "  use_external_ip: true")
  fi
else
  UDP_START="${LIVEKIT_UDP_PORT_START:-50000}"
  UDP_END="${LIVEKIT_UDP_PORT_END:-60000}"
  ICE_TCP_PORT="${LIVEKIT_TCP_PORT:-7881}"
  log "mode=udp-prefer tcp_port=${ICE_TCP_PORT} udp=${UDP_START}-${UDP_END} allow_tcp_fallback=true"
  RTC_BLOCK=$(printf '%s\n' \
    "  tcp_port: ${ICE_TCP_PORT}" \
    "  port_range_start: ${UDP_START}" \
    "  port_range_end: ${UDP_END}" \
    "  use_external_ip: true" \
    "  force_tcp: false" \
    "  allow_tcp_fallback: true")
fi

# --------------------------------------------------------------------- Redis
REDIS_BLOCK=""
if [ -n "${LIVEKIT_REDIS_HOST:-}" ]; then
  _addr="$LIVEKIT_REDIS_HOST"
  case "$_addr" in
    *:*) : ;;
    *) _addr="${_addr}:${LIVEKIT_REDIS_PORT:-6379}" ;;
  esac
  REDIS_BLOCK="redis:
  address: \"$(yesc "$_addr")\""
  [ -n "${LIVEKIT_REDIS_USERNAME:-}" ] && REDIS_BLOCK="$REDIS_BLOCK
  username: \"$(yesc "$LIVEKIT_REDIS_USERNAME")\""
  [ -n "${LIVEKIT_REDIS_PASSWORD:-}" ] && REDIS_BLOCK="$REDIS_BLOCK
  password: \"$(yesc "$LIVEKIT_REDIS_PASSWORD")\""
  log "redis: distributed mode via ${_addr}"
else
  log "redis: not configured — single in-memory node"
fi

# ------------------------------------------------------------------ webhooks
WEBHOOK_BLOCK=""
if [ -n "${LIVEKIT_WEBHOOK_URLS:-}" ]; then
  WEBHOOK_BLOCK="webhook:
  api_key: \"$(yesc "$LIVEKIT_API_KEY")\"
  urls:"
  _old_ifs="$IFS"; IFS=','
  for _u in $LIVEKIT_WEBHOOK_URLS; do
    _u=$(printf '%s' "$_u" | tr -d '[:space:]')
    [ -n "$_u" ] || continue
    WEBHOOK_BLOCK="$WEBHOOK_BLOCK
  - \"$(yesc "$_u")\""
  done
  IFS="$_old_ifs"
fi

# ----------------------------------------------------------------- the config
{
  echo "port: ${PORT}"
  echo "logging:"
  echo "  level: ${LIVEKIT_LOG_LEVEL:-info}"
  echo "  json: false"
  echo "keys:"
  echo "  \"$(yesc "$LIVEKIT_API_KEY")\": \"$(yesc "$LIVEKIT_API_SECRET")\""
  echo "rtc:"
  echo "$RTC_BLOCK"
  echo "room:"
  # Pro Ticket never calls createRoom — join relies on auto_create.
  echo "  auto_create: ${LIVEKIT_ROOM_AUTO_CREATE:-true}"
  echo "  empty_timeout: ${LIVEKIT_ROOM_EMPTY_TIMEOUT:-300}"
  echo "  departure_timeout: ${LIVEKIT_ROOM_DEPARTURE_TIMEOUT:-20}"
  echo "turn:"
  echo "  enabled: false"
  [ -n "$REDIS_BLOCK" ] && echo "$REDIS_BLOCK"
  [ -n "$WEBHOOK_BLOCK" ] && echo "$WEBHOOK_BLOCK"
} > "$CONFIG"
chmod 600 "$CONFIG"

log "generated $CONFIG:"
sed -e "s/$(printf '%s' "$LIVEKIT_API_SECRET" | sed 's/[]\/$*.^[]/\\&/g')/***REDACTED***/g" \
  -e "s/^  password:.*/  password: \"***REDACTED***\"/" "$CONFIG" >&2

# --------------------------------------------------------------- TCP bridge
if [ -n "$BRIDGE_FROM" ] && [ -n "$ICE_TCP_PORT" ] && [ "$BRIDGE_FROM" != "$ICE_TCP_PORT" ]; then
  BRIDGE_TO="${LIVEKIT_BRIDGE_TARGET_IP:-}"
  if [ -z "$BRIDGE_TO" ]; then
    BRIDGE_TO=$(ip -4 -o addr show scope global 2>/dev/null \
      | awk '{print $4}' | cut -d/ -f1 | head -n 1 || true)
  fi
  if [ -z "$BRIDGE_TO" ]; then
    BRIDGE_TO=$(hostname -i 2>/dev/null | tr ' ' '\n' \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n 1 || true)
  fi
  if [ -z "$BRIDGE_TO" ]; then
    log "FATAL: no non-loopback IPv4 address on this container to bridge to."
    log "FATAL: set LIVEKIT_BRIDGE_TARGET_IP to override."
    exit 1
  fi
  log "bridging container :${BRIDGE_FROM} -> ${BRIDGE_TO}:${ICE_TCP_PORT} (ICE/TCP)"
  socat TCP-LISTEN:"$BRIDGE_FROM",fork,reuseaddr \
    TCP:"$BRIDGE_TO":"$ICE_TCP_PORT",retry=5,interval=1 &
fi

exec tini -s -- /livekit-server --config "$CONFIG"
