#!/usr/bin/env sh
set -e -u

# This script sets proper owner and group for files in the repo.
# Run with sudo before the first docker-compose up on a fresh clone.

# Create directories that docker file-mounts require to exist as files, not dirs.
# Without this, docker creates them as directories on first mount, breaking the container.
echo "Creating required directories..."
mkdir -p logs/nginx logs/php logs/mysql logs/phpstan logs/backup \
  private/mysqld private/mysql-data private/nginx \
  private/letsencrypt \
  web/prod web/dev
[ -f private/msmtprc ] || touch private/msmtprc

# Everything below changes ownership and needs root. Without it the
# directories above are still created, which is all that matters on macOS
# Docker Desktop (VirtioFS); on Linux hosts re-run with sudo.
if [ "$(id -u)" -ne 0 ]; then
  echo "Not root: directories created, ownership fixes skipped (fine on macOS;"
  echo "on Linux hosts re-run with sudo so container UIDs can write)."
  exit 0
fi

# On a server set up by disaster-recovery.sh the checkouts and the secrets belong
# to the deploy user (uid 1000; DEPLOY_USER, admin by default): the deploy pulls and
# the host scripts run as that user, the php containers run as www-data (also uid 1000), and git refuses a tree owned
# by someone else. A clone made as root or files restored with a foreign uid would
# break the next pull or a job that reads a secret. A developer checkout (no such
# user with uid 1000, e.g. macOS) keeps its owner, so compose and git still work
# for the person who runs them. The blocks further down put cron, logrotate and
# mysql files back to their own owners.
# shellcheck source=scripts/deploy-user.sh
. ./scripts/deploy-user.sh
if [ "$(id -u "${deploy_user}" 2>/dev/null || true)" = 1000 ]; then
  if command -v git >/dev/null 2>&1; then
    echo "Fixing repository ownership..."
    for repo in . ./private; do
      [ -d "$repo/.git" ] || continue
      chown -R 1000:1000 "$repo/.git"
      # Tracked files and every directory on their way: git replaces a file by
      # deleting and recreating it, and adds new files to existing directories.
      # A path missing from the worktree makes chown fail, which is not an error here.
      (
        cd "$repo" || exit 0
        git -c safe.directory='*' ls-files -z | xargs -0 chown -h 1000:1000 2>/dev/null
        {
          printf '.\0'
          git -c safe.directory='*' ls-tree -r -d --name-only -z HEAD
        } | xargs -0 chown 1000:1000 2>/dev/null
      ) || true
    done
  fi

  # Compose reads the secrets as root; the Zabbix agent (uid 1997) reads its own
  # MySQL credentials. Nobody else needs to read any of them.
  echo "Fixing private/environment permissions..."
  if [ -d ./private/environment ]; then
    for f in ./private/environment/*; do
      [ -f "$f" ] || continue
      case "$f" in
      *.example) chown 1000:1000 "$f" ;;
      */zabbix-*.conf | *zbx*.cnf) chown 1997:1997 "$f" && chmod 0400 "$f" ;;
      *) chown 1000:1000 "$f" && chmod 0600 "$f" ;;
      esac
    done
  fi
fi

# cron tasks should be owned by root, otherwise they won't run
# and will be silently ignored
echo "Fixing cron permissions..."
chown -R 0:0 ./config/cron
chmod 0644 ./config/cron/*
# overlay cron files are bind-mounted into /etc/cron.d and must be root-owned too
if [ -d ./private/cron ]; then
  chown -R 0:0 ./private/cron
  # guard the glob: an empty private/cron/ would leave *.cron literal and error
  for f in ./private/cron/*.cron; do
    [ -e "$f" ] || continue
    chmod 0644 "$f"
  done
fi

# logrotate configuration should be owned by root,
# otherwise it will be ignored
echo "Fixing logrotate permissions..."
chown -R 0:0 ./config/logrotate
chmod 0644 ./config/logrotate/*

# mysql container files
echo "Fixing mysql permissions..."
chown -R 1001:1001 ./config/mysql
[ -d ./logs/mysql ] && chown -R 1001:1001 ./logs/mysql
[ -d ./private/mysql-data ] && chown -R 1001:1001 ./private/mysql-data
[ -d ./private/mysqld ] && chown -R 1001:1001 ./private/mysqld

# php and nginx containers files
echo "Fixing php and nginx permissions..."
[ -d ./logs/nginx ] && chown -R 1000:1000 ./logs/nginx
[ -d ./logs/php ] && chown -R 1000:1000 ./logs/php
[ -d ./logs/phpstan ] && chown -R 1000:1000 ./logs/phpstan
[ -d ./logs/backup ] && chown -R 1000:1000 ./logs/backup
[ -d ./logs/seo-reindex ] && chown -R 1000:1000 ./logs/seo-reindex
[ -d ./private/seo-reindex ] && chown -R 1000:1000 ./private/seo-reindex
[ -d ./private/letsencrypt ] && chown -R 1000:1000 ./private/letsencrypt
[ -d ./private/nginx ] && chown -R 1000:1000 ./private/nginx
[ -f ./private/msmtprc ] && chown 1000:1000 ./private/msmtprc
echo "web folder will be processed now, hold on..."
chown -R 1000:1000 ./web

echo "Fixing backup folder permissions..."
[ -d ./backup/ ] && chown -R 1000:1000 ./backup/

echo "Access rights fix is complete"
