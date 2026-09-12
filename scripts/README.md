# Scripts Directory Overview

This directory contains various scripts for automating tasks, maintenance, and operations related to the Bitrix infrastructure.

## Python Environment Setup

For Python scripts in this directory, it's recommended to use a virtual environment:

```bash
# Create virtual environment
python3 -m venv venv

# Activate virtual environment
source venv/bin/activate

# Install required packages
pip3 install -r requirements.txt
```

## Scripts and Files

Below is a list of scripts and relevant files found in this directory:

*   **`check-404.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Prints the 404 URLs that YandexBot and Googlebot hit in the nginx access log, counted, with `/bitrix/cache/` and `/upload/` paths excluded, for redirect troubleshooting.
    *   **Notes:** `check-404.sh [log-file]`; the log defaults to `logs/nginx/prod.access.log` or `CHECK_404_LOG`.

*   **`compare-backups.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Interactive tool to compare two backups from S3, showing differences between selected dates.

*   **`convert-utf8mb4.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Converts a database to utf8mb4 in place with one generated `ALTER TABLE` per table that still needs it, keeping column types and binary collations; verifies column definitions and per-table row digests before and after each run. Makes no backup of its own.
    *   **Notes:** `sudo ./scripts/convert-utf8mb4.sh [--dry-run] [--collation NAME] DATABASE`; see [Converting the database to utf8mb4](../Readme.md#routine-operations) for the Bitrix settings that go with it.

*   **`dedup-upload.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Replaces byte-identical files under `web/prod/upload` with hard links (`hardlink -t -X` from util-linux), excluding module scratch, exchange and log directories. Runs monthly from `config/cron/host.cron`.
    *   **Notes:** `./scripts/dedup-upload.sh [--dry-run] [directory]`; full `hardlink` output goes to `logs/dedup-upload.log`. Linked copies share later in-place writes, so review the exclusions for your modules; needs util-linux `hardlink` with `--respect-xattrs` and `flock`.

*   **`disaster-recovery.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Automates disaster recovery process by setting up a fresh Ubuntu server with Docker, restoring files from S3 backup, and recovering MySQL database.
    *   **Notes:** Critical script that orchestrates multiple recovery steps.

*   **`file-backup.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Performs incremental file backups to S3 using duplicity, under a `duplicity_web_<hostname>` prefix. Excludes cache, logs, and development directories. Full backup every 60 days. Runs without encryption and includes `private/environment/*.env`, so the bucket must stay private.

*   **`find-image-type-mismatch.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Detects images where file extension doesn't match actual MIME type.

*   **`ftp-entrypoint.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Entrypoint of the `ftp` service (`ftp-manual` profile): starts pure-ftpd with verbose logging into `logs/ftp/pureftpd.log` and, at each container start, appends the previous run's log to `session-history.log` before the image clears it.

*   **`fix-rights.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Sets proper file ownership for containers (UID/GID 1000 for PHP/Nginx, 1001 for MySQL). Must be run after file operations.
    *   **Notes:** Critical for ensuring the application runs correctly after deployment or file changes.

*   **`mysql-dump.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Creates a compressed MySQL dump (utf8mb4 client, `b_user_session` excluded) and uploads it to S3; a dump under 1 MB is treated as a failure and not synced.
    *   **Notes:** Reads `private/environment/mysql.env` and `private/environment/backup.env` (`BACKUP_S3_BUCKET`, `S3_ENDPOINT_URL`, `DOMAIN`); the database name is derived from `DOMAIN` (dots and dashes to underscores), not from `MYSQL_DATABASE`, and the dump lands under `mysql_<hostname>/` in the bucket.

