# VPS Scripts

Bash scripts for VPS maintenance tasks with `.env` support and CRON compatibility.

## Setup

```bash
cp .env.example .env
# Edit .env with your values
```

## Scripts

| Script | Description |
|--------|-------------|
| `install-crontab.sh` | Interactive cron job installer with timezone configuration |
| `backup-databases.sh` | Unified backup for MySQL, PostgreSQL, and SQLite databases |
| `backup-coolify-setup.sh` | Full Coolify installation backup + vps-scripts .env |
| `restore.sh` | Interactive restore for databases and file volumes |
| `update-cf-github-ips.sh` | Updates Cloudflare IP list with GitHub Actions IPs |

## Configuration

### Logging

```bash
LOG_TO_SCREEN=true    # Output logs to terminal (default: true)
ENABLE_LOGGING=false  # Also write logs to logs/<script>.log
```

Errors always output to stderr regardless of these settings.

### Cloudflare

For `update-cf-github-ips.sh` - updates a Cloudflare IP list with GitHub Actions ranges.

```bash
CF_ACCOUNT_ID=       # Dashboard > Any domain > Overview > Account ID (right sidebar)
CF_API_TOKEN=        # My Profile > API Tokens > Create with "Account Filter Lists: Edit"
CF_LIST_ID=          # Create list first, find ID in URL when editing
```

### Database Backups

**General settings:**

```bash
BACKUP_DIR=/backups                # Local backup directory
BACKUP_RETENTION_DAYS=7            # Auto-delete database backups older than this
BACKUP_FILES_RETENTION_DAYS=30     # Auto-delete file backups older than this (default: 30)
```

**Auto-discovery mode** (recommended):

Leave all `BACKUP_*` variables empty. The script will:
1. Find all running Coolify services and applications
2. Try database backup methods (MySQL, PostgreSQL, SQLite)
3. Skip methods that don't apply to each service

Note: File storage is excluded from auto-discovery (too large for daily backups). Use `--files-only` for weekly/monthly file backups.

**Manual configuration** (optional):

```bash
# Find UUIDs: ls /data/coolify/services/ /data/coolify/applications/
BACKUP_MYSQL="uuid1,uuid2"
BACKUP_POSTGRES="uuid3,uuid4"
BACKUP_SQLITE="uuid5"
BACKUP_FILES="uuid6"         # File storage volumes (uploads, media, etc.)
```

Setting any database `BACKUP_*` variable disables auto-discovery.

**Usage:**

```bash
# Auto-discover and backup databases
./scripts/backup-databases.sh

# Backup specific UUID(s) - databases only
./scripts/backup-databases.sh uuid1 uuid2

# Backup file storage only (for weekly/monthly cron)
./scripts/backup-databases.sh --files-only uuid1 uuid2
```

**Database detection:**
- MySQL/MariaDB: Uses `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE` from `.env` (also supports `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE`)
- PostgreSQL: Uses `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` from `.env`
- SQLite: Auto-detected by volume names containing `db-data` or `dbdata`

**File storage detection:**
Auto-detected by volume name patterns in `docker-compose.yml`:
- Included: `laravel-storage`, `storage-data`, `storage`, `uploads`, `files`, `media`, `assets`, `attachments`
- Excluded: `cache`, `tmp`, `logs`, `db-data`, `pg-data`, `mysql-data`, `redis-data`

**Multiple databases:** The script automatically finds all env vars ending with `_DATABASE` or `_DB`. You can also add `BACKUP_DATABASES=db1,db2,db3` to your Coolify app's environment variables.

### Restoring Backups

**Interactive mode:**

```bash
./scripts/restore.sh
```

Browse and select backups to restore via numbered menus.

**Options:**

| Flag | Description |
|------|-------------|
| `--fetch-remote` | Sync from remote storage before restore |
| `--dry-run` | Preview what would be restored |
| `--coolify-setup` | Restore full Coolify installation |
| `--latest` | Restore the most recent backup (skip timestamp selection) |
| `--target UUID` | Restore to a different service (for migrations) |
| `-y, --yes` | Skip confirmation prompts |
| `uuid` | Directly restore specific UUID |

**Examples:**

```bash
# Interactive mode - browse and select
./scripts/restore.sh

# Fetch from remote first, then interactive
./scripts/restore.sh --fetch-remote

# Preview without making changes
./scripts/restore.sh --dry-run

# Restore specific UUID
./scripts/restore.sh abc123xyz

# Restore latest backup for UUID (no prompts with -y)
./scripts/restore.sh --latest -y abc123xyz

# Restore Coolify installation
./scripts/restore.sh --coolify-setup

# Migration: restore OLD_UUID's backup to NEW_UUID's service
./scripts/restore.sh --target NEW_UUID OLD_UUID

# Migration with latest backup, no prompts
./scripts/restore.sh --target NEW_UUID --latest -y OLD_UUID
```

