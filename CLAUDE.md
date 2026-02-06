# Bitrix.infra - Infrastructure Guidelines

## Build/Service Commands
- Start services: `docker-compose up --build -d`
- Stop services: `docker-compose down`
- Rebuild containers: `docker-compose build --no-cache`
- Fix permissions: `sudo ./scripts/fix-rights.sh`
- Clear cache: `echo "flush_all" | docker exec -i memcached /usr/bin/nc 127.0.0.1 11211`
- Clear sessions: `echo "flush_all" | docker exec -i memcached-sessions /usr/bin/nc 127.0.0.1 11211`

## Code Style Guidelines
- Bash: Follow POSIX compatibility where possible
- PHP: PSR-12 standard with 4-space indentation
- YAML: 2-space indentation
- HTML/CSS: 2-space indentation
- Docker: Follow best practices for multi-stage builds and minimal images
- Error handling: Log all errors with appropriate context
- Backup scripts: Always test restore process after implementation
- Config files: Use comments to document non-obvious settings

## File Structure Conventions
- Config files in `/config` directory
- Scripts in `/scripts` directory
- Logs in `/logs` directory
- Web files in `/web/prod` and `/web/dev`
- Environment files in `/private/environment`

## Server
- Production server: `bitrix` (SSH alias)
- Repository location on server: `/web`
- Host timezone: UTC, php-cron container timezone: Europe/Moscow (UTC+3)
- File timestamps on server are in UTC

## Cron File Deployment
- `/web/config/cron` directory is owned by root; to deploy cron changes:
  `sudo chown admin:admin /web/config/cron && git pull && sudo chown root:root /web/config/cron && sudo chown root:root /web/config/cron/*.cron && sudo chmod 0644 /web/config/cron/*.cron`

## Export Profiles (acrit.export)
- Run single export: `docker exec -u www-data php-cron bash -c "/usr/bin/php -f /web/prod/bitrix/modules/acrit.export/cli/export.php profile=ID auto=Y site=s1 >> /web/prod/upload/acrit.export/log/log_ID.e63f31938c399df95752fe5013735c65.txt 2>&1"`
- Must run as `www-data`, not root (root is rejected by the script)
- `auto=Y` may skip export if data unchanged; killing a running export can leave a lock in the DB (visible as "Profile N is locked" in log), unlock via Bitrix admin
- Logs: `/web/prod/upload/acrit.export/log/`
- XML output: `/web/prod/upload/acrit.export/`