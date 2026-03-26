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

*   **`alter-robots-txt.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Updates robots.txt files for regional subdomains, blocking specific sections based on region.
    *   **Notes:** May take arguments to specify the environment (e.g., dev/prod).

*   **`check-404.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Analyzes nginx logs to find 404 errors from search engine bots for redirect troubleshooting.
    *   **Notes:** Might use `urls.txt` or a similar file as input.

*   **`compare-backups.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Interactive tool to compare two backups from S3, showing differences between selected dates.

*   **`disaster-recovery.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Automates disaster recovery process by setting up a fresh Ubuntu server with Docker, restoring files from S3 backup, and recovering MySQL database.
    *   **Notes:** Critical script that orchestrates multiple recovery steps.

*   **`file-backup.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Performs incremental file backups to S3 using duplicity. Excludes cache, logs, and development directories. Full backup every 60 days.

*   **`find-image-type-mismatch.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Detects images where file extension doesn't match actual MIME type.

*   **`fix-rights.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Sets proper file ownership for containers (UID/GID 1000 for PHP/Nginx, 1001 for MySQL). Must be run after file operations.
    *   **Notes:** Critical for ensuring the application runs correctly after deployment or file changes.

*   **`mysql-dump.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Creates compressed MySQL dump and uploads to S3. Excludes user sessions table to reduce backup size.
    *   **Notes:** May require database credentials, possibly from environment variables or a configuration file.

*   **`optimise-images.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Optimizes PNG, JPEG, WebP, and GIF images using various tools. Uses SQLite database at `private/image-optimisation/optimised.db` to track processed files and avoid reprocessing.

*   **`renew-dev.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Recreates dev site from production or from an existing backup.
    *   **Options:**
        *   `--date` - Restore from an existing backup file instead of creating a new dump from production. When used, the script will:
            1. List available backup dates from `/web/backup/` (newest first, up to 20)
            2. Prompt for date selection (YYYY-MM-DD format)
            3. List available `.sql.gz` files for that date
            4. Prompt for file selection
            5. Restore from the selected backup
    *   **Use cases:**
        *   Restore dev from a specific point in time for debugging
        *   Compare current prod data with historical backup (useful with SEO tools)
        *   Test migrations against old data

*   **`requirements.txt`**
    *   **Type:** Data file (Python dependencies)
    *   **Purpose:** Lists Python package dependencies required by Python scripts in this directory (e.g., `urls.py`).
    *   **Notes:** Used with `pip install -r requirements.txt`.

*   **`setup.py`**
    *   **Type:** Python packaging script (`.py`)
    *   **Purpose:** Standard Python project setup script, likely used for packaging any Python utilities or scripts in this directory if they were to be distributed or installed as a package.

*   **`update-dns-token.sh`**
    *   **Type:** Shell script (`.sh`)
    *   **Purpose:** Updates Yandex Cloud DNS authentication token for automatic certificate renewal.
    *   **Notes:** Requires API credentials, probably sourced from environment variables or a secure configuration file.

*   **`urls.py`**
    *   **Type:** Python script (`.py`)
    *   **Purpose:** Python utility for checking URLs, finding redirects, broken links, and extracting page titles. Supports updating redirect maps.
    *   **Notes:** May use `requirements.txt` for its dependencies.

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
search-reindex list                      # List verified Yandex hosts
search-reindex submit-url <url>...       # Submit one or more URLs
search-reindex submit <file>             # Submit URLs from file
search-reindex submit-regions <file>     # Submit URLs for MSK, SPB, TULA
search-reindex diagnostics               # Check Yandex site issues
```

**Examples:**
```shell
# Submit specific URLs for reindexing (goes to both Yandex and Bing)
search-reindex submit-url https://favor-group.ru/catalog/profnastil/1484/

# Submit URLs from file for all regional subdomains
search-reindex submit-regions /tmp/urls.txt

# Read relative URLs from stdin
echo "/catalog/new-page/" | search-reindex submit-regions -

# Check for site issues (exit 1 if FATAL/CRITICAL — Zabbix-friendly)
search-reindex diagnostics && echo 'All OK'
```

