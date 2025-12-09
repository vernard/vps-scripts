#!/bin/bash
# Common utilities for VPS scripts

COOLIFY_SERVICES_DIR="/data/coolify/services"
COOLIFY_APPS_DIR="/data/coolify/applications"

# Detect project root (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load environment variables from .env
load_env() {
    local env_file="$PROJECT_ROOT/.env"
    if [[ -f "$env_file" ]]; then
        set -a
        source "$env_file"
        set +a
    else
        log_error ".env file not found at $env_file"
        exit 1
    fi
}

# Logging function (controlled by ENABLE_LOGGING and LOG_TO_SCREEN)
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $*"

    # Output to screen if enabled
    if [[ "${LOG_TO_SCREEN:-true}" == "true" ]]; then
        echo "$message"
    fi

    # Write to log file if enabled
    if [[ "${ENABLE_LOGGING:-false}" == "true" ]]; then
        local script_name="$(basename "${BASH_SOURCE[1]}" .sh)"
        local log_dir="$PROJECT_ROOT/logs"
        local log_file="$log_dir/${script_name}.log"

        mkdir -p "$log_dir"
        echo "$message" >> "$log_file"
    fi
}

# Error logging (always outputs, regardless of ENABLE_LOGGING)
log_error() {
    local script_name="$(basename "${BASH_SOURCE[1]}" .sh)"
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"

    # Always output to stderr
    echo "$message" >&2

    # Also log to file if logging is enabled
    if [[ "${ENABLE_LOGGING:-false}" == "true" ]]; then
        local log_dir="$PROJECT_ROOT/logs"
        local log_file="$log_dir/${script_name}.log"
        mkdir -p "$log_dir"
        echo "$message" >> "$log_file"
    fi
}

# Sync to remote storage
sync_to_remote() {
    local source_path="$1"

    case "${REMOTE_SYNC_METHOD:-}" in
        rsync)
            if [[ -n "${RSYNC_TARGET:-}" ]]; then
                log "Syncing to $RSYNC_TARGET"
                rsync -avz --delete "$source_path" "$RSYNC_TARGET"
            fi
            ;;
        rclone)
            if [[ -n "${RCLONE_REMOTE:-}" ]]; then
                log "Syncing to $RCLONE_REMOTE"
                rclone sync "$source_path" "$RCLONE_REMOTE"
            fi
            ;;
        *)
            log "No remote sync method configured"
            ;;
    esac
}

# Sync from remote storage (reverse of sync_to_remote)
sync_from_remote() {
    local target_path="$1"

    case "${REMOTE_SYNC_METHOD:-}" in
        rsync)
            if [[ -n "${RSYNC_TARGET:-}" ]]; then
                log "Fetching from $RSYNC_TARGET"
                rsync -avz "$RSYNC_TARGET" "$target_path"
            else
                log_error "RSYNC_TARGET not configured"
                return 1
            fi
            ;;
        rclone)
            if [[ -n "${RCLONE_REMOTE:-}" ]]; then
                log "Fetching from $RCLONE_REMOTE"
                rclone sync "$RCLONE_REMOTE" "$target_path"
            else
                log_error "RCLONE_REMOTE not configured"
                return 1
            fi
            ;;
        *)
            log_error "No remote sync method configured (set REMOTE_SYNC_METHOD)"
            return 1
            ;;
    esac

    log "Remote fetch completed"
    return 0
}

# Clean old backups based on retention policy
# Args: backup_path [retention_days] [skip_files]
# skip_files: if "true", skip directories containing file backups (*.tar.zst except sqlite-data.tar.zst)
cleanup_old_backups() {
    local backup_path="$1"
    local retention_days="${2:-${BACKUP_RETENTION_DAYS:-7}}"
    local skip_files="${3:-false}"

    if [[ -d "$backup_path" ]]; then
        log "Cleaning backups older than $retention_days days in $backup_path"

        # Find timestamp directories (depth 2: backup_path/uuid/timestamp)
        find "$backup_path" -mindepth 2 -maxdepth 2 -type d -mtime "+$retention_days" 2>/dev/null | while read -r dir; do
            # If skip_files=true, skip directories containing file backups
            if [[ "$skip_files" == "true" ]]; then
                # Check for .tar.zst files that aren't sqlite-data.tar.zst
                if find "$dir" -maxdepth 1 -name "*.tar.zst" ! -name "sqlite-data.tar.zst" -quit 2>/dev/null | grep -q .; then
                    continue
                fi
            fi
            rm -rf "$dir"
        done
    fi
}