*   **`optimise-images.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Optimizes PNG, JPEG, WebP, and GIF images using various tools. Uses SQLite database at `private/image-optimisation/optimised.db` to track processed files and avoid reprocessing.

*   **`pull-public.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Production pull of this repository for the `updater` webhook: validates user, repository, branch and origin, makes the root-owned `config/cron` and `config/logrotate` writable for the pull only, and restarts `php-cron` or nginx when a file-mounted config changed inode (nginx after a test in a fresh container).
    *   **Notes:** See [Automation (host cron)](../Readme.md#automation-host-cron) for the first-time rollout.

*   **`renew-dev.sh`:** Recreates dev from current production or a selected backup; see [Dev site renewal from backup](../Readme.md#routine-operations) for usage and safeguards.

*   **`requirements.txt`**
    *   **Type:** Data file (Python dependencies)
    *   **Purpose:** Lists Python package dependencies required by Python scripts in this directory (e.g., `urls.py`).
    *   **Notes:** Used with `pip install -r requirements.txt`.

*   **`setup.py`**
    *   **Type:** Python packaging script (`.py`)
    *   **Purpose:** Packages `urls.py` as the `bitrix-infra-scripts` module.

*   **`phpstan-scan.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Weekly PHPStan static-analysis scan of the prod Bitrix tree; writes the owned-code error count to `logs/phpstan/owned_errors_count.txt` for Zabbix to read via `system.run`. Self-updates the PHPStan PHAR on each run.
    *   **Notes:** See the PHPStan static analysis monitoring section in the main Readme for setup instructions, Zabbix template import, and the two scan scopes (owned vs diagnostic).

*   **`seo-reindex.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Drains `/web/private/seo-reindex/queue.txt` into the Yandex Webmaster recrawl API, up to the account-wide daily quota (~960 URLs/day). Runs daily at 00:15 MSK as the `admin` user.
    *   **Notes:** Requires `private/environment/seo-reindex.env` with a valid Yandex Webmaster OAuth token. Logs go to `logs/seo-reindex/YYYY-MM-DD.log`. Bing reindexing is handled separately via `bin/search-reindex submit --bing-only`.

*   **`update-dns-token.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Refreshes the Yandex Cloud IAM token (12-hour lifetime) that DNSroboCert uses for the DNS challenge; runs three times a day from `config/cron/host.cron`.
    *   **Notes:** Calls the `yc` CLI from the `admin` user's home and writes the token into `private/environment/dnsrobocert.env`.

*   **`urls.py`**
    *   **Type:** Python script (`.py`)
    *   **Purpose:** Python utility for checking URLs, finding redirects, broken links, and extracting page titles. Supports updating redirect maps.
    *   **Notes:** Dependencies in `requirements.txt`; `urls.txt` is its empty input placeholder.

## bin/ Directory Tools

### fgmysql — Read-only MySQL access

Read-only MySQL CLI via SSH socket tunnel, using the `claude_ro` user with SELECT-only privileges. Designed for safe database access from AI agents (e.g. Claude Code) and ad-hoc queries.

**Prerequisites:**
- `mycli` installed (`brew install mycli` on macOS)
- SSH access to the server configured

**Setup:**

1. Add SSH host alias to `~/.ssh/config`:
   ```
   Host bitrix
       HostName your-server.example.com
       User your-username
       IdentityFile ~/.ssh/your-key
   ```

2. Add `MYSQL_CLAUDE_RO_PASSWORD` to server's `/web/private/environment/mysql.env`

3. Create the MySQL user on the server:
   ```sql
   CREATE USER 'claude_ro'@'localhost' IDENTIFIED BY 'password_from_env';
   GRANT SELECT ON favor_group_ru.* TO 'claude_ro'@'localhost';
   GRANT SELECT ON dev_favor_group_ru.* TO 'claude_ro'@'localhost';
   FLUSH PRIVILEGES;
   ```

4. Add to your shell profile:
   ```shell
   export PATH="/path/to/bitrix.infra/bin:$PATH"
   export SSH_HOST="bitrix"  # optional, defaults to "bitrix"
   ```

**Usage:**
```shell
fgmysql                     # Interactive session (production)
fgmysql -e "SELECT ..."     # Run query and exit
fgmysql dev                 # Connect to dev database
fgmysql dev -e "SELECT ..." # Query dev database
```

The tunnel starts automatically and password is fetched from the server (cached for 1 hour).

**Manual tunnel management:**
```shell
./mysql-tunnel.sh start   # Start tunnel
./mysql-tunnel.sh status  # Check status
./mysql-tunnel.sh stop    # Stop tunnel
```

### search-reindex — Search engine URL reindexing

Submits URLs to Yandex and Bing for reindexing. Useful after content updates, fixing 404 errors, or adding new pages.

**Setup:**

1. Add `bin/` to your PATH:
   ```shell
   export PATH="/path/to/bitrix.infra/bin:$PATH"
   ```

2. Run interactive setup (guides you through Yandex OAuth app creation and optional Bing API key):
   ```shell
   search-reindex setup
   ```

The script auto-detects host IDs for favor-group.ru sites. Yandex uses OAuth (oauth.yandex.ru), Bing uses a simple API key from Bing Webmaster Tools. Config is stored in `bin/.search-reindex` (gitignored).

**Usage:**
```shell
search-reindex list                                   # List verified Yandex hosts
search-reindex quota                                  # Show remaining Yandex daily quota
search-reindex submit-url [--bing-only] <url>...      # Submit one or more URLs
search-reindex submit [--bing-only] <file>            # Submit URLs from file
search-reindex submit-regions [--bing-only] <file>    # Submit URLs for MSK, SPB, TULA
search-reindex diagnostics                            # Check Yandex site issues
```

`--bing-only` skips Yandex submission (e.g. when its daily quota is exhausted but Bing's separate quota still has headroom).

**Examples:**
```shell
# Submit specific URLs for reindexing (goes to both Yandex and Bing)
search-reindex submit-url https://favor-group.ru/catalog/profnastil/1484/

# Submit URLs from file for all regional subdomains
search-reindex submit-regions /tmp/urls.txt

# Read relative URLs from stdin
echo "/catalog/new-page/" | search-reindex submit-regions -

# Push to Bing only (e.g. Yandex quota already drained)
search-reindex submit --bing-only /tmp/urls.txt

# Check for site issues (exit 1 if FATAL/CRITICAL — Zabbix-friendly)
search-reindex diagnostics && echo 'All OK'
```

**Routine reindexing via the server-side cron:** for bulk Yandex submissions that exceed the ~960/day quota, append absolute URLs to `/web/private/seo-reindex/queue.txt` on the server. The `seo-reindex.sh` cron (00:15 MSK daily, runs as `admin`) drains the queue top-down up to remaining quota and removes attempted lines. Bing has a separate 10 000/day quota and is sent manually with `--bing-only` from a workstation.

### yandex-reviews — Yandex Maps organisation review sync

Moved to the private overlay repository (`bin/yandex-reviews` there): the organisation IDs and Bitrix iblock bindings are site-specific.

