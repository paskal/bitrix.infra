# shellcheck shell=sh
# Sourced by the host scripts. The deploy user owns the checkouts, runs the deploy pulls and the
# jobs that do not need root, and keeps the backup credentials in its home (~/.aws). Set
# DEPLOY_USER in the environment or in the repository's .env; the default is admin.
# Sets deploy_user and deploy_home.
deploy_root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -f "${deploy_root}/docker-compose.yml" ] || deploy_root="${INFRA_DIR:-$(pwd)}"
deploy_user="${DEPLOY_USER:-}"
if [ -z "${deploy_user}" ] && [ -f "${deploy_root}/.env" ]; then
  # value as compose reads it: quotes, a trailing comment, spaces and a CR removed
  deploy_user=$(sed -n 's/^DEPLOY_USER=//p' "${deploy_root}/.env" | tr -d "\"'\r" |
    sed 's/[[:space:]]#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | tail -1)
fi
deploy_user="${deploy_user:-admin}"
# a user that does not exist yet has no passwd entry; callers run with set -e, some with pipefail
deploy_home=$(getent passwd "${deploy_user}" 2>/dev/null | cut -d: -f6) || deploy_home=""
deploy_home="${deploy_home:-/home/${deploy_user}}"
