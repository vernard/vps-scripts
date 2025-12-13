#!/bin/bash
# Backup entire Coolify installation for VPS migration

# Note: We don't use set -e here because we need to handle errors gracefully
# and send notifications even when individual backup steps fail.

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

COOLIFY_DIR="/data/coolify"
BACKUP_BASE="${BACKUP_DIR:-/backups}/coolify-setup"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_PATH="$BACKUP_BASE/$TIMESTAMP"
START_TIME=$(date +%s)

# Track for notifications
SUCCESS_COUNT=0
FAIL_COUNT=0
BACKED_UP_LIST=""
ERROR_MESSAGES=""

if [[ ! -d "$COOLIFY_DIR" ]]; then
    log_error "Coolify directory not found: $COOLIFY_DIR"
    ERROR_MESSAGES="Coolify directory not found: $COOLIFY_DIR"
    FAIL_COUNT=1
    END_TIME=$(date +%s)
    notify_backup_complete "backup-coolify-setup" "$SUCCESS_COUNT" "$FAIL_COUNT" "$BACKED_UP_LIST" "$ERROR_MESSAGES" "$((END_TIME - START_TIME))"
    exit 1
fi

# Signal start to healthcheck service
ping_healthcheck "start"

log "Starting Coolify setup backup"

mkdir -p "$BACKUP_PATH"

# Backup Coolify's internal PostgreSQL database
log "Backing up Coolify's internal database"
COOLIFY_DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E '^coolify-db' | head -1)

if [[ -n "$COOLIFY_DB_CONTAINER" ]]; then
    # Use a temp file and pipefail to catch pg_dumpall errors
    DB_BACKUP_ERROR=""
    DB_BACKUP_OUTPUT=$(mktemp)
    if (set -o pipefail; docker exec "$COOLIFY_DB_CONTAINER" pg_dumpall -U coolify 2>&1 | zstd > "$BACKUP_PATH/coolify-db.sql.zst") 2>"$DB_BACKUP_OUTPUT"; then
        # Verify the backup is not empty (more than just zstd header)
        if [[ -f "$BACKUP_PATH/coolify-db.sql.zst" ]] && [[ $(stat -c%s "$BACKUP_PATH/coolify-db.sql.zst" 2>/dev/null || stat -f%z "$BACKUP_PATH/coolify-db.sql.zst" 2>/dev/null) -gt 100 ]]; then
            ((SUCCESS_COUNT++))
            BACKED_UP_LIST+="• Coolify PostgreSQL database"$'\n'
            log "Coolify database backed up successfully"
        else
            ((FAIL_COUNT++))
            ERROR_MESSAGES+="• Coolify database backup appears empty"$'\n'
            log_error "Coolify database backup appears empty"
            rm -f "$BACKUP_PATH/coolify-db.sql.zst"
        fi
    else
        DB_BACKUP_ERROR=$(cat "$DB_BACKUP_OUTPUT" 2>/dev/null | head -5)
        ((FAIL_COUNT++))
        ERROR_MESSAGES+="• Failed to backup Coolify database: ${DB_BACKUP_ERROR:-unknown error}"$'\n'
        log_error "Failed to backup Coolify database: ${DB_BACKUP_ERROR:-unknown error}"
        rm -f "$BACKUP_PATH/coolify-db.sql.zst"
    fi
    rm -f "$DB_BACKUP_OUTPUT"
else
    ((FAIL_COUNT++))
    ERROR_MESSAGES+="• Coolify database container not found"$'\n'
    log_error "Coolify database container not found"
fi

# Backup Coolify configuration directory
log "Backing up Coolify configuration"
if tar --zstd -cf "$BACKUP_PATH/coolify-data.tar.zst" \
    --exclude='*/backups/*' \
    --exclude='*/logs/*' \
    --exclude='*/ssh/mux/*' \
    -C /data coolify; then
    ((SUCCESS_COUNT++))
    BACKED_UP_LIST+="• Coolify configuration directory"$'\n'
else
    ((FAIL_COUNT++))
    ERROR_MESSAGES+="• Failed to backup Coolify data directory"$'\n'
    log_error "Failed to backup Coolify data directory"
fi

# Backup SSH keys if they exist
if [[ -d "$COOLIFY_DIR/ssh" ]]; then
    log "Backing up SSH keys"
    if cp -r "$COOLIFY_DIR/ssh" "$BACKUP_PATH/ssh"; then
        # Remove mux directory (contains runtime socket files)
        rm -rf "$BACKUP_PATH/ssh/mux"
        ((SUCCESS_COUNT++))
        BACKED_UP_LIST+="• SSH keys"$'\n'
    else
        ((FAIL_COUNT++))
        ERROR_MESSAGES+="• Failed to backup SSH keys"$'\n'
    fi
fi

# Create manifest with backup info
cat > "$BACKUP_PATH/manifest.txt" << EOF
Coolify Backup Manifest
=======================
Date: $(date)
Hostname: $(hostname)
Coolify Version: $(docker inspect coolify --format '{{.Config.Image}}' 2>/dev/null || echo 'unknown')

Contents:
- coolify-db.sql.zst: Coolify's internal PostgreSQL database
- coolify-data.tar.zst: /data/coolify directory (configs, docker-compose files)
- ssh/: SSH keys (if present)

Restore Instructions:
1. Install Coolify on new VPS
2. Stop Coolify: docker compose -f /data/coolify/source/docker-compose.yml down
3. Restore database: zstd -dc coolify-db.sql.zst | docker exec -i coolify-db psql -U coolify
4. Extract data: tar --zstd -xf coolify-data.tar.zst -C /data
5. Restore SSH keys to /data/coolify/ssh
6. Restart Coolify: docker compose -f /data/coolify/source/docker-compose.yml up -d
EOF

log "Coolify backup completed: $BACKUP_PATH"

# Backup vps-scripts .env file (separate directory)
VPS_SCRIPTS_BACKUP_BASE="${BACKUP_DIR:-/backups}/vps-scripts"
VPS_SCRIPTS_BACKUP_PATH="$VPS_SCRIPTS_BACKUP_BASE/$TIMESTAMP"

if [[ -f "$PROJECT_ROOT/.env" ]]; then
    log "Backing up vps-scripts .env"
    mkdir -p "$VPS_SCRIPTS_BACKUP_PATH"
    if cp "$PROJECT_ROOT/.env" "$VPS_SCRIPTS_BACKUP_PATH/.env"; then
        ((SUCCESS_COUNT++))
        BACKED_UP_LIST+="• vps-scripts .env"$'\n'
        log "vps-scripts backup completed: $VPS_SCRIPTS_BACKUP_PATH"
    else
        ((FAIL_COUNT++))
        ERROR_MESSAGES+="• Failed to backup vps-scripts .env"$'\n'
    fi
else
    log "No vps-scripts .env found at $PROJECT_ROOT/.env"
fi

# Cleanup old backups
cleanup_old_backups "$BACKUP_BASE"
cleanup_old_backups "$VPS_SCRIPTS_BACKUP_BASE"

# Sync to remote
sync_to_remote "${BACKUP_DIR:-/backups}"

log "All backups completed"

# Calculate duration and send notifications
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

notify_backup_complete \
    "backup-coolify-setup" \
    "$SUCCESS_COUNT" \
    "$FAIL_COUNT" \
    "$BACKED_UP_LIST" \
    "$ERROR_MESSAGES" \
    "$DURATION"
