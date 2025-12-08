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
| `update-cf-github-ips.sh` | Updates Cloudflare IP list with GitHub Actions IPs |
| `backup-app-postgres.sh` | Backup PostgreSQL databases from Coolify applications |
| `backup-app-mysql.sh` | Backup MySQL databases from Coolify applications |
| `backup-service-postgres.sh` | Backup PostgreSQL databases from Coolify services |
| `backup-service-mysql.sh` | Backup MySQL databases from Coolify services |
| `backup-coolify-setup.sh` | Full Coolify installation backup for VPS migration |

## Configuration

### Logging

```bash
ENABLE_LOGGING=false  # Set to true to write logs to logs/<script>.log
```

Errors always output to stderr regardless of this setting.

### Cloudflare

For `update-cf-github-ips.sh` - updates a Cloudflare IP list with GitHub Actions ranges.

```bash
CF_ACCOUNT_ID=       # Dashboard > Any domain > Overview > Account ID (right sidebar)
CF_API_TOKEN=        # My Profile > API Tokens > Create with "Account Filter Lists: Edit"
CF_LIST_ID=          # Create list first, find ID in URL when editing
```

### Backups

**General settings:**

```bash
BACKUP_DIR=/backups           # Local backup directory
BACKUP_RETENTION_DAYS=7       # Auto-delete backups older than this
```

**Coolify applications** (your deployed apps):

```bash
# Find UUIDs: ls /data/coolify/applications/
BACKUP_APP_POSTGRES="uuid1,uuid2"
BACKUP_APP_MYSQL="uuid3"
```

**Coolify services** (standalone databases, redis, etc.):

```bash
# Find UUIDs: ls /data/coolify/services/
BACKUP_SERVICE_POSTGRES="uuid4"
BACKUP_SERVICE_MYSQL=""
```

**Multiple databases:** Add `BACKUP_DATABASES=db1,db2,db3` to your Coolify app's environment variables.

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
│   ├── database.sql.gz
│   └── app.env
├── services/{uuid}/{timestamp}/
│   ├── database.sql.gz
│   └── service.env
└── coolify-setup/{timestamp}/
    ├── coolify-db.sql.gz
    ├── coolify-data.tar.gz
    └── manifest.txt
```
