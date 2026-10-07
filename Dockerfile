# Minimal Alpine image with the PostgreSQL 18 client (pg_dump) baked in at
# build time (Alpine v3.23 ships postgresql18-client 18.6). No runtime mount.
FROM alpine:3.23

RUN apk add --no-cache \
        postgresql18-client \
        rclone \
        ca-certificates \
        tzdata \
        tini \
    && adduser -D -u 10001 -h /home/backup backup

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /backups \
    && chown backup:backup /backups

USER backup
WORKDIR /home/backup

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
