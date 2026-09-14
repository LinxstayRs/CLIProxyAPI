# Official multi-architecture release image; keep tag and digest in sync.
FROM eceasy/cli-proxy-api:v7.3.3@sha256:f9abbf3fa5fed1ca5410cf207eeae6d7c3d7d1b5305397fc928d4d43d4474d15

USER root

RUN mkdir -p /CLIProxyAPI /data/auths /data/plugins

# Binary and example config are supplied by the release image.
COPY scripts/docker/zeabur-entrypoint.sh /usr/local/bin/zeabur-entrypoint

RUN chmod 0755 /usr/local/bin/zeabur-entrypoint

WORKDIR /CLIProxyAPI

ENV TZ=Asia/Shanghai \
    PORT=8080 \
    CPA_DATA_DIR=/data

EXPOSE 8080
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/zeabur-entrypoint"]
# The wrapper supplies the command and config path.
CMD []