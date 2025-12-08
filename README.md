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
| `backup-databases.sh` | Unified backup for MySQL, PostgreSQL, and SQLite databases |
| `backup-coolify-setup.sh` | Full Coolify installation backup for VPS migration |
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
BACKUP_DIR=/backups           # Local backup directory
BACKUP_RETENTION_DAYS=7       # Auto-delete backups older than this
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
- MySQL/MariaDB: Uses `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE` from `.env`
- PostgreSQL: Uses `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` from `.env`
- SQLite: Auto-detected by volume names containing `db-data` or `dbdata`

**File storage detection:**
Auto-detected by volume name patterns in `docker-compose.yml`:
- Included: `storage-data`, `storage`, `uploads`, `files`, `media`, `assets`, `attachments`
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

# Restore Coolify installation
./scripts/restore.sh --coolify-setup
```

**Safety features:**
- **Pre-restore backup**: Current state saved to `/backups/pre-restore/` before restore
- **Confirmation prompts**: Requires explicit confirmation before destructive operations
- **Dry-run mode**: Test restore process without making changes
- **Validation**: Verifies backup integrity (zstd) before restore

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

## CRON

See `crontab.example` for sample schedules. Install with:

```bash
crontab -e
# Paste entries from crontab.example
```

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
└── pre-restore/{uuid}/{timestamp}/   # Safety backups before restore
    └── ...
```