# Read env var from a Coolify app's .env file (resolves variable references)
read_coolify_env() {
    local env_file="$1"
    local var_name="$2"

    if [[ -f "$env_file" ]]; then
        # Source the env file in a subshell to resolve variable references
        (
            set -a
            source "$env_file" 2>/dev/null
            set +a
            echo "${!var_name}"
        )
    fi
}

# Try multiple variable names, return first non-empty value
# Usage: read_coolify_env_multi "$env_file" "VAR1" "VAR2" "VAR3"
read_coolify_env_multi() {
    local env_file="$1"
    shift
    local var_names=("$@")

    for var in "${var_names[@]}"; do
        local value=$(read_coolify_env "$env_file" "$var")
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    done
}

# Find all env vars ending with _DATABASE or _DB and return their resolved values (comma-separated)
# Excludes: SERVICE_NAME_*, SERVICE_FQDN_*, PMA_* (not actual database names)
find_database_env_vars() {
    local env_file="$1"

    if [[ -f "$env_file" ]]; then
        (
            set -a
            source "$env_file" 2>/dev/null
            set +a
            # Get all vars ending with _DATABASE or _DB, excluding SERVICE_NAME_*, PMA_*, etc.
            for var in $(grep -E "(_DATABASE|_DB)=" "$env_file" | grep -v -E "^(SERVICE_NAME_|SERVICE_FQDN_|PMA_)" | cut -d'=' -f1); do
                echo "${!var}"
            done | sort -u | paste -sd ',' -
        )
    fi
}

# Find docker-compose file (supports .yml and .yaml)
find_compose_file() {
    local dir="$1"

    if [[ -f "$dir/docker-compose.yml" ]]; then
        echo "$dir/docker-compose.yml"
    elif [[ -f "$dir/docker-compose.yaml" ]]; then
        echo "$dir/docker-compose.yaml"
    fi
}

# Get container name from docker-compose file
get_container_name() {
    local compose_file="$1"
    local service_name="$2"

    if [[ -f "$compose_file" ]]; then
        local project_dir=$(dirname "$compose_file")
        local project_name=$(basename "$project_dir")

        # Method 1: Try to find running container via docker (Coolify pattern: service-uuid-*)
        # This is the most reliable method for Coolify deployments
        local container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^${service_name}-${project_name}-" | head -1)
        if [[ -n "$container" ]]; then
            echo "$container"
            return
        fi

        # Method 2: Try alternate Coolify pattern (uuid in container name)
        container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^${service_name}.*${project_name}" | head -1)
        if [[ -n "$container" ]]; then
            echo "$container"
            return
        fi

        # Method 3: Extract container_name from compose file using awk (fallback)
        # Note: This can fail on complex compose files with nested service references
        local name=$(awk -v svc="$service_name" '
            /^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*$/ { in_service = ($1 == svc":") }
            in_service && /container_name:/ { gsub(/.*container_name:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit }
        ' "$compose_file")

        if [[ -n "$name" ]]; then
            echo "$name"
            return
        fi

        # Fallback: compose project name + service (standard docker-compose naming)
        echo "${project_name}-${service_name}-1"
    fi
}

# Check if a container exists and is running
# Returns 0 if running, 1 if exists but not running, 2 if doesn't exist
check_container() {
    local container_name="$1"

    if docker inspect "$container_name" &>/dev/null; then
        local status=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)
        if [[ "$status" == "true" ]]; then
            return 0  # Running
        else
            return 1  # Exists but not running
        fi
    else
        return 2  # Doesn't exist
    fi
}

# Get human-readable container status message
get_container_status_message() {
    local container_name="$1"

    check_container "$container_name"
    local status=$?

    case $status in
        0) echo "running" ;;
        1) echo "exists but not running" ;;
        2) echo "not found" ;;
    esac
}

