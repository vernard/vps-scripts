#!/bin/bash
#
# Install cron jobs for vps-scripts
# Usage: ./install-crontab.sh [OPTIONS]
#
# Options:
#   --dry-run    Show what would be installed without making changes
#   --remove     Remove vps-scripts cron jobs
#   -y, --yes    Skip confirmation prompts (uses defaults)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Options
DRY_RUN=false
REMOVE=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --remove) REMOVE=true; shift ;;
        -y|--yes) SKIP_CONFIRM=true; shift ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

# Marker for identifying our cron jobs
MARKER="# vps-scripts"

# Selected jobs to install
declare -a SELECTED_JOBS=()

# Timezone for cron
CRON_TZ=""

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"

    if $SKIP_CONFIRM; then
        [[ "$default" == "y" ]]
        return
    fi

    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"

    read -r -p "$prompt $hint " response
    response="${response:-$default}"
    [[ "$response" =~ ^[Yy]$ ]]
}

ask_input() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"

    if $SKIP_CONFIRM; then
        eval "$var_name=\$default"
        return
    fi

    read -r -p "$prompt " response
    response="${response:-$default}"
    eval "$var_name=\$response"
}

configure_timezone() {
    echo -e "${BLUE}Timezone Configuration${NC}"
    echo ""

    # Get current system timezone
    local current_tz=""
    if command -v timedatectl &>/dev/null; then
        current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
    elif [[ -f /etc/timezone ]]; then
        current_tz=$(cat /etc/timezone)
    fi

    if [[ -n "$current_tz" ]]; then
        echo -e "Current system timezone: ${GREEN}$current_tz${NC}"
    else
        echo -e "${YELLOW}Could not detect system timezone.${NC}"
    fi

    echo ""
    echo "Cron jobs will run according to a timezone. Options:"
    echo "  1. Use system timezone ($current_tz)"
    echo "  2. Set a specific timezone for cron jobs (e.g., America/New_York)"
    echo ""

    if ask_yes_no "Use system timezone?" "y"; then
        echo -e "${GREEN}Using system timezone${NC}"
    else
        echo ""
        echo "Enter timezone (e.g., America/New_York, Europe/London, Asia/Tokyo):"
        echo "See: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones"
        ask_input "Timezone:" CRON_TZ "$current_tz"
        if [[ -n "$CRON_TZ" ]]; then
            echo -e "${GREEN}Cron jobs will use: $CRON_TZ${NC}"
        fi
    fi
    echo ""
}

configure_jobs() {
    echo -e "${BLUE}Configure cron jobs:${NC}"
    echo ""

    # 1. Cloudflare GitHub IPs
    echo -e "${CYAN}1. Update Cloudflare IP list with GitHub Actions IPs${NC}"
    echo "   Keeps your Cloudflare WAF rules updated with GitHub's IP ranges."
    echo "   Schedule: Every 6 hours"
    if ask_yes_no "   Enable?" "y"; then
        SELECTED_JOBS+=("0 */6 * * *|scripts/update-cf-github-ips.sh|Update Cloudflare IP list with GitHub Actions IPs")
        echo -e "   ${GREEN}Enabled${NC}"
    else
        echo -e "   ${YELLOW}Skipped${NC}"
    fi
    echo ""

    # 2. Database backups
    echo -e "${CYAN}2. Database backups (auto-discovery)${NC}"
    echo "   Automatically finds and backs up MySQL, PostgreSQL, and SQLite databases."
    echo "   Schedule: Daily at 2 AM"
    if ask_yes_no "   Enable?" "y"; then
        SELECTED_JOBS+=("0 2 * * *|scripts/backup-databases.sh|Backup databases (auto-discovery)")
        echo -e "   ${GREEN}Enabled${NC}"
    else
        echo -e "   ${YELLOW}Skipped${NC}"
    fi
    echo ""

    # 3. File storage backups
    echo -e "${CYAN}3. File storage backups${NC}"
    echo "   Backs up file volumes (uploads, media, etc.) for specific services."
    echo "   Requires service/application UUIDs."
    echo "   Schedule: Weekly on Sunday at 3 AM"
    if ask_yes_no "   Enable?" "n"; then
        echo ""
        echo "   Enter UUIDs to backup (space-separated):"
        echo "   Find UUIDs with: ls /data/coolify/services/ /data/coolify/applications/"
        local uuids=""
        ask_input "   UUIDs:" uuids ""
        if [[ -n "$uuids" ]]; then
            SELECTED_JOBS+=("0 3 * * 0|scripts/backup-databases.sh --files-only $uuids|File storage backups")
            echo -e "   ${GREEN}Enabled for: $uuids${NC}"
        else
            echo -e "   ${YELLOW}Skipped (no UUIDs provided)${NC}"
        fi
    else
        echo -e "   ${YELLOW}Skipped${NC}"
    fi
    echo ""

    # 4. Coolify setup backup
    echo -e "${CYAN}4. Full Coolify setup backup${NC}"
    echo "   Backs up Coolify database, configuration, and SSH keys."
    echo "   Schedule: Weekly on Sunday at 4 AM"
    if ask_yes_no "   Enable?" "y"; then
        SELECTED_JOBS+=("0 4 * * 0|scripts/backup-coolify-setup.sh|Full Coolify setup backup")
        echo -e "   ${GREEN}Enabled${NC}"
    else
        echo -e "   ${YELLOW}Skipped${NC}"
    fi
    echo ""
}

