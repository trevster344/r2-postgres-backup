#!/bin/sh
set -eu

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# --- Required configuration -------------------------------------------------
: "${PGHOST:?PGHOST is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"

# --- Optional configuration with defaults -----------------------------------
: "${PGPORT:=5432}"
: "${R2_PATH_PREFIX:=}"
: "${BACKUP_INTERVAL_SECONDS:=86400}"
: "${BACKUP_DIR:=/backups}"
: "${PG_DUMP_MODE:=database}"

case "$PG_DUMP_MODE" in
    database) : "${PGDATABASE:?PGDATABASE is required when PG_DUMP_MODE=database}" ;;
    cluster)  : ;;
    *) echo "ERROR: PG_DUMP_MODE must be 'database' or 'cluster'" >&2; exit 1 ;;
esac

export PGHOST PGPORT PGUSER PGPASSWORD
[ -n "${PGDATABASE:-}" ] && export PGDATABASE

# --- Verify the baked-in clients are runnable -------------------------------
command -v pg_dump >/dev/null 2>&1 && pg_dump --version >/dev/null 2>&1 \
    || { echo "ERROR: pg_dump not runnable" >&2; exit 1; }
command -v pg_dumpall >/dev/null 2>&1 && pg_dumpall --version >/dev/null 2>&1 \
    || { echo "ERROR: pg_dumpall not runnable" >&2; exit 1; }

# --- Configure rclone entirely from the environment -------------------------
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"

mkdir -p "$BACKUP_DIR"

REMOTE="r2:${R2_BUCKET}"
if [ -n "$R2_PATH_PREFIX" ]; then
    REMOTE="${REMOTE}/${R2_PATH_PREFIX}"
fi

run_backup() {
    ts="$(date -u +%Y%m%d-%H%M%S)"

    if [ "$PG_DUMP_MODE" = "cluster" ]; then
        file="${BACKUP_DIR}/cluster-${ts}.sql"
        log "Dumping entire cluster (pg_dumpall --clean) from ${PGHOST}:${PGPORT} -> ${file}"
        if ! pg_dumpall --clean -f "$file"; then
            log "pg_dumpall FAILED"
            rm -f "$file"
            return 1
        fi
    else
        file="${BACKUP_DIR}/${PGDATABASE}-${ts}.dump"
        log "Dumping database '${PGDATABASE}' from ${PGHOST}:${PGPORT} -> ${file}"
        if ! pg_dump -Fc -f "$file"; then
            log "pg_dump FAILED for '${PGDATABASE}'"
            rm -f "$file"
            return 1
        fi
    fi

    log "Uploading ${file} -> ${REMOTE}/"
    if ! rclone copy "$file" "${REMOTE}/"; then
        log "rclone upload FAILED for ${file}"
        rm -f "$file"
        return 1
    fi

    rm -f "$file"
    log "Backup complete: uploaded to ${REMOTE}/"
    return 0
}

log "Starting backup loop (mode=${PG_DUMP_MODE}, every ${BACKUP_INTERVAL_SECONDS}s)"
while true; do
    run_backup || log "Backup run failed; retrying in ${BACKUP_INTERVAL_SECONDS}s"
    log "Sleeping ${BACKUP_INTERVAL_SECONDS}s"
    # Run sleep in the background and wait so signals (SIGTERM) are handled promptly.
    sleep "$BACKUP_INTERVAL_SECONDS" &
    wait $!
done
