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