show_jobs() {
    if [[ ${#SELECTED_JOBS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No cron jobs selected.${NC}"
        return 1
    fi

    echo -e "${BLUE}Cron jobs to be installed:${NC}"
    echo ""
    if [[ -n "$CRON_TZ" ]]; then
        echo -e "  ${CYAN}CRON_TZ=$CRON_TZ${NC}"
        echo ""
    fi
    for job in "${SELECTED_JOBS[@]}"; do
        IFS='|' read -r schedule script desc <<< "$job"
        echo -e "  ${GREEN}$schedule${NC} $SCRIPT_DIR/$script"
        echo -e "    ${YELLOW}# $desc${NC}"
        echo ""
    done
}

generate_crontab_entries() {
    echo "$MARKER-start (DO NOT EDIT THIS LINE)"
    echo "# Installed from: $SCRIPT_DIR"
    echo "# Installed on: $(date)"
    if [[ -n "$CRON_TZ" ]]; then
        echo "CRON_TZ=$CRON_TZ"
    fi
    echo ""
    for job in "${SELECTED_JOBS[@]}"; do
        IFS='|' read -r schedule script desc <<< "$job"
        echo "# $desc"
        echo "$schedule $SCRIPT_DIR/$script"
        echo ""
    done
    echo "$MARKER-end (DO NOT EDIT THIS LINE)"
}

remove_existing() {
    crontab -l 2>/dev/null | sed "/$MARKER-start/,/$MARKER-end/d" || true
}

install_crontab() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY RUN] Would install:${NC}"
        echo ""
        generate_crontab_entries
        return
    fi

    # Get existing crontab without our entries
    local existing
    existing=$(remove_existing)

    # Combine existing + new
    {
        echo "$existing"
        echo ""
        generate_crontab_entries
    } | crontab -

    echo -e "${GREEN}Cron jobs installed successfully!${NC}"
    echo ""
    echo "Verify with: crontab -l"
}

remove_crontab() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY RUN] Would remove vps-scripts cron jobs${NC}"
        return
    fi

    local existing
    existing=$(remove_existing)

    if [[ -z "${existing// }" ]]; then
        crontab -r 2>/dev/null || true
    else
        echo "$existing" | crontab -
    fi

    echo -e "${GREEN}vps-scripts cron jobs removed.${NC}"
}

confirm() {
    if $SKIP_CONFIRM; then
        return 0
    fi
    read -r -p "Proceed with installation? [y/N] " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Main
echo ""
echo -e "${BLUE}vps-scripts Cron Installer${NC}"
echo -e "Installation directory: ${GREEN}$SCRIPT_DIR${NC}"
echo ""

# Check scripts exist and are executable
for script in scripts/update-cf-github-ips.sh scripts/backup-databases.sh scripts/backup-coolify-setup.sh; do
    if [[ ! -x "$SCRIPT_DIR/$script" ]]; then
        echo -e "${YELLOW}Making $script executable...${NC}"
        chmod +x "$SCRIPT_DIR/$script" 2>/dev/null || true
    fi
done

if $REMOVE; then
    echo -e "${YELLOW}This will remove all vps-scripts cron jobs.${NC}"
    if $SKIP_CONFIRM || ask_yes_no "Continue?" "n"; then
        remove_crontab
    else
        echo "Cancelled."
    fi
else
    # Check for existing installation
    if crontab -l 2>/dev/null | grep -q "$MARKER-start"; then
        echo -e "${YELLOW}Existing vps-scripts cron jobs found. They will be replaced.${NC}"
        echo ""
    fi

    configure_timezone
    configure_jobs

    if show_jobs; then
        echo ""
        if confirm; then
            install_crontab
        else
            echo "Cancelled."
        fi
    fi
fi
