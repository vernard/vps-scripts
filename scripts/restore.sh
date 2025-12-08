#!/bin/bash
# Restore backups for Coolify services and applications
# Supports MySQL, PostgreSQL, SQLite databases and file volumes
#
# Usage:
#   ./restore.sh                          # Interactive mode - browse and select
#   ./restore.sh --fetch-remote           # Sync from remote before restore
#   ./restore.sh --dry-run                # Preview without making changes
#   ./restore.sh --coolify-setup          # Restore Coolify installation
#   ./restore.sh -y                       # Skip confirmation prompts
#   ./restore.sh uuid1                    # Directly restore specific UUID
#   ./restore.sh --latest uuid1           # Restore latest backup for UUID

set -e

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

BACKUP_BASE="${BACKUP_DIR:-/backups}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Parse command-line flags
DRY_RUN=false
FETCH_REMOTE=false
COOLIFY_SETUP=false
SKIP_CONFIRMATION=false
RESTORE_LATEST=false
TARGET_UUID=""

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [UUID]

Restore backups for Coolify services and applications.

Options:
  --fetch-remote    Sync backups from remote storage before restore
  --dry-run         Preview what would be restored without making changes
  --coolify-setup   Restore full Coolify installation
  --latest          Restore the most recent backup (skip timestamp selection)
  -y, --yes         Skip confirmation prompts
  -h, --help        Show this help message

Arguments:
  UUID              Directly restore a specific service/application UUID

Examples:
  $(basename "$0")                    # Interactive mode
  $(basename "$0") --fetch-remote     # Fetch from remote, then interactive
  $(basename "$0") --dry-run          # Preview mode
  $(basename "$0") abc123xyz          # Restore specific UUID
  $(basename "$0") --latest abc123xyz # Restore latest backup for UUID
  $(basename "$0") --coolify-setup    # Restore Coolify installation
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --fetch-remote)
            FETCH_REMOTE=true
            shift
            ;;
        --coolify-setup)
            COOLIFY_SETUP=true
            shift
            ;;
        --yes|-y)
            SKIP_CONFIRMATION=true
            shift
            ;;
        --latest)
            RESTORE_LATEST=true
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            TARGET_UUID="$1"
            shift
            ;;
    esac
done

# ============================================================================
# Helper Functions
# ============================================================================

# Restart docker compose for a UUID
restart_compose() {
    local uuid="$1"

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would restart containers for $uuid"
        return 0
    fi

    if ! find_uuid_location "$uuid"; then
        log_error "UUID not found: $uuid"
        return 1
    fi

    local dir="$UUID_BASE_DIR/$uuid"
    local compose_file=$(find_compose_file "$dir")

    if [[ -z "$compose_file" ]]; then
        log_error "No compose file found for $uuid"
        return 1
    fi

    log "Restarting containers for $uuid..."
    docker compose -f "$compose_file" restart || {
        log_error "Failed to restart containers"
        return 1
    }

    log "Containers restarted successfully"
    return 0
}

# Format timestamp from YYYYMMDD_HHMMSS to readable format
format_timestamp() {
    local ts="$1"
    # 20241209_143000 -> 2024-12-09 14:30:00
    echo "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}"
}