# Find a running container from a list of service names
# Usage: find_running_container "$COMPOSE_FILE" "mysql" "mariadb" "db"
# Returns the first container that exists and is running
find_running_container() {
    local compose_file="$1"
    shift
    local service_names=("$@")
    local tried_containers=()

    for service in "${service_names[@]}"; do
        local container=$(get_container_name "$compose_file" "$service")
        if [[ -n "$container" ]]; then
            tried_containers+=("$container")
            if check_container "$container"; then
                echo "$container"
                return 0
            fi
        fi
    done

    # Return list of tried containers for error reporting (comma-separated)
    if [[ ${#tried_containers[@]} -gt 0 ]]; then
        printf '%s\n' "${tried_containers[*]}" | tr ' ' ','
    fi
    return 1
}

# Find service with SQLite data volume and its mount path
# Returns: "service_name:mount_path" or empty if not found
# Looks for volumes containing 'db-data' or 'dbdata'
find_sqlite_service() {
    local compose_file="$1"

    if [[ -f "$compose_file" ]]; then
        awk '
            /^services:[[:space:]]*$/ { in_services = 1; next }
            /^[a-zA-Z]/ && !/^[[:space:]]/ { in_services = 0 }
            in_services && /^[[:space:]]+[a-zA-Z0-9_-]+:[[:space:]]*$/ {
                svc = $1; gsub(/:/, "", svc)
                # Skip common property keys - only match actual service names
                if (svc !~ /^(volumes|image|environment|depends_on|labels|networks|command|build|ports|expose|healthcheck|restart|container_name|env_file|working_dir|user|entrypoint|stdin_open|tty|privileged|devices|dns|logging|configs|secrets|deploy)$/) {
                    current_service = svc
                }
            }
            /volumes:/ && current_service { in_volumes = 1; next }
            in_volumes && /^[[:space:]]*-/ {
                # Match db-data/dbdata but exclude mysql/postgres/redis paths
                if (/db-data|dbdata/) {
                    mount_path = $0
                    gsub(/.*:/, "", mount_path)
                    gsub(/["\047[:space:]]/, "", mount_path)
                    # Skip if mount path is for mysql/postgres/redis
                    if (mount_path ~ /mysql|postgres|redis/) next
                    print current_service ":" mount_path
                    exit
                }
            }
            in_volumes && /^[[:space:]]*[a-zA-Z]/ && !/^[[:space:]]*-/ { in_volumes = 0 }
        ' "$compose_file"
    fi
}

# Find file storage volumes and their mount paths
# Returns lines of "service_name:volume_name:mount_path" for each matching volume
# Includes: storage-data, storage, uploads, files, media, assets, attachments
# Excludes: cache, tmp, temp, logs, database-data, db-data, pg-data, redis-data, mysql-data
find_storage_volumes() {
    local compose_file="$1"

    if [[ -f "$compose_file" ]]; then
        awk '
            /^services:[[:space:]]*$/ { in_services = 1; next }
            /^[a-zA-Z]/ && !/^[[:space:]]/ { in_services = 0 }
            in_services && /^[[:space:]]+[a-zA-Z0-9_-]+:[[:space:]]*$/ {
                svc = $1; gsub(/:/, "", svc)
                # Skip common property keys - only match actual service names
                if (svc !~ /^(volumes|image|environment|depends_on|labels|networks|command|build|ports|expose|healthcheck|restart|container_name|env_file|working_dir|user|entrypoint|stdin_open|tty|privileged|devices|dns|logging|configs|secrets|deploy)$/) {
                    current_service = svc
                }
            }
            /volumes:/ && current_service { in_volumes = 1; next }
            in_volumes && /^[[:space:]]*-/ {
                # Skip excluded patterns (cache, db, etc)
                if (/cache|tmp|temp|logs|database-data|db-data|dbdata|pg-data|postgres-data|mysql-data|redis-data/) {
                    next
                }
                # Match included patterns (storage, uploads, files, etc)
                if (/laravel-storage|storage-data|storage|uploads|upload|files|file|media|assets|attachments/) {
                    line = $0
                    # Extract volume name (before the colon)
                    vol_name = line
                    gsub(/^[[:space:]]*-[[:space:]]*["\047]?/, "", vol_name)
                    gsub(/:.*/, "", vol_name)
                    # Extract just the suffix (after last underscore) for the backup filename
                    vol_suffix = vol_name
                    gsub(/.*_/, "", vol_suffix)
                    # Extract mount path (after the colon)
                    mount_path = line
                    gsub(/.*:/, "", mount_path)
                    gsub(/["\047[:space:]]/, "", mount_path)
                    print current_service ":" vol_suffix ":" mount_path
                }
            }
            in_volumes && /^[[:space:]]*[a-zA-Z]/ && !/^[[:space:]]*-/ { in_volumes = 0 }
        ' "$compose_file"
    fi
}

# Check if compose file has any running containers
has_running_containers() {
    local compose_file="$1"
    local project_name=$(basename "$(dirname "$compose_file")")
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$project_name"
}

# Find all UUIDs with running containers
discover_running_uuids() {
    local uuids=()

    # Check services
    for dir in "$COOLIFY_SERVICES_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local uuid=$(basename "$dir")
        local compose=$(find_compose_file "$dir")
        [[ -z "$compose" ]] && continue

        if has_running_containers "$compose"; then
            uuids+=("$uuid")
        fi
    done

    # Check applications
    for dir in "$COOLIFY_APPS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local uuid=$(basename "$dir")
        local compose=$(find_compose_file "$dir")
        [[ -z "$compose" ]] && continue

        if has_running_containers "$compose"; then
            uuids+=("$uuid")
        fi
    done

    printf '%s\n' "${uuids[@]}"
}

# =============================================================================
# NOTIFICATION FUNCTIONS
# =============================================================================

# Send Discord webhook notification
# Args: title, description, color (decimal), [fields_json]
# Color: 3066993 (green), 15158332 (red), 15844367 (yellow)
send_discord() {
    local webhook_url="${DISCORD_WEBHOOK_URL:-}"
    [[ -z "$webhook_url" ]] && return 0

    local title="$1"
    local description="$2"
    local color="${3:-3066993}"
    local fields_json="${4:-[]}"
    local hostname="${HOSTNAME:-$(hostname)}"

    local payload=$(cat <<EOF
{
  "embeds": [{
    "title": "$title",
    "description": "$description",
    "color": $color,
    "fields": $fields_json,
    "footer": {"text": "$hostname"},
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
)

    curl -s -H "Content-Type: application/json" -d "$payload" "$webhook_url" >/dev/null 2>&1
}

# Send email notification
# Args: subject, body
send_email() {
    local smtp_host="${SMTP_HOST:-}"
    [[ -z "$smtp_host" ]] && return 0

    local subject="$1"
    local body="$2"
    local to="${EMAIL_TO:-}"
    local from="${EMAIL_FROM:-vps-scripts@$(hostname)}"
    local smtp_port="${SMTP_PORT:-587}"
    local smtp_user="${SMTP_USER:-}"
    local smtp_pass="${SMTP_PASS:-}"
    local hostname="${HOSTNAME:-$(hostname)}"

    [[ -z "$to" ]] && return 0

    # Add hostname to subject
    subject="[$hostname] $subject"

    # Build email with headers
    local email_content="Subject: $subject
From: $from
To: $to
Content-Type: text/plain; charset=utf-8

$body

--
Sent from $hostname at $(date '+%Y-%m-%d %H:%M:%S %Z')
"

    # Try different mail methods
    if command -v msmtp &>/dev/null && [[ -n "$smtp_user" ]]; then
        # Use msmtp with inline config
        echo "$email_content" | msmtp \
            --host="$smtp_host" \
            --port="$smtp_port" \
            --auth=on \
            --user="$smtp_user" \
            --password="$smtp_pass" \
            --tls=on \
            --from="$from" \
            "$to" 2>/dev/null
    elif command -v curl &>/dev/null && [[ -n "$smtp_user" ]]; then
        # Use curl for SMTP
        curl -s --url "smtps://${smtp_host}:${smtp_port}" \
            --ssl-reqd \
            --mail-from "$from" \
            --mail-rcpt "$to" \
            --user "${smtp_user}:${smtp_pass}" \
            -T - <<< "$email_content" 2>/dev/null
    elif command -v mail &>/dev/null; then
        # Fall back to system mail
        echo "$body" | mail -s "$subject" "$to" 2>/dev/null
    elif command -v sendmail &>/dev/null; then
        # Fall back to sendmail
        echo "$email_content" | sendmail -t 2>/dev/null
    fi
}

# Ping healthcheck URL (for dead man's switch monitoring)
# Args: [status] - "start", "success", "fail", or empty for simple ping
ping_healthcheck() {
    local url="${HEALTHCHECK_URL:-}"
    [[ -z "$url" ]] && return 0

    local status="${1:-}"

    case "$status" in
        start) url="${url}/start" ;;
        fail)  url="${url}/fail" ;;
        success) ;; # Default ping URL
        *) ;; # Simple ping
    esac

    curl -fsS --retry 3 --max-time 10 "$url" >/dev/null 2>&1
}

# Build JSON fields array for Discord embed
# Args: pairs of "name" "value" (inline=true by default)
build_discord_fields() {
    local fields="["
    local first=true

    while [[ $# -ge 2 ]]; do
        local name="$1"
        local value="$2"
        shift 2

        [[ "$first" != "true" ]] && fields+=","
        first=false

        # Escape quotes and newlines in value
        value=$(echo "$value" | sed 's/"/\\"/g' | tr '\n' ' ')

        fields+="{\"name\":\"$name\",\"value\":\"$value\",\"inline\":true}"
    done

    fields+="]"
    echo "$fields"
}

# Notify backup completion (sends to both Discord and Email based on config)
# Args: script_name, success_count, fail_count, backed_up_list, error_messages, duration_seconds
notify_backup_complete() {
    local script_name="$1"
    local success_count="${2:-0}"
    local fail_count="${3:-0}"
    local backed_up_list="${4:-}"
    local error_messages="${5:-}"
    local duration="${6:-0}"

    local total=$((success_count + fail_count))
    local status="success"
    local color=3066993  # Green
    local emoji="✅"

    if [[ $fail_count -gt 0 && $success_count -eq 0 ]]; then
        status="failure"
        color=15158332  # Red
        emoji="❌"
    elif [[ $fail_count -gt 0 ]]; then
        status="partial"
        color=15844367  # Yellow
        emoji="⚠️"
    fi

    # Format duration
    local duration_str
    if [[ $duration -ge 60 ]]; then
        duration_str="$((duration / 60))m $((duration % 60))s"
    else
        duration_str="${duration}s"
    fi

    # === DISCORD (Summary) ===
    if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
        local title="$emoji Backup ${status^}: $script_name"
        local description="Completed at $(date '+%Y-%m-%d %H:%M:%S %Z')"

        local fields=$(build_discord_fields \
            "✓ Success" "$success_count" \
            "✗ Failed" "$fail_count" \
            "Duration" "$duration_str"
        )

        send_discord "$title" "$description" "$color" "$fields"
    fi

    # === EMAIL (Detailed on failure, or if NOTIFY_EMAIL_ALWAYS=true) ===
    if [[ -n "${SMTP_HOST:-}" && -n "${EMAIL_TO:-}" ]]; then
        local should_email=false

        if [[ "$status" != "success" ]]; then
            should_email=true
        elif [[ "${NOTIFY_EMAIL_ALWAYS:-false}" == "true" ]]; then
            should_email=true
        fi

        if [[ "$should_email" == "true" ]]; then
            local subject="Backup ${status^}: $script_name ($success_count/$total succeeded)"

            local body="BACKUP REPORT: $script_name
============================================

Status: ${status^^}
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')
Duration: $duration_str

SUMMARY
-------
Successful: $success_count
Failed: $fail_count
Total: $total
"

            if [[ -n "$backed_up_list" ]]; then
                body+="
BACKED UP
---------
$backed_up_list
"
            fi

            if [[ -n "$error_messages" ]]; then
                body+="
ERRORS
------
$error_messages
"
            fi

            send_email "$subject" "$body"
        fi
    fi

    # === HEALTHCHECK PING ===
    if [[ "$status" == "success" ]]; then
        ping_healthcheck "success"
    else
        ping_healthcheck "fail"
    fi
}
