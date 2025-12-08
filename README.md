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

**Configure UUIDs by database type** (auto-detects service vs application):

```bash
# Find UUIDs: ls /data/coolify/services/ /data/coolify/applications/
BACKUP_MYSQL="uuid1,uuid2"
BACKUP_POSTGRES="uuid3,uuid4"
BACKUP_SQLITE="uuid5"
BACKUP_FILES="uuid6"         # File storage volumes (uploads, media, etc.)
```

**Usage:**

```bash
# Backup all configured databases
./scripts/backup-databases.sh

# Backup specific UUID(s) only
./scripts/backup-databases.sh uuid1 uuid2
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

**Remote sync:**

```bash
REMOTE_SYNC_METHOD=rsync              # rsync or rclone

# For rsync (SSH to NAS/server):
RSYNC_TARGET=user@host:/path

# For rclone (Google Drive, S3, etc.):
RCLONE_REMOTE=gdrive:backups/vps      # Requires: rclone config
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
└── coolify-setup/{timestamp}/
    ├── coolify-db.sql.zst
    ├── coolify-data.tar.zst
    └── manifest.txt
```
