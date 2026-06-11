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
| Bitrix HTTP wizard rejects sessions (Firefox/curl) | `session.cookie_secure = Off` via a gitignored local override (see "Local overrides" in Readme.md) — do not edit the tracked ini |
| 502s + php-fpm SIGSEGV after install on arm64 | PHP 8.4 opcache JIT crash — `opcache.jit = disable` in the same local override |
| `fix-rights.sh` needs interactive sudo | On macOS Docker Desktop only the `mkdir` part matters; run without sudo and ignore chown failures. The chowns matter on Linux hosts |
| Adding TLS | Provide a dhparam file ≥2048 bits (`openssl dhparam -out private/letsencrypt/dhparams.pem 2048`) and declare `ssl_dhparam` per vhost in the private overlay |
| macOS bind-mount changes invisible | Docker Desktop bind mounts sometimes need `docker compose restart` → force-recreate to pick up inode changes |
| File-level mounts track inodes | Deploy config changes with `tee` (write in-place) rather than `rsync`/`git pull`; see Readme.md nginx deploy notes |
| `my.cnf` is sized for a dedicated server | `innodb_buffer_pool_size = 4G`; shrink via a gitignored compose override mounting your own cnf (see "Local overrides" in Readme.md) — keeps the tree clean |
| Optional services missing | `adminer`, `updater`, `certbot`, `zabbix-agent`, `ftp` sit behind compose profiles — enable with `COMPOSE_PROFILES` when needed; the core stack needs none |

## Automating the Bitrix installer

The install wizard predates modern web conventions; if you drive it programmatically:

- State is 100% session-based with no URL checkpointing — keep one `curl` cookie jar for the whole flow; losing the session restarts from step 1. Browser automation is fragile here (any tab navigation kills it); `curl` is the reliable path.
- The module-installation step is AJAX-only: each `GET /?CurrentStepID=create_modules&__wiz_nextStep=X&__wiz_nextStepStage=Y` returns `[response]...Post({'nextStep': ..., 'nextStepStage': ...})[/response]` — loop until it stops advancing (~38 iterations for the Start edition).
- The licence step embeds an iframe from `www.1c-bitrix.ru` that may issue a top-frame JS redirect in real browsers; curl is immune.
- One installer redirect drops a non-standard port from the URL — reopen `http://localhost:${HTTP_PORT}/` and the wizard continues.
- Selecting the blank `@` template requires a Bitrix cloud licence; the bundled demo solutions install from local files without one.

## Verify

```bash
# nginx config test
mkdir -p /tmp/empty
docker run --rm --add-host php:127.0.0.1 \
  -v "$PWD/config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/config/nginx/bitrix.conf:/etc/nginx/bitrix.conf:ro" \
  -v "$PWD/config/nginx/fastcgi.conf:/etc/nginx/fastcgi.conf:ro" \
  -v "$PWD/config/nginx/bots.conf:/etc/nginx/bots.conf:ro" \
  -v "$PWD/config/nginx/security_headers.conf:/etc/nginx/security_headers.conf:ro" \
  -v "$PWD/config/nginx/static-cdn.conf:/etc/nginx/static-cdn.conf:ro" \
  -v "$PWD/config/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v /tmp/empty:/etc/nginx/private.conf.d:ro \
  -v /tmp/empty:/etc/nginx/letsencrypt:ro \
  ghcr.io/paskal/nginx:latest nginx -t

# compose validation
COMPOSE_PROFILES=certs,dbadmin,monitoring,hooks,ftp docker compose config -q
```