**Safety features:**
- **Pre-restore backup**: Current state saved to `/backups/pre-restore/` before restore
- **Confirmation prompts**: Requires explicit confirmation before destructive operations
- **Dry-run mode**: Test restore process without making changes
- **Validation**: Verifies backup integrity (zstd) before restore
- **Auto-restart**: Containers automatically restart after successful restore

**Remote sync:**

```bash
REMOTE_SYNC_METHOD=rsync              # rsync or rclone

# For rsync (SSH to NAS/server):
RSYNC_TARGET=user@host:/path

# For rclone (Google Drive, S3, etc.):
RCLONE_REMOTE=gdrive:backups/vps      # Requires: rclone config
```

### Setting up rclone with Google Drive

1. Install rclone:
   ```bash
   curl https://rclone.org/install.sh | sudo bash
   ```

2. Create OAuth credentials in [Google Cloud Console](https://console.cloud.google.com/):
   - Create project > Enable Google Drive API
   - APIs & Services > Credentials > Create OAuth client ID (Desktop app)

3. Configure rclone:
   ```bash
   rclone config
   # n) New remote
   # name> gdrive
   # Storage> drive
   # client_id> (your client ID)
   # client_secret> (your client secret)
   # scope> 4 (drive.file - only access files created by rclone)
   # service_account_file> (leave blank - not needed)
   # Edit advanced config> n
   # Use auto config> n (for headless server)
   # Copy the URL, open in local browser, authorize, paste code back
   ```

4. Test connection:
   ```bash
   rclone lsd gdrive:
   ```

5. Update `.env`:
   ```bash
   REMOTE_SYNC_METHOD=rclone
   RCLONE_REMOTE=gdrive:backups/vps
   ```

## Notifications & Monitoring

Backup scripts automatically send notifications based on your `.env` configuration.

### Discord Notifications

Get a summary embed after each backup run:

```bash
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
```

**Setup:**
1. Server Settings → Integrations → Webhooks → New Webhook
2. Copy the webhook URL
3. Add to `.env`

### Email Notifications

Requires `msmtp` to be installed:

```bash
# Debian/Ubuntu
apt install msmtp
# Note: May suggest apparmor - it's optional, not required

# Alpine
apk add msmtp
```

Receive detailed reports on failures (or optionally on every run):

```bash
SMTP_HOST=smtp.gmail.com          # Your SMTP server
SMTP_PORT=587                     # TLS port (default: 587)
SMTP_USER=your@email.com          # Your email
SMTP_PASS=xxxx-xxxx-xxxx-xxxx     # App password (not your regular password!)
EMAIL_TO=alerts@example.com       # Where to send notifications
NOTIFY_EMAIL_ALWAYS=false         # Set to true to receive on success too
```

**Gmail Setup:**
1. Enable 2FA on your Google account
2. Go to Security → App passwords → Generate new app password
3. Use the generated password for `SMTP_PASS`

**Behavior:**
- By default, emails are only sent on failures or partial failures
- Set `NOTIFY_EMAIL_ALWAYS=true` to receive emails on every run

### Healthcheck Monitoring (Dead Man's Switch)

Use external monitoring to detect when cron jobs stop running:

```bash
HEALTHCHECK_URL=https://hc-ping.com/your-uuid-here
```

**How it works:**
1. Script pings `/start` when backup begins
2. Script pings success or `/fail` when complete
3. If no ping received within expected window, the service alerts you

**Recommended services:**
- [healthchecks.io](https://healthchecks.io) - Free tier with 20 checks
- [Uptime Kuma](https://github.com/louislam/uptime-kuma) - Self-hosted
- [Cronitor](https://cronitor.io) - More features, paid

**healthchecks.io setup:**
1. Create account at healthchecks.io
2. Add new check with your cron schedule (e.g., `0 2 * * *`)
3. Copy the ping URL and add to `.env`

## CRON

**Recommended:** Use the interactive installer:

```bash
./install-crontab.sh
```

The installer will:
- Detect your installation directory automatically
- Configure timezone settings
- Let you choose which jobs to enable
- Ask for file storage UUIDs if needed

**Options:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Show what would be installed without making changes |
| `--remove` | Remove all vps-scripts cron jobs |
| `-y, --yes` | Skip prompts (uses defaults) |

**Manual installation:** See `crontab.example` for sample entries (update paths first).

## Backup Output

```
/backups/
├── apps/{uuid}/{timestamp}/
│   ├── {database}.sql.zst     # MySQL/PostgreSQL dumps
│   ├── sqlite-data.tar.zst    # SQLite data directory
│   ├── {volume-name}.tar.zst  # File storage volumes (storage, uploads, etc.)
│   └── env.backup
├── services/{uuid}/{timestamp}/
│   ├── {database}.sql.zst
│   ├── sqlite-data.tar.zst
│   ├── {volume-name}.tar.zst
│   └── env.backup
├── coolify-setup/{timestamp}/
│   ├── coolify-db.sql.zst
│   ├── coolify-data.tar.zst
│   └── manifest.txt
├── vps-scripts/{timestamp}/          # Backed up with coolify-setup
│   └── .env
└── pre-restore/{uuid}/{timestamp}/   # Safety backups before restore
    └── ...
```
