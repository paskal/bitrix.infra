# AGENTS.md — Quick reference for AI agents

This repository is a generic Docker Compose stack for running a Bitrix CMS site.
Production identity (TLS, site vhosts, site-specific cron) attaches via a
private `docker-compose.override.yml` (see "Production overlay" in Readme.md).

## Local demo quickstart (6 commands)

```bash
git clone https://github.com/paskal/bitrix.infra.git && cd bitrix.infra
for f in private/environment/*.env.example; do cp "$f" "${f%.example}"; done
sudo ./scripts/fix-rights.sh
docker compose up -d
curl -L https://www.1c-bitrix.ru/download/start_encode.tar.gz | tar -xz -C web/prod/
open http://localhost   # or xdg-open on Linux
```

In the Bitrix wizard: DB host = `localhost`, DB name / user / password from `private/environment/mysql.env`.

## Residual gotchas

| Gotcha | Fix |
|--------|-----|
| Port 80/443 in use | Set `HTTP_PORT=8080` / `HTTPS_PORT=8443` in `.env` |
| Running two stacks side by side | Set a unique `COMPOSE_PROJECT_NAME` in each stack's `.env` |
| Bitrix HTTP wizard rejects sessions | Set `session.cookie_secure = Off` in `config/php/90-php.ini` (revert after enabling TLS) |
| Adding TLS | Provide a dhparam file ≥2048 bits and declare `ssl_dhparam` per vhost in the private overlay |
| macOS bind-mount changes invisible | Docker Desktop bind mounts sometimes need `docker compose restart` → force-recreate to pick up inode changes |
| File-level mounts track inodes | Deploy config changes with `tee` (write in-place) rather than `rsync`/`git pull`; see Readme.md nginx deploy notes |
| `my.cnf` is sized for a dedicated server | `innodb_buffer_pool_size = 4G`; shrink to e.g. 512M for laptop demos |
| `docker compose config -q` without profiles | Errors on `nginx depends_on updater` (updater is behind `hooks` profile) — use `COMPOSE_PROFILES=certs,dbadmin,monitoring,hooks,ftp docker compose config -q` |

## Verify

```bash
# nginx config test
docker run --rm --add-host php:127.0.0.1 \
  -v "$PWD/config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/config/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v /tmp/empty:/etc/nginx/private.conf.d:ro \
  -v /tmp/empty:/etc/nginx/letsencrypt:ro \
  ghcr.io/paskal/nginx:latest nginx -t

# compose validation
COMPOSE_PROFILES=certs,dbadmin,monitoring,hooks,ftp docker compose config -q
```
