#!/bin/bash
# Backup PostgreSQL databases from Coolify services

set -e

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

# Check if any services configured
if [[ -z "${BACKUP_SERVICE_POSTGRES:-}" ]]; then
    log "No PostgreSQL services configured for backup"
    exit 0
fi

COOLIFY_SERVICES_DIR="/data/coolify/services"
BACKUP_BASE="${BACKUP_DIR:-/backups}/services"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Process each UUID
IFS=',' read -ra UUIDS <<< "$BACKUP_SERVICE_POSTGRES"
for uuid in "${UUIDS[@]}"; do
    uuid=$(echo "$uuid" | xargs)  # trim whitespace
    [[ -z "$uuid" ]] && continue

    SERVICE_DIR="$COOLIFY_SERVICES_DIR/$uuid"
    SERVICE_ENV="$SERVICE_DIR/.env"
    COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"

    if [[ ! -d "$SERVICE_DIR" ]]; then
        log_error "Service directory not found: $SERVICE_DIR"
        continue
    fi

    log "Backing up PostgreSQL service: $uuid"

    # Read credentials from service's .env
    PG_USER=$(read_coolify_env "$SERVICE_ENV" "POSTGRES_USER")
    PG_PASSWORD=$(read_coolify_env "$SERVICE_ENV" "POSTGRES_PASSWORD")
    PG_DB=$(read_coolify_env "$SERVICE_ENV" "POSTGRES_DB")
    BACKUP_DBS=$(read_coolify_env "$SERVICE_ENV" "BACKUP_DATABASES")

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

    # Copy service's .env file
    if [[ -f "$SERVICE_ENV" ]]; then
        cp "$SERVICE_ENV" "$BACKUP_PATH/service.env"
    fi

    log "Backup completed for $uuid"
done

# Cleanup old backups
cleanup_old_backups "$BACKUP_BASE"

# Sync to remote
sync_to_remote "$BACKUP_BASE"

log "PostgreSQL service backup completed"
