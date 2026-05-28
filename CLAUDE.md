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

## Nginx Config Deployment
- **CRITICAL: NEVER `docker compose restart nginx` without testing config first.** A broken config prevents nginx from starting, causing full site outage. Always:
  1. `docker exec $(docker ps -qf "name=nginx" | head -1) nginx -t`
  2. Only if test passes → `docker compose restart nginx` or `docker exec nginx nginx -s reload`
- File-level Docker bind mounts track inodes; **anything that replaces the file — `rsync`, `git pull`, `git checkout`, `git stash` — swaps the inode and the running container keeps reading the OLD content.** `nginx -t`/`-s reload` then operate on the stale inode and silently confirm the old config (verify with `docker exec nginx grep <new-marker> /etc/nginx/file.conf` — not just `nginx -t`).
- Deploy via `tee` to write in-place: `ssh bitrix 'tee /web/config/nginx/file.conf' < config/nginx/file.conf > /dev/null`
- Always test before reload: `docker exec nginx nginx -t && docker exec nginx nginx -s reload`
- **If the inode was already swapped (e.g. you deployed via `git pull`), reload is not enough — re-bind with `docker restart nginx`** (plain docker; it re-resolves bind mounts from the stored host path on start). `docker compose up/restart nginx` currently errors `no such service: adminer` (compose-file depends_on inconsistency), so use plain `docker restart`. Validate the new file first WITHOUT touching the live container via an ephemeral run on the compose network: `docker run --rm --entrypoint nginx --network web_default -v /web/config/nginx/<each>.conf:/etc/nginx/<each>.conf:ro -v /web/private/nginx:/etc/nginx/private.conf.d:ro -v /web/private/letsencrypt:/etc/nginx/letsencrypt:ro ghcr.io/paskal/nginx:latest -t`
- Directory-level mounts (e.g. `conf.d/`) don't have the inode issue
- `nginx -V` output from a running container may not match the image used on restart — don't trust module availability without testing in a fresh container

## Cron File Deployment
- `/web/config/cron` directory is owned by root; to deploy cron changes:
  `sudo chown admin:admin /web/config/cron && git pull && sudo chown root:root /web/config/cron && sudo chown root:root /web/config/cron/*.cron && sudo chmod 0644 /web/config/cron/*.cron`
- `/etc/cron.d/bitrix_infra` is a symlink to `/web/config/cron/host.cron` (per `disaster-recovery.sh`), so the chown dance + `git pull` is the whole deploy.

## PHPStan Monitoring

Weekly PHPStan scan against the prod Bitrix tree; count of owned-code findings is read by zabbix-agent via `system.run`, trigger alerts when count ≠ 0.

