#!/bin/bash
# Unified database backup script for Coolify services and applications
# Supports MySQL, PostgreSQL, SQLite, and file storage
#
# Usage:
#   ./backup-databases.sh                       # Auto-discover and backup databases
#   ./backup-databases.sh uuid1 uuid2           # Backup specific UUIDs (databases)
#   ./backup-databases.sh --files-only uuid1    # Backup file storage only

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

BACKUP_BASE="${BACKUP_DIR:-/backups}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
START_TIME=$(date +%s)

# Track if any backups were performed
BACKUP_COUNT=0
BACKUP_PATHS=()

# Track for notifications
SUCCESS_COUNT=0
FAIL_COUNT=0
BACKED_UP_LIST=""
ERROR_MESSAGES=""

# Record a successful backup
record_success() {
    local uuid="$1"
    local type="$2"
    ((SUCCESS_COUNT++))
    BACKED_UP_LIST+="• $uuid ($type)"$'\n'
}

# Record a failed backup
record_failure() {
    local uuid="$1"
    local type="$2"
    local msg="$3"
    ((FAIL_COUNT++))
    ERROR_MESSAGES+="• $uuid ($type): $msg"$'\n'
}

# Parse --files-only flag
FILES_ONLY=false
if [[ "${1:-}" == "--files-only" ]]; then
    FILES_ONLY=true
    shift
fi

