# LiveKit SFU wrapper for Railway / VPS.
# Railway builds this Dockerfile from GitHub — no registry publish required.
# Upstream is Alpine + /livekit-server; we add boot-time config, ICE/TCP bridge, and tini.
FROM livekit/livekit-server:latest

# socat — bridges Railway TCP proxy container port onto ICE/TCP listen port
# tini — reaps socat and forwards SIGTERM so redeploys drain cleanly
# bind-tools — resolve RAILWAY_TCP_PROXY_DOMAIN to the advertised candidate IP
# iproute2 — non-loopback interface IP for the socat bridge target
RUN apk add --no-cache socat tini bind-tools iproute2 ca-certificates

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV TINI_SUBREAPER=1 \
    TINI_KILL_PROCESS_GROUP=1

# 7880 = signalling / RoomService HTTP; 7881 = ICE/TCP (Railway TCP proxy target)
EXPOSE 7880 7881
ENTRYPOINT ["/entrypoint.sh"]