**File locations:**
- `scripts/phpstan-scan.sh` — entrypoint (flock-guarded, self-updates PHAR)
- `private/phpstan/phpstan-owned.neon` — alerted scope (target = 0)
- `private/phpstan/phpstan-diagnostic.neon` — manual broader sweep
- `private/phpstan/phpstan.phar` — auto-updated PHAR (gitignored)
- `config/zabbix/templates/phpstan-monitoring.yaml` — template (three items, three triggers — count + freshness + failure-marker)
- `logs/phpstan/owned-latest.json` + `owned_errors_count.txt` — output, also kept for `diagnostic-*`
- `logs/phpstan/stderr.log` — open_basedir noise + any real PHP warnings
- Cron line in `config/cron/host.cron`: `30 4 * * 1 root cd $INFRA_DIR && ./scripts/phpstan-scan.sh >>/web/logs/phpstan/cron.log 2>&1` (script's diagnostic prints preserved for forensics)

**Manual scans:**
```bash
# Owned scope (what Zabbix watches) — ~2 min cold, ~1 min warm
ssh favor-group 'cd /web && ./scripts/phpstan-scan.sh'

# Diagnostic scope (broader, manual-only) — ~5 min cold
ssh favor-group 'cd /web && ./scripts/phpstan-scan.sh --diagnostic'

# Read result
ssh favor-group 'cat /web/logs/phpstan/owned_errors_count.txt'
```

**When to use diagnostic scope:** the owned count jumped and the obvious recent commit doesn't explain it. Run diagnostic, diff the file lists against `owned-latest.json`, see if a path change accidentally scoped in vendor code (the answer is usually yes — fix via `excludePaths` in the owned neon).

**Re-import the Zabbix template after edits:**
```python
from zabbix_utils import ZabbixAPI
import os
api = ZabbixAPI(url=os.environ['ZABBIX_URL'])
api.login(token=os.environ['ZABBIX_TOKEN'])
with open('config/zabbix/templates/phpstan-monitoring.yaml') as f:
    api.configuration.import_(
        source=f.read(), format='yaml',
        rules={
            'templates':       {'createMissing': True, 'updateExisting': True},
            'items':           {'createMissing': True, 'updateExisting': True},
            'triggers':        {'createMissing': True, 'updateExisting': True},
            'template_groups': {'createMissing': True},
        },
    )
```
Zabbix canonicalises the YAML on export (strips `value_type: UNSIGNED` since that's the default, normalises block-scalar whitespace). The committed file is the canonical export form — diffs after edits should be small and stable.

**Linking the template to a host** (`host.update` REPLACES the templates list, so preserve existing first):
```python
h = api.host.get(hostids='<HOSTID>', selectParentTemplates=['templateid'], output=['hostid'])[0]
existing = [{'templateid': t['templateid']} for t in h['parentTemplates']]
api.host.update(hostid='<HOSTID>', templates=existing + [{'templateid': '<TEMPLATEID>'}])
```
On favor-group: template 10655 linked to host 10350 (`favor-group.ru_yandex.cloud.host`).

After linking, the agent picks up the new active-check list on its next config refresh. Force it immediately with `docker compose restart zabbix-agent` (or `docker compose --profile monitoring restart zabbix-agent` if started under that profile) — otherwise the first item value lands ~5 minutes later via the agent's automatic refresh.

**Triggers in the template:**
- `system.run[... owned_errors_count.txt]<>0` — fires when owned-error count drifts above zero (severity WARNING).
- `fuzzytime(... vfs.file.time[owned-latest.xml,modify], 8d)=0` — long-tail backstop. Fires when the XML file hasn't been rewritten in 8 days. We watch the XML mtime rather than count.txt because the XML is only ever written when PHPStan actually completed a scan; the count file could in principle be touched manually and silently re-arm freshness. One-day grace over the 7-day cron interval. Severity WARNING.
- `last(... vfs.file.exists[owned_last_failure.txt])=1` — fast-path. Fires within ~5 min (one polling cycle) when the scan script writes a failure sentinel (empty/truncated XML, PHPStan exit ≠ 0|1, simplexml parse failure, post-processing failure). The sentinel is auto-cleared on the next successful run. Severity HIGH.

All three ship `status: ENABLED` in the YAML — re-imports stay armed without an extra step. Trade-off: a fresh install must stabilise (run the scan once → count=0 → XML file fresh) *before* linking the template to a host, otherwise the count and freshness triggers fire on first poll. See Readme.md "How to enable" step 5 for the linking order.

**PHAR auto-update note:** no version pin. `curl -sLz` does a conditional GET; zero traffic when unchanged. Acceptable because the metric is *zero owned errors* — a new PHPStan release that adds a rule simply produces fixable findings on the next run, not a baseline-drift false alarm.

**Historical scans:** previous runs aren't archived (only `*-latest.json` is kept). For trend data, look at the Zabbix item history (retention 30 d by default in the shipped template).

**Full design rationale** (D1–D7, all task post-mortems, ignoreErrors taxonomy, synthetic-regression test transcript): `favor-group.ru/docs/plans/completed/20260517-phpstan-prod-monitoring.md`.

## SEO Reindex Cron
- `scripts/seo-reindex.sh` (daily 21:15 UTC = 00:15 MSK as `admin`) drains URLs from `/web/private/seo-reindex/queue.txt` into Yandex Webmaster recrawl, up to ~960/day account-wide quota. Token: `/web/private/environment/seo-reindex.env`. Logs: `/web/logs/seo-reindex/YYYY-MM-DD.log`. Bing is sent manually via `bin/search-reindex submit --bing-only <file>`.

## Export Profiles (acrit.export)
- Run single export: `docker exec -u www-data php-cron bash -c "/usr/bin/php -f /web/prod/bitrix/modules/acrit.export/cli/export.php profile=ID auto=Y site=s1 >> /web/prod/upload/acrit.export/log/log_ID.e63f31938c399df95752fe5013735c65.txt 2>&1"`
- Must run as `www-data`, not root (root is rejected by the script)
- `auto=Y` may skip export if data unchanged; killing a running export can leave a lock in the DB (visible as "Profile N is locked" in log), unlock via Bitrix admin
- Logs: `/web/prod/upload/acrit.export/log/`
- XML output: `/web/prod/upload/acrit.export/`