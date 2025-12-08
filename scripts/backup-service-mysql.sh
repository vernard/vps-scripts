#!/bin/bash
# Backup MySQL databases from Coolify services

set -e

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

# Check if any services configured
if [[ -z "${BACKUP_SERVICE_MYSQL:-}" ]]; then
    log "No MySQL services configured for backup"
    exit 0
fi

COOLIFY_SERVICES_DIR="/data/coolify/services"
BACKUP_BASE="${BACKUP_DIR:-/backups}/services"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Process each UUID
IFS=',' read -ra UUIDS <<< "$BACKUP_SERVICE_MYSQL"
for uuid in "${UUIDS[@]}"; do
    uuid=$(echo "$uuid" | xargs)  # trim whitespace
    [[ -z "$uuid" ]] && continue

    SERVICE_DIR="$COOLIFY_SERVICES_DIR/$uuid"
    SERVICE_ENV="$SERVICE_DIR/.env"
    COMPOSE_FILE=$(find_compose_file "$SERVICE_DIR")

    if [[ ! -d "$SERVICE_DIR" ]]; then
        log_error "Service directory not found: $SERVICE_DIR"
        continue
    fi

    log "Backing up MySQL service: $uuid"

    # Read credentials from service's .env
    MYSQL_USER=$(read_coolify_env "$SERVICE_ENV" "MYSQL_USER")
    MYSQL_PASSWORD=$(read_coolify_env "$SERVICE_ENV" "MYSQL_PASSWORD")
    MYSQL_DB=$(read_coolify_env "$SERVICE_ENV" "MYSQL_DATABASE")
    MYSQL_ROOT_PASSWORD=$(read_coolify_env "$SERVICE_ENV" "MYSQL_ROOT_PASSWORD")
    BACKUP_DBS=$(read_coolify_env "$SERVICE_ENV" "BACKUP_DATABASES")

    # Prefer root user for backups if available
    if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
        MYSQL_USER="root"
        MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD"
    fi

    # Collect databases to backup:
    # 1. BACKUP_DATABASES if set, otherwise MYSQL_DATABASE
    # 2. Any env vars ending with _DATABASE
    if [[ -n "$BACKUP_DBS" ]]; then
        DBS="$BACKUP_DBS"
    else
        DBS="$MYSQL_DB"
    fi

    # Add any *_DATABASE env vars
    EXTRA_DBS=$(find_database_env_vars "$SERVICE_ENV")
    if [[ -n "$EXTRA_DBS" ]]; then
        if [[ -n "$DBS" ]]; then
            DBS="$DBS,$EXTRA_DBS"
        else
            DBS="$EXTRA_DBS"
        fi
    fi

    # Deduplicate database list
    DBS=$(echo "$DBS" | tr ',' '\n' | sort -u | paste -sd ',' -)

    if [[ -z "$MYSQL_USER" ]] || [[ -z "$MYSQL_PASSWORD" ]]; then
        log_error "Missing MySQL credentials for $uuid"
        continue
    fi

    # Find a running container (tries db, mysql, mariadb in order)
    CONTAINER=$(find_running_container "$COMPOSE_FILE" "db" "mysql" "mariadb")
    if [[ $? -ne 0 ]]; then
        if [[ -n "$CONTAINER" ]]; then
            log_error "No running container found for $uuid (tried: $CONTAINER)"
        else
            log_error "Could not find MySQL container for $uuid"
        fi
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
        docker exec "$CONTAINER" mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$db" | gzip > "$BACKUP_PATH/${db}.sql.gz" || {
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

log "MySQL service backup completed"