# Describe backup contents
describe_backup_contents() {
    local path="$1"
    local contents=()

    # Check for SQL dumps
    local sql_count=$(ls "$path"/*.sql.zst 2>/dev/null | wc -l)
    if [[ $sql_count -gt 0 ]]; then
        contents+=("${sql_count} SQL")
    fi

    # Check for SQLite
    if [[ -f "$path/sqlite-data.tar.zst" ]]; then
        contents+=("SQLite")
    fi

    # Check for file volumes (tar.zst excluding sqlite-data)
    local file_count=$(ls "$path"/*.tar.zst 2>/dev/null | grep -v sqlite-data | wc -l)
    if [[ $file_count -gt 0 ]]; then
        contents+=("${file_count} Files")
    fi

    if [[ ${#contents[@]} -eq 0 ]]; then
        echo "empty"
    else
        echo "${contents[*]}"
    fi
}

# Validate backup integrity before restore
validate_backup() {
    local backup_path="$1"
    local errors=()

    if [[ ! -d "$backup_path" ]]; then
        log_error "Backup path does not exist: $backup_path"
        return 1
    fi

    # Check for at least one backup file
    local has_backup=false

    for file in "$backup_path"/*.sql.zst "$backup_path"/*.tar.zst; do
        if [[ -f "$file" ]]; then
            has_backup=true
            # Verify zstd integrity
            if ! zstd -t "$file" 2>/dev/null; then
                errors+=("Corrupt file: $(basename "$file")")
            fi
        fi
    done

    if [[ "$has_backup" != true ]]; then
        log_error "No backup files found in: $backup_path"
        return 1
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        for err in "${errors[@]}"; do
            log_error "$err"
        done
        return 1
    fi

    return 0
}

# Prompt for confirmation before destructive operations
confirm_restore() {
    local target="$1"
    local backup_info="$2"

    if [[ "$SKIP_CONFIRMATION" == true ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    echo ""
    echo "=== Restore Confirmation ==="
    echo "Target: $target"
    echo "Backup: $backup_info"
    echo ""
    echo "WARNING: This will overwrite existing data!"
    echo ""
    read -p "Continue? [y/N]: " response

    case "$response" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            log "Restore cancelled by user"
            return 1
            ;;
    esac
}

# Find UUID location (service or app) - same as backup script
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

# ============================================================================
# Pre-Restore Backup
# ============================================================================

# Create safety backup before restore
pre_restore_backup() {
    local uuid="$1"
    local restore_type="$2"  # "mysql", "postgres", "sqlite", "files"

    if [[ "${RESTORE_PRE_BACKUP:-true}" != true ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would create pre-restore backup"
        return 0
    fi

    local PRE_BACKUP_PATH="$BACKUP_BASE/pre-restore/$uuid/$TIMESTAMP"

    log "Creating pre-restore backup..."
    mkdir -p "$PRE_BACKUP_PATH"

    if ! find_uuid_location "$uuid"; then
        log_error "UUID not found: $uuid"
        return 1
    fi

    local dir="$UUID_BASE_DIR/$uuid"
    local env_file="$dir/.env"
    local compose_file=$(find_compose_file "$dir")

    case "$restore_type" in
        mysql)
            pre_backup_mysql "$uuid" "$env_file" "$compose_file" "$PRE_BACKUP_PATH"
            ;;
        postgres)
            pre_backup_postgres "$uuid" "$env_file" "$compose_file" "$PRE_BACKUP_PATH"
            ;;
        sqlite)
            pre_backup_sqlite "$uuid" "$compose_file" "$PRE_BACKUP_PATH"
            ;;
        files)
            pre_backup_files "$uuid" "$compose_file" "$PRE_BACKUP_PATH"
            ;;
    esac

    if [[ -f "$env_file" ]]; then
        cp "$env_file" "$PRE_BACKUP_PATH/env.backup"
    fi

    log "Pre-restore backup saved to: $PRE_BACKUP_PATH"
    return 0
}

# Pre-backup MySQL (simplified version for safety backup)
pre_backup_mysql() {
    local uuid="$1" env_file="$2" compose_file="$3" backup_path="$4"

    local MYSQL_USER=$(read_coolify_env_multi "$env_file" "MYSQL_USER" "SERVICE_USER_MYSQL")
    local MYSQL_PASSWORD=$(read_coolify_env_multi "$env_file" "MYSQL_PASSWORD" "SERVICE_PASSWORD_MYSQL" "SERVICE_PASSWORD_64_MYSQL")
    local MYSQL_DB=$(read_coolify_env_multi "$env_file" "MYSQL_DATABASE" "MYSQL_DB")
    local MYSQL_ROOT_PASSWORD=$(read_coolify_env_multi "$env_file" "MYSQL_ROOT_PASSWORD" "SERVICE_PASSWORD_MYSQL_ROOT")

    if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
        MYSQL_USER="root"
        MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD"
    fi

    local CONTAINER=$(find_running_container "$compose_file" "db" "mysql" "mariadb" 2>/dev/null) || return 1

    if [[ -n "$MYSQL_DB" ]]; then
        docker exec "$CONTAINER" mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DB" 2>/dev/null | zstd > "$backup_path/${MYSQL_DB}.sql.zst" || true
    fi
}

# Pre-backup PostgreSQL
pre_backup_postgres() {
    local uuid="$1" env_file="$2" compose_file="$3" backup_path="$4"

    local PG_USER=$(read_coolify_env_multi "$env_file" "POSTGRES_USER" "SERVICE_USER_POSTGRES")
    local PG_DB=$(read_coolify_env_multi "$env_file" "POSTGRES_DB" "POSTGRES_DATABASE")

    local CONTAINER=$(find_running_container "$compose_file" "db" "postgres" "postgresql" 2>/dev/null) || return 1

    if [[ -n "$PG_DB" ]]; then
        docker exec "$CONTAINER" pg_dump -U "$PG_USER" "$PG_DB" 2>/dev/null | zstd > "$backup_path/${PG_DB}.sql.zst" || true
    fi
}

# Pre-backup SQLite
pre_backup_sqlite() {
    local uuid="$1" compose_file="$2" backup_path="$3"

    local SQLITE_INFO=$(find_sqlite_service "$compose_file" 2>/dev/null) || return 1
    local SERVICE_NAME="${SQLITE_INFO%%:*}"
    local MOUNT_PATH="${SQLITE_INFO#*:}"
    local CONTAINER=$(get_container_name "$compose_file" "$SERVICE_NAME")

    if check_container "$CONTAINER"; then
        docker cp "$CONTAINER:$MOUNT_PATH" "$backup_path/sqlite-data" 2>/dev/null || true
        if [[ -d "$backup_path/sqlite-data" ]]; then
            tar --zstd -cf "$backup_path/sqlite-data.tar.zst" -C "$backup_path" sqlite-data && rm -rf "$backup_path/sqlite-data"
        fi
    fi
}

# Pre-backup files
pre_backup_files() {
    local uuid="$1" compose_file="$2" backup_path="$3"

    local STORAGE_VOLUMES=$(find_storage_volumes "$compose_file" 2>/dev/null) || return 1

    while IFS=: read -r service_name vol_name mount_path; do
        [[ -z "$service_name" ]] && continue
        local CONTAINER=$(get_container_name "$compose_file" "$service_name")
        if check_container "$CONTAINER"; then
            local temp_dir="$backup_path/${vol_name}-temp"
            docker cp "$CONTAINER:$mount_path" "$temp_dir" 2>/dev/null || continue
            tar --zstd -cf "$backup_path/${vol_name}.tar.zst" -C "$backup_path" "${vol_name}-temp" && rm -rf "$temp_dir"
        fi
    done <<< "$STORAGE_VOLUMES"
}

# ============================================================================
# Restore Functions
# ============================================================================

# Restore MySQL database
restore_mysql() {
    local uuid="$1"
    local backup_path="$2"
    local db_file="$3"

    local db_name="${db_file%.sql.zst}"

    log "Restoring MySQL database: $db_name"

    if ! find_uuid_location "$uuid"; then
        log_error "UUID not found: $uuid"
        return 1
    fi

    local dir="$UUID_BASE_DIR/$uuid"
    local env_file="$dir/.env"
    local compose_file=$(find_compose_file "$dir")

    local MYSQL_USER=$(read_coolify_env_multi "$env_file" "MYSQL_USER" "SERVICE_USER_MYSQL")
    local MYSQL_PASSWORD=$(read_coolify_env_multi "$env_file" "MYSQL_PASSWORD" "SERVICE_PASSWORD_MYSQL" "SERVICE_PASSWORD_64_MYSQL")
    local MYSQL_ROOT_PASSWORD=$(read_coolify_env_multi "$env_file" "MYSQL_ROOT_PASSWORD" "SERVICE_PASSWORD_MYSQL_ROOT")

    # Prefer root for restores
    if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
        MYSQL_USER="root"
        MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD"
    fi

    local CONTAINER=$(find_running_container "$compose_file" "db" "mysql" "mariadb")
    if [[ $? -ne 0 ]]; then
        log_error "No running MySQL container found for $uuid"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would restore $db_name to container $CONTAINER"
        return 0
    fi

    # Create pre-restore backup
    pre_restore_backup "$uuid" "mysql"

    log "  Restoring to container: $CONTAINER"
    zstd -dc "$backup_path/$db_file" | docker exec -i "$CONTAINER" mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$db_name" || {
        log_error "Failed to restore database $db_name"
        return 1
    }

    log "  MySQL database $db_name restored successfully"
    return 0
}

# Restore PostgreSQL database
restore_postgres() {
    local uuid="$1"
    local backup_path="$2"
    local db_file="$3"

    local db_name="${db_file%.sql.zst}"

    log "Restoring PostgreSQL database: $db_name"

    if ! find_uuid_location "$uuid"; then
        log_error "UUID not found: $uuid"
        return 1
    fi

    local dir="$UUID_BASE_DIR/$uuid"
    local env_file="$dir/.env"
    local compose_file=$(find_compose_file "$dir")

    local PG_USER=$(read_coolify_env_multi "$env_file" "POSTGRES_USER" "SERVICE_USER_POSTGRES")

    local CONTAINER=$(find_running_container "$compose_file" "db" "postgres" "postgresql")
    if [[ $? -ne 0 ]]; then
        log_error "No running PostgreSQL container found for $uuid"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would restore $db_name to container $CONTAINER"
        log "[DRY-RUN] Would drop and recreate database first"
        return 0
    fi

    # Create pre-restore backup
    pre_restore_backup "$uuid" "postgres"

    # Drop and recreate database before restore
    log "  Dropping existing database $db_name..."
    docker exec "$CONTAINER" psql -U "$PG_USER" -c "DROP DATABASE IF EXISTS \"$db_name\";" postgres 2>/dev/null || true
    docker exec "$CONTAINER" psql -U "$PG_USER" -c "CREATE DATABASE \"$db_name\";" postgres || {
        log_error "Failed to create database $db_name"
        return 1
    }

    log "  Restoring to container: $CONTAINER"
    zstd -dc "$backup_path/$db_file" | docker exec -i "$CONTAINER" psql -U "$PG_USER" "$db_name" || {
        log_error "Failed to restore database $db_name"
        return 1
    }

    log "  PostgreSQL database $db_name restored successfully"
    return 0
}

# Restore SQLite database
restore_sqlite() {
    local uuid="$1"
    local backup_path="$2"

    log "Restoring SQLite database"

    if ! find_uuid_location "$uuid"; then
        log_error "UUID not found: $uuid"
        return 1
    fi

    local dir="$UUID_BASE_DIR/$uuid"
    local compose_file=$(find_compose_file "$dir")

    local SQLITE_INFO=$(find_sqlite_service "$compose_file")
    if [[ -z "$SQLITE_INFO" ]]; then
        log_error "No SQLite data volume found for $uuid"
        return 1
    fi

    local SERVICE_NAME="${SQLITE_INFO%%:*}"
    local MOUNT_PATH="${SQLITE_INFO#*:}"

    local CONTAINER=$(get_container_name "$compose_file" "$SERVICE_NAME")
    if ! check_container "$CONTAINER"; then
        log_error "Container $CONTAINER is not running"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would restore SQLite to $CONTAINER:$MOUNT_PATH"
        return 0
    fi

    # Create pre-restore backup
    pre_restore_backup "$uuid" "sqlite"

    # Extract to temp directory
    local temp_dir=$(mktemp -d)
    tar --zstd -xf "$backup_path/sqlite-data.tar.zst" -C "$temp_dir"

    # Copy back to container
    log "  Restoring to $CONTAINER:$MOUNT_PATH"
    docker cp "$temp_dir/sqlite-data/." "$CONTAINER:$MOUNT_PATH" || {
        rm -rf "$temp_dir"
        log_error "Failed to restore SQLite data"
        return 1
    }

    rm -rf "$temp_dir"
    log "  SQLite database restored successfully"
    return 0
}

# Restore file volumes
restore_files() {
    local uuid="$1"
    local backup_path="$2"
    local volume_file="$3"

    local vol_name="${volume_file%.tar.zst}"

    log "Restoring file volume: $vol_name"

    if ! find_uuid_location "$uuid"; then
        log_error "UUID not found: $uuid"
        return 1
    fi

    local dir="$UUID_BASE_DIR/$uuid"
    local compose_file=$(find_compose_file "$dir")

    # Find the storage volume with matching name
    local STORAGE_INFO=$(find_storage_volumes "$compose_file" | grep ":${vol_name}:")
    if [[ -z "$STORAGE_INFO" ]]; then
        log_error "Volume $vol_name not found in compose file"
        return 1
    fi

    local SERVICE_NAME="${STORAGE_INFO%%:*}"
    local rest="${STORAGE_INFO#*:}"
    local MOUNT_PATH="${rest#*:}"

    local CONTAINER=$(get_container_name "$compose_file" "$SERVICE_NAME")
    if ! check_container "$CONTAINER"; then
        log_error "Container $CONTAINER is not running"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would restore $vol_name to $CONTAINER:$MOUNT_PATH"
        return 0
    fi

    # Create pre-restore backup
    pre_restore_backup "$uuid" "files"

    # Extract and restore
    local temp_dir=$(mktemp -d)
    tar --zstd -xf "$backup_path/$volume_file" -C "$temp_dir"

    log "  Restoring to $CONTAINER:$MOUNT_PATH"
    docker cp "$temp_dir/${vol_name}-temp/." "$CONTAINER:$MOUNT_PATH" || {
        rm -rf "$temp_dir"
        log_error "Failed to restore files"
        return 1
    }

    rm -rf "$temp_dir"
    log "  File volume $vol_name restored successfully"
    return 0
}

# Restore Coolify setup
restore_coolify_setup() {
    local backup_path="$1"

    log "Restoring Coolify setup from: $backup_path"

    if [[ ! -f "$backup_path/manifest.txt" ]]; then
        log_error "Invalid Coolify backup - manifest.txt not found"
        return 1
    fi

    # Show manifest
    echo ""
    echo "=== Backup Manifest ==="
    cat "$backup_path/manifest.txt"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] Would restore Coolify setup:"
        log "[DRY-RUN] - Stop Coolify containers"
        log "[DRY-RUN] - Restore database from coolify-db.sql.zst"
        log "[DRY-RUN] - Restore data from coolify-data.tar.zst"
        log "[DRY-RUN] - Restore SSH keys if present"
        log "[DRY-RUN] - Start Coolify containers"
        return 0
    fi

    # Confirm destructive operation
    if ! confirm_restore "Coolify Installation" "$backup_path"; then
        return 1
    fi

    local COOLIFY_COMPOSE="/data/coolify/source/docker-compose.yml"

    # Stop Coolify
    log "Stopping Coolify..."
    docker compose -f "$COOLIFY_COMPOSE" down || true

    # Restore database
    if [[ -f "$backup_path/coolify-db.sql.zst" ]]; then
        log "Restoring Coolify database..."
        # Start only the database container
        docker compose -f "$COOLIFY_COMPOSE" up -d coolify-db
        sleep 5  # Wait for DB to be ready

        local COOLIFY_DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E '^coolify-db' | head -1)
        zstd -dc "$backup_path/coolify-db.sql.zst" | docker exec -i "$COOLIFY_DB_CONTAINER" psql -U coolify || {
            log_error "Failed to restore Coolify database"
        }
    fi

    # Restore data directory
    if [[ -f "$backup_path/coolify-data.tar.zst" ]]; then
        log "Restoring Coolify data directory..."
        tar --zstd -xf "$backup_path/coolify-data.tar.zst" -C /data
    fi

    # Restore SSH keys
    if [[ -d "$backup_path/ssh" ]]; then
        log "Restoring SSH keys..."
        cp -r "$backup_path/ssh" /data/coolify/
        chmod 700 /data/coolify/ssh
        chmod 600 /data/coolify/ssh/* 2>/dev/null || true
    fi

    # Restart Coolify
    log "Starting Coolify..."
    docker compose -f "$COOLIFY_COMPOSE" up -d

    log "Coolify setup restored successfully"
    return 0
}

# ============================================================================
# Interactive Menu Functions
# ============================================================================

# Display main menu
show_main_menu() {
    echo ""
    echo "=== VPS Backup Restore ==="
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN MODE - No changes will be made]"
    fi
    echo ""
    echo "Select backup category:"
    echo "  1) Services ($BACKUP_BASE/services/)"
    echo "  2) Applications ($BACKUP_BASE/apps/)"
    echo "  3) Coolify Setup ($BACKUP_BASE/coolify-setup/)"
    echo "  q) Quit"
    echo ""
}

# List available UUIDs in a category
list_uuids() {
    local category="$1"
    local backup_path="$BACKUP_BASE/$category"

    if [[ ! -d "$backup_path" ]]; then
        log_error "No backups found in $backup_path"
        return 1
    fi

    local uuids=($(ls -1 "$backup_path" 2>/dev/null))

    if [[ ${#uuids[@]} -eq 0 ]]; then
        log_error "No backup UUIDs found"
        return 1
    fi

    echo ""
    echo "Available UUIDs in $category:"
    local i=1
    for uuid in "${uuids[@]}"; do
        local latest=$(ls -1t "$backup_path/$uuid" 2>/dev/null | head -1)
        local formatted=""
        if [[ -n "$latest" ]]; then
            formatted=$(format_timestamp "$latest")
        fi
        echo "  $i) $uuid (latest: ${formatted:-none})"
        ((i++))
    done
    echo "  b) Back"
    echo ""

    read -p "Select UUID [1-${#uuids[@]}]: " selection

    if [[ "$selection" == "b" ]]; then
        return 1
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#uuids[@]} ]]; then
        SELECTED_UUID="${uuids[$((selection-1))]}"
        return 0
    fi

    log_error "Invalid selection"
    return 1
}

# List available timestamps for a UUID
list_timestamps() {
    local category="$1"
    local uuid="$2"
    local backup_path="$BACKUP_BASE/$category/$uuid"

    local timestamps=($(ls -1t "$backup_path" 2>/dev/null))

    if [[ ${#timestamps[@]} -eq 0 ]]; then
        log_error "No backups found for UUID: $uuid"
        return 1
    fi

    echo ""
    echo "Available backups for $uuid:"
    local i=1
    for ts in "${timestamps[@]}"; do
        local formatted_date=$(format_timestamp "$ts")
        local contents=$(describe_backup_contents "$backup_path/$ts")
        echo "  $i) $formatted_date - $contents"
        ((i++))
    done
    echo "  b) Back"
    echo ""

    read -p "Select backup [1-${#timestamps[@]}]: " selection

    if [[ "$selection" == "b" ]]; then
        return 1
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#timestamps[@]} ]]; then
        SELECTED_TIMESTAMP="${timestamps[$((selection-1))]}"
        return 0
    fi

    log_error "Invalid selection"
    return 1
}

# List Coolify setup backups
list_coolify_backups() {
    local backup_path="$BACKUP_BASE/coolify-setup"

    if [[ ! -d "$backup_path" ]]; then
        log_error "No Coolify setup backups found"
        return 1
    fi

    local timestamps=($(ls -1t "$backup_path" 2>/dev/null))

    if [[ ${#timestamps[@]} -eq 0 ]]; then
        log_error "No Coolify setup backups found"
        return 1
    fi

    echo ""
    echo "Available Coolify setup backups:"
    local i=1
    for ts in "${timestamps[@]}"; do
        local formatted_date=$(format_timestamp "$ts")
        echo "  $i) $formatted_date"
        ((i++))
    done
    echo "  b) Back"
    echo ""

    read -p "Select backup [1-${#timestamps[@]}]: " selection

    if [[ "$selection" == "b" ]]; then
        return 1
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#timestamps[@]} ]]; then
        SELECTED_TIMESTAMP="${timestamps[$((selection-1))]}"
        return 0
    fi

    log_error "Invalid selection"
    return 1
}

# Select what to restore from a backup
select_restore_items() {
    local backup_path="$1"
    local uuid="$2"

    # Find available items
    local items=()
    local item_types=()

    # SQL dumps
    for file in "$backup_path"/*.sql.zst; do
        if [[ -f "$file" ]]; then
            local filename=$(basename "$file")
            items+=("$filename")
            # Determine if MySQL or PostgreSQL based on UUID location
            if find_uuid_location "$uuid"; then
                local dir="$UUID_BASE_DIR/$uuid"
                local compose_file=$(find_compose_file "$dir")
                local pg_container=$(find_running_container "$compose_file" "db" "postgres" "postgresql" 2>/dev/null) || true
                if [[ -n "$pg_container" ]]; then
                    item_types+=("postgres")
                else
                    item_types+=("mysql")
                fi
            else
                item_types+=("sql")
            fi
        fi
    done

    # SQLite
    if [[ -f "$backup_path/sqlite-data.tar.zst" ]]; then
        items+=("sqlite-data.tar.zst")
        item_types+=("sqlite")
    fi

    # File volumes
    for file in "$backup_path"/*.tar.zst; do
        if [[ -f "$file" ]]; then
            local filename=$(basename "$file")
            if [[ "$filename" != "sqlite-data.tar.zst" ]]; then
                items+=("$filename")
                item_types+=("files")
            fi
        fi
    done

    if [[ ${#items[@]} -eq 0 ]]; then
        log_error "No restorable items found in backup"
        return 1
    fi

    echo ""
    echo "Available items to restore:"
    local i=1
    for item in "${items[@]}"; do
        echo "  $i) $item (${item_types[$((i-1))]})"
        ((i++))
    done
    echo "  a) All items"
    echo "  b) Back"
    echo ""

    read -p "Select item [1-${#items[@]}, a, b]: " selection

    if [[ "$selection" == "b" ]]; then
        return 1
    fi

    if [[ "$selection" == "a" ]]; then
        # Restore all items
        local formatted_ts=$(format_timestamp "$SELECTED_TIMESTAMP")
        if ! confirm_restore "$uuid" "$formatted_ts (all items)"; then
            return 1
        fi

        for idx in "${!items[@]}"; do
            local item="${items[$idx]}"
            local type="${item_types[$idx]}"
            case "$type" in
                mysql)
                    restore_mysql "$uuid" "$backup_path" "$item"
                    ;;
                postgres)
                    restore_postgres "$uuid" "$backup_path" "$item"
                    ;;
                sqlite)
                    restore_sqlite "$uuid" "$backup_path"
                    ;;
                files)
                    restore_files "$uuid" "$backup_path" "$item"
                    ;;
            esac
        done

        # Restart containers after restore
        restart_compose "$uuid"
        return 0
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#items[@]} ]]; then
        local item="${items[$((selection-1))]}"
        local type="${item_types[$((selection-1))]}"

        local formatted_ts=$(format_timestamp "$SELECTED_TIMESTAMP")
        if ! confirm_restore "$uuid" "$formatted_ts ($item)"; then
            return 1
        fi

        case "$type" in
            mysql)
                restore_mysql "$uuid" "$backup_path" "$item"
                ;;
            postgres)
                restore_postgres "$uuid" "$backup_path" "$item"
                ;;
            sqlite)
                restore_sqlite "$uuid" "$backup_path"
                ;;
            files)
                restore_files "$uuid" "$backup_path" "$item"
                ;;
        esac

        # Restart containers after restore
        restart_compose "$uuid"
        return 0
    fi

    log_error "Invalid selection"
    return 1
}

# Interactive restore flow
interactive_restore() {
    local category="$1"

    if ! list_uuids "$category"; then
        return
    fi

    if ! list_timestamps "$category" "$SELECTED_UUID"; then
        return
    fi

    local backup_path="$BACKUP_BASE/$category/$SELECTED_UUID/$SELECTED_TIMESTAMP"

    # Validate backup
    log "Validating backup..."
    if ! validate_backup "$backup_path"; then
        return 1
    fi
    log "Backup validation passed"

    # Select and restore items
    select_restore_items "$backup_path" "$SELECTED_UUID"
}

# Interactive Coolify restore
interactive_coolify_restore() {
    if ! list_coolify_backups; then
        return
    fi

    restore_coolify_setup "$BACKUP_BASE/coolify-setup/$SELECTED_TIMESTAMP"
}

# Direct UUID restore
direct_uuid_restore() {
    local uuid="$1"

    # Find backup category
    local category=""
    if [[ -d "$BACKUP_BASE/services/$uuid" ]]; then
        category="services"
    elif [[ -d "$BACKUP_BASE/apps/$uuid" ]]; then
        category="apps"
    else
        log_error "No backups found for UUID: $uuid"
        exit 1
    fi

    # If --latest flag, auto-select most recent timestamp
    if [[ "$RESTORE_LATEST" == true ]]; then
        SELECTED_TIMESTAMP=$(ls -1t "$BACKUP_BASE/$category/$uuid" 2>/dev/null | head -1)
        if [[ -z "$SELECTED_TIMESTAMP" ]]; then
            log_error "No backups found for UUID: $uuid"
            exit 1
        fi
        local formatted=$(format_timestamp "$SELECTED_TIMESTAMP")
        log "Using latest backup: $formatted"
    else
        if ! list_timestamps "$category" "$uuid"; then
            exit 1
        fi
    fi

    local backup_path="$BACKUP_BASE/$category/$uuid/$SELECTED_TIMESTAMP"

    log "Validating backup..."
    if ! validate_backup "$backup_path"; then
        exit 1
    fi
    log "Backup validation passed"

    select_restore_items "$backup_path" "$uuid"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    # Handle remote fetch first
    if [[ "$FETCH_REMOTE" == true ]]; then
        log "Fetching backups from remote storage..."
        sync_from_remote "$BACKUP_BASE" || {
            log_error "Failed to fetch from remote"
            exit 1
        }
    fi

    # Handle Coolify setup restore
    if [[ "$COOLIFY_SETUP" == true ]]; then
        interactive_coolify_restore
        exit 0
    fi

    # Handle direct UUID restore
    if [[ -n "$TARGET_UUID" ]]; then
        direct_uuid_restore "$TARGET_UUID"
        exit 0
    fi

    # Interactive mode
    while true; do
        show_main_menu
        read -p "Enter choice: " choice

        case "$choice" in
            1)
                interactive_restore "services"
                ;;
            2)
                interactive_restore "apps"
                ;;
            3)
                interactive_coolify_restore
                ;;
            q|Q)
                log "Exiting"
                exit 0
                ;;
            *)
                log_error "Invalid choice"
                ;;
        esac
    done
}

main "$@"
