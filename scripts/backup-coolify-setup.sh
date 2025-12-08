#!/bin/bash
# Backup entire Coolify installation for VPS migration

set -e

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

COOLIFY_DIR="/data/coolify"
BACKUP_BASE="${BACKUP_DIR:-/backups}/coolify-setup"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_PATH="$BACKUP_BASE/$TIMESTAMP"

if [[ ! -d "$COOLIFY_DIR" ]]; then
    log_error "Coolify directory not found: $COOLIFY_DIR"
    exit 1
fi

log "Starting Coolify setup backup"

mkdir -p "$BACKUP_PATH"

# Backup Coolify's internal PostgreSQL database
log "Backing up Coolify's internal database"
COOLIFY_DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E '^coolify-db' | head -1)

if [[ -n "$COOLIFY_DB_CONTAINER" ]]; then
    docker exec "$COOLIFY_DB_CONTAINER" pg_dumpall -U coolify | gzip > "$BACKUP_PATH/coolify-db.sql.gz" || {
        log_error "Failed to backup Coolify database"
    }
else
    log_error "Coolify database container not found"
fi

# Backup Coolify configuration directory
log "Backing up Coolify configuration"
tar -czf "$BACKUP_PATH/coolify-data.tar.gz" \
    --exclude='*/backups/*' \
    --exclude='*/logs/*' \
    -C /data coolify || {
    log_error "Failed to backup Coolify data directory"
}

# Backup SSH keys if they exist
if [[ -d "$COOLIFY_DIR/ssh" ]]; then
    log "Backing up SSH keys"
    cp -r "$COOLIFY_DIR/ssh" "$BACKUP_PATH/ssh"
fi

# Create manifest with backup info
cat > "$BACKUP_PATH/manifest.txt" << EOF
Coolify Backup Manifest
=======================
Date: $(date)
Hostname: $(hostname)
Coolify Version: $(docker inspect coolify --format '{{.Config.Image}}' 2>/dev/null || echo 'unknown')

Contents:
- coolify-db.sql.gz: Coolify's internal PostgreSQL database
- coolify-data.tar.gz: /data/coolify directory (configs, docker-compose files)
- ssh/: SSH keys (if present)

Restore Instructions:
1. Install Coolify on new VPS
2. Stop Coolify: docker compose -f /data/coolify/source/docker-compose.yml down
3. Restore database: gunzip -c coolify-db.sql.gz | docker exec -i coolify-db psql -U coolify
4. Extract data: tar -xzf coolify-data.tar.gz -C /data
5. Restore SSH keys to /data/coolify/ssh
6. Restart Coolify: docker compose -f /data/coolify/source/docker-compose.yml up -d
EOF

log "Backup completed: $BACKUP_PATH"

# Cleanup old backups
cleanup_old_backups "$BACKUP_BASE"

# Sync to remote
sync_to_remote "$BACKUP_BASE"

log "Coolify setup backup completed"