# Collect UUIDs from arguments (if provided)
FILTER_UUIDS=()
if [[ $# -gt 0 ]]; then
    FILTER_UUIDS=("$@")
    if [[ "$FILES_ONLY" == true ]]; then
        log "File-only backup for UUIDs: ${FILTER_UUIDS[*]}"
    else
        log "Filtering backups to UUIDs: ${FILTER_UUIDS[*]}"
    fi
fi

# Check if manual database config exists (excludes BACKUP_FILES)
has_manual_config() {
    [[ -n "${BACKUP_MYSQL:-}" ]] || \
    [[ -n "${BACKUP_POSTGRES:-}" ]] || \
    [[ -n "${BACKUP_SQLITE:-}" ]]
}

# Determine if auto-discovery mode should be used
AUTO_DISCOVER=false
if ! has_manual_config && [[ ${#FILTER_UUIDS[@]} -eq 0 ]]; then
    AUTO_DISCOVER=true
fi

# Check if UUID should be processed (based on filter)
should_process_uuid() {
    local uuid="$1"

    # If no filter, process all
    if [[ ${#FILTER_UUIDS[@]} -eq 0 ]]; then
        return 0
    fi

    # Check if UUID is in filter list
    for filter_uuid in "${FILTER_UUIDS[@]}"; do
        if [[ "$uuid" == "$filter_uuid" ]]; then
            return 0
        fi
    done
    return 1
}

# Find UUID location (service or app) and return base_dir and backup_subdir
# Sets: UUID_BASE_DIR, UUID_BACKUP_SUBDIR
find_uuid_location() {
    local uuid="$1"

    if [[ -d "$COOLIFY_SERVICES_DIR/$uuid" ]]; then
        UUID_BASE_DIR="$COOLIFY_SERVICES_DIR"
        UUID_BACKUP_SUBDIR="services"
        return 0
    elif [[ -d "$COOLIFY_APPS_DIR/$uuid" ]]; then
        UUID_BASE_DIR="$COOLIFY_APPS_DIR"
        UUID_BACKUP_SUBDIR="apps"
        return 0
    else
        return 1
    fi
}

# Backup MySQL database
backup_mysql() {
    local uuid="$1"
    local env_file="$2"
    local compose_file="$3"
    local backup_path="$4"

    # Read credentials (try multiple possible variable names)
    local MYSQL_USER=$(read_coolify_env_multi "$env_file" "MYSQL_USER" "SERVICE_USER_MYSQL" "DB_USERNAME")
    local MYSQL_PASSWORD=$(read_coolify_env_multi "$env_file" "MYSQL_PASSWORD" "SERVICE_PASSWORD_MYSQL" "SERVICE_PASSWORD_64_MYSQL" "DB_PASSWORD")
    local MYSQL_DB=$(read_coolify_env_multi "$env_file" "MYSQL_DATABASE" "MYSQL_DB" "DB_DATABASE")
    local MYSQL_ROOT_PASSWORD=$(read_coolify_env_multi "$env_file" "MYSQL_ROOT_PASSWORD" "SERVICE_PASSWORD_MYSQL_ROOT")
    local BACKUP_DBS=$(read_coolify_env "$env_file" "BACKUP_DATABASES")

    # Prefer root user for backups if available
    if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
        MYSQL_USER="root"
        MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD"
    fi

    # Collect databases to backup
    local DBS=""
    if [[ -n "$BACKUP_DBS" ]]; then
        DBS="$BACKUP_DBS"
    else
        DBS="$MYSQL_DB"
    fi

    # Add any *_DATABASE or *_DB env vars
    local EXTRA_DBS=$(find_database_env_vars "$env_file")
    if [[ -n "$EXTRA_DBS" ]]; then
        if [[ -n "$DBS" ]]; then
            DBS="$DBS,$EXTRA_DBS"
        else
            DBS="$EXTRA_DBS"
        fi
    fi

    # Deduplicate
    DBS=$(echo "$DBS" | tr ',' '\n' | sort -u | paste -sd ',' -)

    if [[ -z "$MYSQL_USER" ]] || [[ -z "$MYSQL_PASSWORD" ]]; then
        log_error "Missing MySQL credentials for $uuid"
        return 1
    fi

    # Find running container
    local CONTAINER=$(find_running_container "$compose_file" "db" "mysql" "mariadb")
    if [[ $? -ne 0 ]]; then
        log_error "No running MySQL container found for $uuid"
        return 1
    fi

    # Verify container is actually a MySQL/MariaDB container
    local image=$(docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null)
    if [[ ! "$image" =~ mysql|mariadb ]]; then
        log_error "Container $CONTAINER is not a MySQL/MariaDB container (image: $image)"
        return 1
    fi

    # Create backup directory
    mkdir -p "$backup_path"

    # Backup each database
    IFS=',' read -ra DB_LIST <<< "$DBS"
    for db in "${DB_LIST[@]}"; do
        db=$(echo "$db" | xargs)
        [[ -z "$db" ]] && continue

        log "  Dumping MySQL database: $db"
        docker exec "$CONTAINER" mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$db" 2>/dev/null | zstd > "$backup_path/${db}.sql.zst" || {
            log_error "  Failed to dump database $db"
        }
    done

    return 0
}

# Backup PostgreSQL database
backup_postgres() {
    local uuid="$1"
    local env_file="$2"
    local compose_file="$3"
    local backup_path="$4"

    # Read credentials (try multiple possible variable names)
    local PG_USER=$(read_coolify_env_multi "$env_file" "POSTGRES_USER" "SERVICE_USER_POSTGRES")
    local PG_DB=$(read_coolify_env_multi "$env_file" "POSTGRES_DB" "POSTGRES_DATABASE")
    local BACKUP_DBS=$(read_coolify_env "$env_file" "BACKUP_DATABASES")

    # Collect databases to backup
    local DBS=""
    if [[ -n "$BACKUP_DBS" ]]; then
        DBS="$BACKUP_DBS"
    else
        DBS="$PG_DB"
    fi

    # Add any *_DATABASE or *_DB env vars
    local EXTRA_DBS=$(find_database_env_vars "$env_file")
    if [[ -n "$EXTRA_DBS" ]]; then
        if [[ -n "$DBS" ]]; then
            DBS="$DBS,$EXTRA_DBS"
        else
            DBS="$EXTRA_DBS"
        fi
    fi

    # Deduplicate
    DBS=$(echo "$DBS" | tr ',' '\n' | sort -u | paste -sd ',' -)

    if [[ -z "$PG_USER" ]]; then
        log_error "Missing PostgreSQL credentials for $uuid"
        return 1
    fi

    # Find running container
    local CONTAINER=$(find_running_container "$compose_file" "db" "postgres" "postgresql")
    if [[ $? -ne 0 ]]; then
        log_error "No running PostgreSQL container found for $uuid"
        return 1
    fi

    # Verify container is actually a PostgreSQL container
    local image=$(docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null)
    if [[ ! "$image" =~ postgres ]]; then
        log_error "Container $CONTAINER is not a PostgreSQL container (image: $image)"
        return 1
    fi

    # Create backup directory
    mkdir -p "$backup_path"

    # Backup each database
    IFS=',' read -ra DB_LIST <<< "$DBS"
    for db in "${DB_LIST[@]}"; do
        db=$(echo "$db" | xargs)
        [[ -z "$db" ]] && continue

        log "  Dumping PostgreSQL database: $db"
        docker exec "$CONTAINER" pg_dump -U "$PG_USER" --no-owner --no-acl "$db" 2>/dev/null | zstd > "$backup_path/${db}.sql.zst" || {
            log_error "  Failed to dump database $db"
        }
    done

    return 0
}

# Backup SQLite database
backup_sqlite() {
    local uuid="$1"
    local env_file="$2"
    local compose_file="$3"
    local backup_path="$4"

    # Find service with SQLite data volume
    local SQLITE_INFO=$(find_sqlite_service "$compose_file")
    if [[ -z "$SQLITE_INFO" ]]; then
        log_error "No SQLite data volume (db-data/dbdata) found for $uuid"
        return 1
    fi

    # Parse service name and mount path
    local SERVICE_NAME="${SQLITE_INFO%%:*}"
    local MOUNT_PATH="${SQLITE_INFO#*:}"

    log "  Found SQLite volume in service '$SERVICE_NAME' at path '$MOUNT_PATH'"

    # Get container name
    local CONTAINER=$(get_container_name "$compose_file" "$SERVICE_NAME")
    if [[ -z "$CONTAINER" ]]; then
        log_error "Could not find container for service $SERVICE_NAME"
        return 1
    fi

    # Verify container is running
    if ! check_container "$CONTAINER"; then
        log_error "Container '$CONTAINER' is not running for $uuid"
        return 1
    fi

    # Create backup directory
    mkdir -p "$backup_path"

    # Copy SQLite data from container
    log "  Copying SQLite data from $CONTAINER:$MOUNT_PATH"
    docker cp "$CONTAINER:$MOUNT_PATH" "$backup_path/sqlite-data" || {
        log_error "  Failed to copy SQLite data from $CONTAINER"
        return 1
    }

    # Compress the backup
    tar --zstd -cf "$backup_path/sqlite-data.tar.zst" -C "$backup_path" sqlite-data && rm -rf "$backup_path/sqlite-data"

    return 0
}

# Backup file storage volumes
backup_files() {
    local uuid="$1"
    local env_file="$2"
    local compose_file="$3"
    local backup_path="$4"

    # Find storage volumes
    local STORAGE_VOLUMES=$(find_storage_volumes "$compose_file")
    if [[ -z "$STORAGE_VOLUMES" ]]; then
        log_error "No file storage volumes found for $uuid"
        return 1
    fi

    # Create backup directory
    mkdir -p "$backup_path"

    local backup_count=0

    # Process each storage volume
    while IFS=: read -r service_name vol_name mount_path; do
        [[ -z "$service_name" ]] && continue

        log "  Found storage volume '$vol_name' in service '$service_name' at '$mount_path'"

        # Get container name
        local CONTAINER=$(get_container_name "$compose_file" "$service_name")
        if [[ -z "$CONTAINER" ]]; then
            log_error "  Could not find container for service $service_name"
            continue
        fi

        # Verify container is running
        if ! check_container "$CONTAINER"; then
            log_error "  Container '$CONTAINER' is not running"
            continue
        fi

        # Copy files from container
        log "  Copying files from $CONTAINER:$mount_path"
        local temp_dir="$backup_path/${vol_name}-temp"
        docker cp "$CONTAINER:$mount_path" "$temp_dir" || {
            log_error "  Failed to copy files from $CONTAINER"
            continue
        }

        # Compress the backup using volume name
        tar --zstd -cf "$backup_path/${vol_name}.tar.zst" -C "$backup_path" "${vol_name}-temp" && rm -rf "$temp_dir"
        ((backup_count++))

    done <<< "$STORAGE_VOLUMES"

    if [[ $backup_count -eq 0 ]]; then
        return 1
    fi

    return 0
}

# Try MySQL backup (returns silently if no MySQL container found)
try_backup_mysql() {
    local uuid="$1" env_file="$2" compose_file="$3" backup_path="$4"

    # Quick check for MySQL container
    local container=$(find_running_container "$compose_file" "db" "mysql" "mariadb" 2>/dev/null) || true
    [[ -z "$container" ]] && return 1

    # Verify it's actually a MySQL/MariaDB container
    local image=$(docker inspect "$container" --format '{{.Config.Image}}' 2>/dev/null)
    [[ ! "$image" =~ mysql|mariadb ]] && return 1

    log "  Trying MySQL backup for $uuid"
    backup_mysql "$uuid" "$env_file" "$compose_file" "$backup_path" 2>/dev/null
}

# Try PostgreSQL backup (returns silently if no PostgreSQL container found)
try_backup_postgres() {
    local uuid="$1" env_file="$2" compose_file="$3" backup_path="$4"

    # Quick check for PostgreSQL container
    local container=$(find_running_container "$compose_file" "db" "postgres" "postgresql" 2>/dev/null) || true
    [[ -z "$container" ]] && return 1

    # Verify it's actually a PostgreSQL container
    local image=$(docker inspect "$container" --format '{{.Config.Image}}' 2>/dev/null)
    [[ ! "$image" =~ postgres ]] && return 1

    log "  Trying PostgreSQL backup for $uuid"
    backup_postgres "$uuid" "$env_file" "$compose_file" "$backup_path" 2>/dev/null
}

# Try SQLite backup (returns silently if no SQLite volume found)
try_backup_sqlite() {
    local uuid="$1" env_file="$2" compose_file="$3" backup_path="$4"

    # Quick check for SQLite volume
    local sqlite_info=$(find_sqlite_service "$compose_file" 2>/dev/null) || true
    [[ -z "$sqlite_info" ]] && return 1

    log "  Trying SQLite backup for $uuid"
    backup_sqlite "$uuid" "$env_file" "$compose_file" "$backup_path" 2>/dev/null
}

# Try Files backup (returns silently if no storage volumes found)
try_backup_files() {
    local uuid="$1" env_file="$2" compose_file="$3" backup_path="$4"

    # Quick check for storage volumes
    local storage_vols=$(find_storage_volumes "$compose_file" 2>/dev/null) || true
    [[ -z "$storage_vols" ]] && return 1

    log "  Trying Files backup for $uuid"
    backup_files "$uuid" "$env_file" "$compose_file" "$backup_path"
}

# Try all backup methods for a UUID (used in auto-discover mode)
try_all_backups() {
    local uuid="$1"

    if ! find_uuid_location "$uuid"; then
        return 1
    fi

    local dir="$UUID_BASE_DIR/$uuid"
    local env_file="$dir/.env"
    local compose_file=$(find_compose_file "$dir")
    local backup_path="$BACKUP_BASE/$UUID_BACKUP_SUBDIR/$uuid/$TIMESTAMP"
    local success=false
    local backup_types=""

    [[ -z "$compose_file" ]] && return 1

    log "Auto-backup ($UUID_BACKUP_SUBDIR): $uuid"

    # Try each database backup method (files excluded from auto-discover)
    if try_backup_mysql "$uuid" "$env_file" "$compose_file" "$backup_path"; then
        success=true
        backup_types+="mysql,"
    fi

    if try_backup_postgres "$uuid" "$env_file" "$compose_file" "$backup_path"; then
        success=true
        backup_types+="postgres,"
    fi

    if try_backup_sqlite "$uuid" "$env_file" "$compose_file" "$backup_path"; then
        success=true
        backup_types+="sqlite,"
    fi

    # Copy .env if any backup succeeded
    if [[ "$success" == true ]] && [[ -f "$env_file" ]]; then
        mkdir -p "$backup_path"
        cp "$env_file" "$backup_path/env.backup"
        ((BACKUP_COUNT++))
        BACKUP_PATHS+=("$backup_path")
        # Record success with the types that worked
        backup_types="${backup_types%,}"  # Remove trailing comma
        record_success "$uuid" "$backup_types"
    fi
}

# Process a single UUID
process_uuid() {
    local uuid="$1"
    local db_type="$2"

    # Find where this UUID lives
    if ! find_uuid_location "$uuid"; then
        log_error "UUID not found in services or applications: $uuid"
        record_failure "$uuid" "$db_type" "UUID not found"
        return 1
    fi

    local dir="$UUID_BASE_DIR/$uuid"
    local env_file="$dir/.env"
    local compose_file=$(find_compose_file "$dir")
    local backup_path="$BACKUP_BASE/$UUID_BACKUP_SUBDIR/$uuid/$TIMESTAMP"

    if [[ -z "$compose_file" ]]; then
        log_error "No docker-compose file found for $uuid"
        record_failure "$uuid" "$db_type" "No docker-compose file"
        return 1
    fi

    log "Backing up $db_type ($UUID_BACKUP_SUBDIR): $uuid"

    local backup_result=0
    case "$db_type" in
        mysql)
            backup_mysql "$uuid" "$env_file" "$compose_file" "$backup_path" || backup_result=$?
            ;;
        postgres)
            backup_postgres "$uuid" "$env_file" "$compose_file" "$backup_path" || backup_result=$?
            ;;
        sqlite)
            backup_sqlite "$uuid" "$env_file" "$compose_file" "$backup_path" || backup_result=$?
            ;;
        files)
            backup_files "$uuid" "$env_file" "$compose_file" "$backup_path" || backup_result=$?
            ;;
        *)
            log_error "Unknown backup type: $db_type"
            record_failure "$uuid" "$db_type" "Unknown backup type"
            return 1
            ;;
    esac

    # Copy .env file and track results
    if [[ $backup_result -eq 0 ]] && [[ -f "$env_file" ]]; then
        cp "$env_file" "$backup_path/env.backup"
        ((BACKUP_COUNT++))
        BACKUP_PATHS+=("$backup_path")
        record_success "$uuid" "$db_type"
    else
        record_failure "$uuid" "$db_type" "Backup failed"
    fi
}

# Process configured UUIDs for a specific database type
process_configured() {
    local config_var="$1"
    local db_type="$2"

    local uuids="${!config_var:-}"
    [[ -z "$uuids" ]] && return 0

    IFS=',' read -ra UUID_LIST <<< "$uuids"
    for uuid in "${UUID_LIST[@]}"; do
        uuid=$(echo "$uuid" | xargs)
        [[ -z "$uuid" ]] && continue

        # Check filter
        if ! should_process_uuid "$uuid"; then
            continue
        fi

        process_uuid "$uuid" "$db_type"
    done
}

# Signal start to healthcheck service
ping_healthcheck "start"

log "Starting backup"

if [[ "$FILES_ONLY" == true ]]; then
    # Files-only mode: backup file storage for specified UUIDs
    if [[ ${#FILTER_UUIDS[@]} -eq 0 ]]; then
        log_error "--files-only requires at least one UUID"
        exit 1
    fi
    for uuid in "${FILTER_UUIDS[@]}"; do
        process_uuid "$uuid" "files"
    done
elif [[ ${#FILTER_UUIDS[@]} -gt 0 ]]; then
    # Direct UUID backup: try all methods on specified UUIDs
    log "Backing up specified UUIDs: ${FILTER_UUIDS[*]}"
    for uuid in "${FILTER_UUIDS[@]}"; do
        try_all_backups "$uuid"
    done
elif [[ "$AUTO_DISCOVER" == true ]]; then
    log "No BACKUP_* config found - auto-discovering running services"
    while IFS= read -r uuid; do
        [[ -z "$uuid" ]] && continue
        try_all_backups "$uuid"
    done < <(discover_running_uuids)
else
    # Process all configured backups (manual config)
    process_configured "BACKUP_MYSQL" "mysql"
    process_configured "BACKUP_POSTGRES" "postgres"
    process_configured "BACKUP_SQLITE" "sqlite"
    process_configured "BACKUP_FILES" "files"
fi

# Cleanup and sync
if [[ $BACKUP_COUNT -gt 0 ]]; then
    if [[ "$FILES_ONLY" == true ]]; then
        # Files-only mode: use FILES retention (default 30 days)
        local files_retention="${BACKUP_FILES_RETENTION_DAYS:-30}"
        cleanup_old_backups "$BACKUP_BASE/services" "$files_retention"
        cleanup_old_backups "$BACKUP_BASE/apps" "$files_retention"
    else
        # Normal mode: use default retention, skip directories with file backups
        cleanup_old_backups "$BACKUP_BASE/services" "${BACKUP_RETENTION_DAYS:-7}" "true"
        cleanup_old_backups "$BACKUP_BASE/apps" "${BACKUP_RETENTION_DAYS:-7}" "true"
    fi
    sync_to_remote "$BACKUP_BASE"
fi

log "Backup completed ($BACKUP_COUNT backups)"

# List backup files with sizes (excludes .env, shows only actual backups)
if [[ ${#BACKUP_PATHS[@]} -gt 0 ]]; then
    log ""
    log "Backup files:"
    for path in "${BACKUP_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            find "$path" -name "*.zst" -type f | while read -r file; do
                size=$(ls -lh "$file" | awk '{print $5}')
                log "  $size  $file"
            done
        fi
    done
fi

# Calculate duration and send notifications
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

notify_backup_complete \
    "backup-databases" \
    "$SUCCESS_COUNT" \
    "$FAIL_COUNT" \
    "$BACKED_UP_LIST" \
    "$ERROR_MESSAGES" \
    "$DURATION"
