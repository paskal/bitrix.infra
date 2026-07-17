#!/usr/bin/env sh
set -eu

repo=/web
cron_dir=$repo/config/cron
logrotate_dir=$repo/config/logrotate
container_cron=/etc/cron.d/tasks
permission_guard_active=0

nginx_bind_files='config/nginx/nginx.conf
config/nginx/bitrix.conf
config/nginx/fastcgi.conf
config/nginx/bots.conf
config/nginx/security_headers.conf
config/nginx/static-cdn.conf'

fail() {
  echo "pull-public: $*" >&2
  exit 1
}

inode_or_missing() {
  if [ -e "$1" ]; then
    stat -c %i "$1"
  else
    echo missing
  fi
}

container_is_running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = true ]
}

nginx_bind_signature() {
  for relative_path in $nginx_bind_files; do
    printf '%s:%s\n' "$relative_path" "$(inode_or_missing "$repo/$relative_path")"
  done
}

nginx_container_bind_signature() {
  for relative_path in $nginx_bind_files; do
    container_path=/etc/nginx/${relative_path##*/}
    container_inode=$(docker exec nginx stat -c %i "$container_path" 2>/dev/null || echo missing)
    printf '%s:%s\n' "$relative_path" "$container_inode"
  done
}

restore_protected_permissions() {
  restore_status=0

  echo "pull-public: restoring root ownership and protected file modes"
  for protected_dir in "$cron_dir" "$logrotate_dir"; do
    sudo -n chown root:root "$protected_dir" || restore_status=1
    for protected_file in "$protected_dir"/*; do
      [ -f "$protected_file" ] || continue
      sudo -n chown root:root "$protected_file" || restore_status=1
      sudo -n chmod 0644 "$protected_file" || restore_status=1
    done
  done

  if [ "$restore_status" -ne 0 ]; then
    echo "pull-public: failed to restore protected ownership or modes" >&2
    return 1
  fi
}

restore_on_exit() {
  exit_status=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$permission_guard_active" -eq 1 ]; then
    if ! restore_protected_permissions; then
      exit_status=1
    fi
  fi
  exit "$exit_status"
}

on_signal() {
  exit "$1"
}

test_fresh_nginx_configuration() {
  nginx_image=$(docker inspect --format '{{.Config.Image}}' nginx) ||
    fail "cannot determine the running nginx image"
  nginx_network=$(
    docker inspect \
      --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}' \
      nginx | sed -n '1p'
  ) || fail "cannot determine the nginx network"
  [ -n "$nginx_network" ] || fail "nginx has no Docker network"

  for required_path in \
    "$repo/private/nginx" \
    "$repo/private/nginx/empty.conf" \
    "$repo/private/letsencrypt" \
    "$repo/web/prod" \
    "$repo/web/dev" \
    "$repo/config/nginx/nginx.conf" \
    "$repo/config/nginx/bitrix.conf" \
    "$repo/config/nginx/fastcgi.conf" \
    "$repo/config/nginx/bots.conf" \
    "$repo/config/nginx/security_headers.conf" \
    "$repo/config/nginx/static-cdn.conf" \
    "$repo/config/nginx/conf.d"; do
    [ -e "$required_path" ] || fail "$required_path is unavailable for nginx validation"
  done

  docker run --rm --entrypoint nginx \
    --network "$nginx_network" \
    -v "$repo/web/prod:/web/prod:ro" \
    -v "$repo/web/dev:/web/dev:ro" \
    -v "$repo/config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$repo/config/nginx/bitrix.conf:/etc/nginx/bitrix.conf:ro" \
    -v "$repo/config/nginx/fastcgi.conf:/etc/nginx/fastcgi.conf:ro" \
    -v "$repo/config/nginx/bots.conf:/etc/nginx/bots.conf:ro" \
    -v "$repo/config/nginx/security_headers.conf:/etc/nginx/security_headers.conf:ro" \
    -v "$repo/config/nginx/static-cdn.conf:/etc/nginx/static-cdn.conf:ro" \
    -v "$repo/config/nginx/conf.d:/etc/nginx/conf.d:ro" \
    -v "$repo/private/nginx/empty.conf:/etc/nginx/conf.d/localhost.conf:ro" \
    -v "$repo/private/nginx:/etc/nginx/private.conf.d:ro" \
    -v "$repo/private/letsencrypt:/etc/nginx/letsencrypt:ro" \
    "$nginx_image" -t
}

[ "$(id -un)" = admin ] || fail "must run as admin"
[ -d "$repo" ] || fail "$repo does not exist"
[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] ||
  fail "$repo is not a git worktree"
[ "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" = "$repo" ] ||
  fail "$repo is not the worktree root"
[ "$(git -C "$repo" branch --show-current 2>/dev/null)" = master ] ||
  fail "$repo is not on master"
[ "$(git -C "$repo" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" = origin/master ] ||
  fail "$repo does not track origin/master"

origin=$(git -C "$repo" remote get-url origin 2>/dev/null) ||
  fail "$repo has no origin remote"
case "$origin" in
git@github.com:paskal/bitrix.infra.git | \
  ssh://git@github.com/paskal/bitrix.infra.git | \
  https://github.com/paskal/bitrix.infra.git) ;;
*)
  fail "$repo has an unexpected origin remote"
  ;;
esac

git -C "$repo" diff --quiet || fail "$repo has unstaged tracked changes"
git -C "$repo" diff --cached --quiet || fail "$repo has staged changes"
[ -z "$(git -C "$repo" ls-files --others --exclude-standard -- config/cron config/logrotate)" ] ||
  fail "protected config directories contain untracked files"
[ -d "$cron_dir" ] || fail "$cron_dir does not exist"
[ -d "$logrotate_dir" ] || fail "$logrotate_dir does not exist"

old_head=$(git -C "$repo" rev-parse HEAD) || fail "cannot read the current commit"

trap restore_on_exit EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
permission_guard_active=1

echo "pull-public: granting admin temporary write access to protected config directories"
sudo -n chown admin:admin "$cron_dir" "$logrotate_dir"

echo "pull-public: pulling public infrastructure"
git -C "$repo" pull --ff-only origin master

restore_protected_permissions
permission_guard_active=0
trap - EXIT HUP INT TERM

new_head=$(git -C "$repo" rev-parse HEAD) || fail "cannot read the updated commit"

[ -e "$cron_dir/php-cron.cron" ] || fail "$cron_dir/php-cron.cron is missing after pull"
host_cron_inode=$(inode_or_missing "$cron_dir/php-cron.cron")
if container_is_running php-cron; then
  container_cron_inode=$(docker exec php-cron stat -c %i "$container_cron" 2>/dev/null || echo missing)
  if [ "$host_cron_inode" != "$container_cron_inode" ]; then
    echo "pull-public: php-cron bind inode is stale; restarting php-cron"
    docker restart php-cron
    host_inode=$(inode_or_missing "$cron_dir/php-cron.cron")
    container_inode=$(docker exec php-cron stat -c %i "$container_cron") ||
      fail "cannot verify the php-cron bind inode"
    [ "$host_inode" = "$container_inode" ] ||
      fail "php-cron bind inode mismatch (host $host_inode, container $container_inode)"
    echo "pull-public: php-cron bind inode verified: $host_inode"
  else
    echo "pull-public: php-cron restart not required"
  fi
else
  echo "pull-public: php-cron is stopped; leaving it stopped"
fi

host_nginx_bind_signature=$(nginx_bind_signature)
nginx_running=0
container_nginx_bind_signature=$host_nginx_bind_signature
if container_is_running nginx; then
  nginx_running=1
  container_nginx_bind_signature=$(nginx_container_bind_signature)
fi

nginx_runtime_changed=0
for nginx_path in $nginx_bind_files config/nginx/conf.d; do
  if ! git -C "$repo" diff --quiet "$old_head" "$new_head" -- "$nginx_path"; then
    nginx_runtime_changed=1
    break
  fi
done

if [ "$host_nginx_bind_signature" != "$container_nginx_bind_signature" ]; then
  nginx_runtime_changed=1
fi

if [ "$nginx_runtime_changed" -eq 1 ]; then
  [ "$nginx_running" -eq 1 ] || fail "nginx is stopped; configuration was not activated"
  if [ "$host_nginx_bind_signature" != "$container_nginx_bind_signature" ]; then
    echo "pull-public: nginx file-bind inode is stale; testing fresh mounts"
    test_fresh_nginx_configuration
    echo "pull-public: restarting nginx to rebind public configuration"
    docker restart nginx
    rebound_nginx_bind_signature=$(nginx_container_bind_signature)
    [ "$host_nginx_bind_signature" = "$rebound_nginx_bind_signature" ] ||
      fail "nginx file-bind inode mismatch after restart"
    docker exec nginx nginx -t
  else
    echo "pull-public: testing directory-mounted nginx configuration"
    docker exec nginx nginx -t
    echo "pull-public: reloading nginx"
    docker exec nginx nginx -s reload
  fi
else
  echo "pull-public: nginx runtime configuration unchanged"
fi

echo "pull-public: deployment complete at $new_head"
