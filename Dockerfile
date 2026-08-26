# Build on the host first (Mako native backend is host-only):
#   mako build --release -p lib -o bonodis
#   docker build -t bonodis .
# Add --requirepass in `docker run ... bonodis --bind 0.0.0.0 ... --requirepass secret` if the port is exposed.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY bonodis /usr/local/bin/bonodis
RUN mkdir -p /data
VOLUME /data
EXPOSE 6379
ENTRYPOINT ["bonodis"]
CMD ["--bind", "0.0.0.0", "--port", "6379", "--dir", "/data", "--appendonly", "yes", "--appendfsync", "everysec", "--maxmemory", "268435456", "--protected-mode", "no", "--maxclients", "50000", "--accept-threads", "4"]
