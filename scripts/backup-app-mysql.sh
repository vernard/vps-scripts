#!/bin/bash
# Backup MySQL databases from Coolify applications

set -e

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

# Check if any apps configured
if [[ -z "${BACKUP_APP_MYSQL:-}" ]]; then
    log "No MySQL apps configured for backup"
    exit 0
fi

COOLIFY_APPS_DIR="/data/coolify/applications"
BACKUP_BASE="${BACKUP_DIR:-/backups}/apps"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Process each UUID
IFS=',' read -ra UUIDS <<< "$BACKUP_APP_MYSQL"
for uuid in "${UUIDS[@]}"; do
    uuid=$(echo "$uuid" | xargs)  # trim whitespace
    [[ -z "$uuid" ]] && continue

    APP_DIR="$COOLIFY_APPS_DIR/$uuid"
    APP_ENV="$APP_DIR/.env"
    COMPOSE_FILE="$APP_DIR/docker-compose.yml"

    if [[ ! -d "$APP_DIR" ]]; then
        log_error "App directory not found: $APP_DIR"
        continue
    fi

    log "Backing up MySQL app: $uuid"

    # Read credentials from app's .env
    MYSQL_USER=$(read_coolify_env "$APP_ENV" "MYSQL_USER")
    MYSQL_PASSWORD=$(read_coolify_env "$APP_ENV" "MYSQL_PASSWORD")
    MYSQL_DB=$(read_coolify_env "$APP_ENV" "MYSQL_DATABASE")
    MYSQL_ROOT_PASSWORD=$(read_coolify_env "$APP_ENV" "MYSQL_ROOT_PASSWORD")
    BACKUP_DBS=$(read_coolify_env "$APP_ENV" "BACKUP_DATABASES")

    # Prefer root user for backups if available
    if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
        MYSQL_USER="root"
        MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD"
    fi

    # Use BACKUP_DATABASES if set, otherwise use MYSQL_DATABASE
    if [[ -n "$BACKUP_DBS" ]]; then
        DBS="$BACKUP_DBS"
    else
        DBS="$MYSQL_DB"
    fi

    if [[ -z "$MYSQL_USER" ]] || [[ -z "$MYSQL_PASSWORD" ]]; then
        log_error "Missing MySQL credentials for $uuid"
        continue
    fi

    # Find container name (look for mysql/mariadb service)
    CONTAINER=$(get_container_name "$COMPOSE_FILE" "mysql")
    if [[ -z "$CONTAINER" ]]; then
        CONTAINER=$(get_container_name "$COMPOSE_FILE" "mariadb")
    fi
    if [[ -z "$CONTAINER" ]]; then
        CONTAINER=$(get_container_name "$COMPOSE_FILE" "db")
    fi

    if [[ -z "$CONTAINER" ]]; then
        log_error "Could not find MySQL container for $uuid"
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

log "MySQL app backup completed"
