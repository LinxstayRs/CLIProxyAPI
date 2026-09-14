FROM golang:1.26-alpine AS request-filter-builder

WORKDIR /src
COPY go.mod ./
COPY cmd/zeabur-request-filter ./cmd/zeabur-request-filter
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/zeabur-request-filter ./cmd/zeabur-request-filter

# Official multi-architecture release image; keep tag and digest in sync.
FROM eceasy/cli-proxy-api:v7.3.15@sha256:86032129fa65496428752ec6e5c7480f07fde137160b728cd850cc65e9eaa391

USER root

RUN mkdir -p /CLIProxyAPI /data/auths /data/plugins

# Binary and example config are supplied by the release image. The small
# deployment-specific filter rejects known abusive clients before CPA sees them.
COPY --from=request-filter-builder /out/zeabur-request-filter /usr/local/bin/zeabur-request-filter
COPY scripts/docker/zeabur-entrypoint.sh /usr/local/bin/zeabur-entrypoint

RUN chmod 0755 /usr/local/bin/zeabur-entrypoint /usr/local/bin/zeabur-request-filter

WORKDIR /CLIProxyAPI

ENV TZ=Asia/Shanghai \
    PORT=8080 \
    CPA_DATA_DIR=/data \
    CPA_INTERNAL_PORT=8317 \
    CPA_BLOCKED_DOMAINS=skynexyl.com \
    CPA_BLOCKED_REQUESTED_WITH=com.skynex.app

EXPOSE 8080
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/zeabur-entrypoint"]
# The wrapper supplies the command and config path.
CMD []
