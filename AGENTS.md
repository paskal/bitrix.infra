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
| `fix-rights.sh` without sudo | Creates the required directories and skips ownership fixes (sufficient on macOS Docker Desktop); the chowns matter on Linux hosts — use sudo there |
| Adding TLS | Provide a dhparam file ≥2048 bits (`openssl dhparam -out private/letsencrypt/dhparams.pem 2048`) and declare `ssl_dhparam` per vhost in the private overlay |
| macOS bind-mount changes invisible | Docker Desktop bind mounts sometimes need `docker compose restart` → force-recreate to pick up inode changes |
| File-level mounts track inodes | Deploy config changes with `tee` (write in-place) rather than `rsync`/`git pull`; see Readme.md nginx deploy notes |
| `my.cnf` is sized for a dedicated server | `innodb_buffer_pool_size = 4G`; shrink via a gitignored compose override mounting your own cnf (see "Local overrides" in Readme.md) — keeps the tree clean |
| Optional services missing | `adminer`, `updater`, `certbot`, `zabbix-agent`, `ftp` sit behind compose profiles — enable with `COMPOSE_PROFILES` when needed; the core stack needs none |

## Automating the Bitrix installer

The install wizard predates modern web conventions; if you drive it programmatically:

- State is 100% session-based with no URL checkpointing — keep one `curl` cookie jar for the whole flow; losing the session restarts from step 1. Browser automation is fragile here (any tab navigation kills it); `curl` is the reliable path.
- **CWizard keeps no server-side state between requests**: `CWizard::GetVar()` reads `$_REQUEST` directly, so every request must carry ALL the hidden `__wiz_*` fields scraped from the current step's page. Omitting them yields plausible-looking success responses while the service scripts silently no-op.
- The real protocol is a hidden-iframe **form POST** (`application/x-www-form-urlencoded`); replicate the module-installation AJAX loop as `POST` with `CurrentStepID=create_modules&__wiz_nextStep=X&__wiz_nextStepStage=Y` plus all hidden fields. Each response contains `[response]...Post(...)[/response]` with the next step/stage — loop until it stops advancing (~38 iterations for the Start edition). (`GET` happens to work too when every field is in the query string, since CWizard reads `$_REQUEST`.)
- The main installer is followed by a SECOND wizard (the solution/content wizard): `select_template → select_theme → site_settings → data_install → finish`. Do not jump straight to `CurrentStepID=finish` — that skips `data_install`, `_index.php` is never created and the site stays stuck on the wizard runner. Its `data_install` AJAX responses use positional `Post(step, stage)` arguments (not the named-object form of the first wizard), and the theme field is named `__wiz_<solution>_themeID`.
- The licence step embeds an iframe from `www.1c-bitrix.ru` that may issue a top-frame JS redirect in real browsers; curl is immune.
- One installer redirect drops a non-standard port from the URL — re-request `http://localhost:${HTTP_PORT}/` (avoid `curl -L`, it follows to port 80) and the wizard continues.
- Selecting the blank `@` template requires a Bitrix cloud licence; the bundled demo solutions install from local files without one.
- Admin login via curl returns `setAuthResult(false)` even with correct credentials — verify the installed site's admin via a real browser.
- After editing Bitrix tables directly via SQL, delete the matching `bitrix/managed_cache/MYSQL/<dir>` inside the php container or the old value keeps being served.

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
