#!/bin/bash
# Update Cloudflare IP list with GitHub Actions IPs

set -e

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
load_env

# Validate required env vars
if [[ -z "${CF_ACCOUNT_ID:-}" ]] || [[ -z "${CF_API_TOKEN:-}" ]] || [[ -z "${CF_LIST_ID:-}" ]]; then
    log_error "Missing required env vars: CF_ACCOUNT_ID, CF_API_TOKEN, CF_LIST_ID"
    exit 1
fi

log "Fetching GitHub Actions IPs"

# Fetch and format GitHub Actions IPs
github_ips=$(curl -sf https://api.github.com/meta | jq '.actions | map({ip: .})')

if [[ -z "$github_ips" ]] || [[ "$github_ips" == "null" ]]; then
    log_error "Failed to fetch GitHub IPs"
    exit 1
fi

log "Updating Cloudflare IP list"

# Replace IP list contents
response=$(curl -sf -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/rules/lists/$CF_LIST_ID/items" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$github_ips")

if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
    log "Successfully updated Cloudflare IP list"
else
    log_error "Failed to update Cloudflare IP list: $response"
    exit 1
fi
