#!/bin/bash
# Backup PostgreSQL databases from Coolify applications

set -e

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

# Check if any apps configured
if [[ -z "${BACKUP_APP_POSTGRES:-}" ]]; then
    log "No PostgreSQL apps configured for backup"
    exit 0
fi

COOLIFY_APPS_DIR="/data/coolify/applications"
BACKUP_BASE="${BACKUP_DIR:-/backups}/apps"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Process each UUID
IFS=',' read -ra UUIDS <<< "$BACKUP_APP_POSTGRES"
for uuid in "${UUIDS[@]}"; do
    uuid=$(echo "$uuid" | xargs)  # trim whitespace
    [[ -z "$uuid" ]] && continue

    APP_DIR="$COOLIFY_APPS_DIR/$uuid"
    APP_ENV="$APP_DIR/.env"
    COMPOSE_FILE=$(find_compose_file "$APP_DIR")

    if [[ ! -d "$APP_DIR" ]]; then
        log_error "App directory not found: $APP_DIR"
        continue
    fi

    log "Backing up PostgreSQL app: $uuid"

    # Read credentials from app's .env
    PG_USER=$(read_coolify_env "$APP_ENV" "POSTGRES_USER")
    PG_PASSWORD=$(read_coolify_env "$APP_ENV" "POSTGRES_PASSWORD")
    PG_DB=$(read_coolify_env "$APP_ENV" "POSTGRES_DB")
    BACKUP_DBS=$(read_coolify_env "$APP_ENV" "BACKUP_DATABASES")

    # Use BACKUP_DATABASES if set, otherwise use POSTGRES_DB
    if [[ -n "$BACKUP_DBS" ]]; then
        DBS="$BACKUP_DBS"
    else
        DBS="$PG_DB"
    fi

    if [[ -z "$PG_USER" ]] || [[ -z "$PG_PASSWORD" ]]; then
        log_error "Missing PostgreSQL credentials for $uuid"
        continue
    fi

    # Find container name (look for postgres service)
    CONTAINER=$(get_container_name "$COMPOSE_FILE" "postgres")
    if [[ -z "$CONTAINER" ]]; then
        CONTAINER=$(get_container_name "$COMPOSE_FILE" "db")
    fi

    if [[ -z "$CONTAINER" ]]; then
        log_error "Could not find PostgreSQL container for $uuid"
        continue
    fi

    # Create backup directory
    BACKUP_PATH="$BACKUP_BASE/$uuid/$TIMESTAMP"
    mkdir -p "$BACKUP_PATH"

    # Backup each database
    IFS=',' read -ra DB_LIST <<< "$DBS"
    for db in "${DB_LIST[@]}"; do
        db=$(echo "$db" | xargs)
        [[ -z "$db" ]] && continue

        log "Dumping database: $db"
        docker exec "$CONTAINER" pg_dump -U "$PG_USER" "$db" | gzip > "$BACKUP_PATH/${db}.sql.gz" || {
            log_error "Failed to dump database $db"
        }
    done

    # Copy app's .env file
    if [[ -f "$APP_ENV" ]]; then
        cp "$APP_ENV" "$BACKUP_PATH/app.env"
    fi

    log "Backup completed for $uuid"
done

# Cleanup old backups
cleanup_old_backups "$BACKUP_BASE"

# Sync to remote
sync_to_remote "$BACKUP_BASE"

log "PostgreSQL app backup completed"
