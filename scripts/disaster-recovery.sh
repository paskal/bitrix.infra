#!/usr/bin/env sh
set -e -u

# This script sets up clean Ubuntu host machine for bitrix.infra
# and recovers site files and the DB content from the backup.

# SITE-SPECIFIC operational script: every value below is for favor-group.ru.
# Forks must replace the variables in this block before use.
domain="favor-group.ru"
backup_s3_directory=favor-group-backup
# Backups sit under the hostname of the machine that made them (duplicity_web_<host>,
# mysql_<host>). After a failover the newest copies belong to the replacement host, so
# restore from it with RESTORE_FROM_HOST=<its hostname>.
restore_from_host="${RESTORE_FROM_HOST:-favor-group}"
duplicity_backup_location="boto3+s3://${backup_s3_directory}/duplicity_web_${restore_from_host}"
mysql_restore_hostname="${restore_from_host}"
mysql_restore_db="favor_group_ru"

### Pre-checks

# Check the current running folder
[ -d "./scripts" ] || (echo "./scripts locations is absent, please run from parent directory of this script" && exit 45)

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo, 'sudo $0'"
  exit 46
fi

echo "Note: it's safe to run the script multiple times"

### Functions

setup_aws() {
  # The backup scripts and this restore read the keys from /home/admin/.aws (see admin_user_setup).
  mkdir -p /home/admin/.aws
  chown admin:"$(id -gn admin)" /home/admin/.aws
  if [ ! -f /usr/local/bin/aws ]; then
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    apt-get -y install unzip >/dev/null
    unzip -o awscliv2.zip >/dev/null
    ./aws/install >/dev/null
    rm -rf awscliv2.zip ./aws
  fi
  if [ ! -f /home/admin/.aws/config ]; then
    echo "[default]\nregion = ru-central1\n" >/home/admin/.aws/config
    chown admin:"$(id -gn admin)" /home/admin/.aws/config
  fi
  if [ ! -f /home/admin/.aws/credentials ]; then
    echo "!! AWS credentials file is absent, won't be able to restore backups without it !!\n"
    echo "Please go by the link and create new static key for the existing service account:"
    echo "https://console.yandex.cloud/folders/<your-folder-id>/iam/service-accounts\n"
    echo "\
You'll get ID and secret key, write them to /home/admin/.aws/credentials in the following format:\n\n\
[default]\n\
aws_access_key_id = KEY\n\
aws_secret_access_key = SECRET_KEY\
"
    exit 47
  fi
}

# Host tools the cron scripts need and a fresh image may lack: m4 and pigz for mysql-dump.sh
# (without m4 the dump fails before writing anything), jq for seo-reindex.sh.
install_host_packages() {
  echo "installing host tools (m4, pigz, jq)..."
  apt-get update -qq >/dev/null
  apt-get -y install m4 pigz jq >/dev/null
}

# Host cron runs several jobs as admin, the backup scripts read /home/admin/.aws, and the
# updater deploys over ssh as admin with passwordless sudo. Containers write as uid 1000, so
# admin is uid 1000: an alias of the login user when that user already has uid 1000.
admin_user_setup() {
  if id admin >/dev/null 2>&1; then
    if [ "$(id -u admin)" -ne 1000 ]; then
      echo "admin exists with uid $(id -u admin), but the containers write as uid 1000; fix admin by hand" >&2
      exit 53
    fi
  else
    login_user=$(logname)
    if [ "${login_user}" != "root" ] && [ "$(id -u "${login_user}")" -eq 1000 ]; then
      echo "creating admin as an alias of ${login_user} (uid 1000)"
      useradd -o -u 1000 -g "$(id -g "${login_user}")" -M -d "/home/${login_user}" -s /bin/bash admin
      [ -e /home/admin ] || ln -s "/home/${login_user}" /home/admin
    elif getent passwd 1000 >/dev/null; then
      echo "uid 1000 belongs to $(getent passwd 1000 | cut -d: -f1), not the login user; create admin by hand" >&2
      exit 52
    else
      echo "creating admin user (uid 1000)"
      if getent group admin >/dev/null; then
        useradd -u 1000 -g admin -m -d /home/admin -s /bin/bash admin
      else
        useradd -u 1000 -U -m -d /home/admin -s /bin/bash admin
      fi
    fi
  fi
  if getent group docker >/dev/null && ! id -nG admin | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker admin
  fi
  # by uid: sudo names an alias after the first passwd entry with that uid, not "admin"
  if [ ! -f /etc/sudoers.d/90-bitrix-infra-admin ]; then
    echo '#1000 ALL=(ALL) NOPASSWD:ALL' >/tmp/90-bitrix-infra-admin
    visudo -cf /tmp/90-bitrix-infra-admin >/dev/null
    install -m 0440 /tmp/90-bitrix-infra-admin /etc/sudoers.d/90-bitrix-infra-admin
    rm -f /tmp/90-bitrix-infra-admin
  fi
}

install_docker_if_not_installed() {
  command -v docker >/dev/null && return
  echo "docker is installing..."
  # set low enough docker MTU to work with host machine MTU of 1450
  mkdir -p /etc/docker
  echo '{"mtu": 1422}' >/etc/docker/daemon.json

  apt-get update >/dev/null
  apt-get -y install \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release >/dev/null

  if [ ! -f "/etc/apt/sources.list.d/docker.list" ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg >/dev/null
    echo \
      "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt-get update >/dev/null
  fi

  apt-get -y install docker-ce docker-ce-cli containerd.io >/dev/null
  # add current user to docker group
  [ "$(logname)" != "root" ] && usermod -aG docker "$(logname)"
  echo "docker is installed"
}

install_docker_compose_if_not_installed() {
  if docker compose version >/dev/null 2>&1; then
    return
  fi
  echo "docker-compose-plugin is installing..."
  apt-get update -qq && apt-get -y install docker-compose-plugin >/dev/null
  echo "docker-compose-plugin is installed"
}

# Necessary for Yandex with DDoS Protection enabled https://cloud.yandex.com/en/docs/vpc/concepts/mtu-mss
set_mtu_1450_if_not_set() {
  if [ "$(cat /sys/class/net/eth0/mtu)" -eq 1450 ]; then return; fi
  echo "setting mtu to 1450..."
  cat <<EOF >/etc/netplan/90-mtu.yaml
network:
  version: 2
  ethernets:
    eth0:
      mtu: 1450
EOF
  netplan apply
  echo "done, mtu is $(cat /sys/class/net/eth0/mtu)"
}

create_host_cronjob_if_not_exist() {
  if [ ! -f "/etc/cron.d/bitrix_infra" ]; then
    echo "creating /etc/cron.d/bitrix_infra from ./config/cron/host.cron..."
    ln -s "${PWD}/config/cron/host.cron" /etc/cron.d/bitrix_infra
    echo "created /etc/cron.d/bitrix_infra"
  fi
  # site-specific host cron from the private overlay, if checked out
  if [ -f "${PWD}/private/cron/host-site.cron" ] && [ ! -f "/etc/cron.d/bitrix_site" ]; then
    chown root:root "${PWD}/private/cron/host-site.cron"
    chmod 0644 "${PWD}/private/cron/host-site.cron"
    ln -s "${PWD}/private/cron/host-site.cron" /etc/cron.d/bitrix_site
    echo "created /etc/cron.d/bitrix_site"
  fi
}

zabbix_setup() {
  [ -f "/etc/systemd/system/set-zabbix-docker-acl.service" ] && return
  echo "creating zabbix user and group"
  groupadd -g 1997 zabbix
  useradd -u 1997 -g zabbix -G docker zabbix
  echo "creating a service 'set-zabbix-docker-acl' which will allow zabbix to read and write docker socket"
  cat <<EOF >/etc/systemd/system/set-zabbix-docker-acl.service
[Unit]
 Description=Zabbix docker ACL Hack
 Requires=local-fs.target
 After=local-fs.target

[Service]
 ExecStart=/usr/bin/setfacl -m u:zabbix:rw /var/run/docker.sock

[Install]
 WantedBy=multi-user.target
EOF
  # acl provides setfacl package
  apt-get -y install acl >/dev/null
  # enable the service on startup and start it
  systemctl enable set-zabbix-docker-acl >/dev/null
  systemctl start set-zabbix-docker-acl
  echo "done the zabbix set up"
}

memcached_user_setup() {
  if ! getent group | cut -d: -f3 | grep -qx '11211'; then
    echo "creating memcached group"
    groupadd -g 11211 memcached
  fi

  if ! getent passwd | cut -d: -f3 | grep -qx '11211'; then
    echo "creating memcached user"
    useradd -u 11211 -g memcached memcached
  fi
}

mysql_user_setup() {
  if ! getent group | cut -d: -f3 | grep -qx '1001'; then
    echo "creating mysql group"
    groupadd -g 1001 mysql
  fi

  if ! getent passwd | cut -d: -f3 | grep -qx '1001'; then
    echo "creating mysql user"
    useradd -u 1001 -g mysql mysql
  fi
}

set_up_duplicity() {
  command -v duplicity >/dev/null && return
  echo "installing duplicity for backups..."
  add-apt-repository -y ppa:duplicity-team/duplicity-release-git >/dev/null
  apt-get -y install duplicity python3-boto3 >/dev/null
  echo "done setting up duplicity"
}

# The updater container deploys over ssh as admin with private/updater_ssh_key (config/updater.yaml).
updater_access_setup() {
  [ -f ./private/updater_ssh_key ] || return 0
  pubkey=$(ssh-keygen -y -f ./private/updater_ssh_key)
  # sshd looks in the home from passwd, which for an existing admin may not be /home/admin
  ssh_dir="$(getent passwd admin | cut -d: -f6)/.ssh"
  mkdir -p "${ssh_dir}"
  touch "${ssh_dir}/authorized_keys"
  if ! grep -qxF "${pubkey}" "${ssh_dir}/authorized_keys"; then
    # a file without a final newline would glue the new key onto its last line
    [ -z "$(tail -c1 "${ssh_dir}/authorized_keys")" ] || echo >>"${ssh_dir}/authorized_keys"
    echo "${pubkey}" >>"${ssh_dir}/authorized_keys"
  fi
  chown -R admin:"$(id -gn admin)" "${ssh_dir}"
  chmod 0700 "${ssh_dir}"
  chmod 0600 "${ssh_dir}/authorized_keys"
}

# A second backup destination (BACKUP2_* in backup.env) needs its keys under its own profile.
check_second_backup_destination() {
  [ -f ./private/environment/backup.env ] || return 0
  profile=$(sed -n 's/^BACKUP2_AWS_PROFILE=//p' ./private/environment/backup.env | tr -d "\"'")
  [ -n "${profile}" ] || return 0
  if ! grep -qx "\[${profile}\]" /home/admin/.aws/credentials; then
    echo "\nbackup.env sends backups to a second destination with the AWS profile '${profile}',"
    echo "but /home/admin/.aws/credentials has no [${profile}] section: add that destination's keys there."
  fi
}

final_ip_check() {
  server_ip=$(dig +short myip.opendns.com @resolver1.opendns.com)
  site_a_entry=$(dig +short ${domain})

  if [ "${server_ip}" != "${site_a_entry}" ]; then
    echo "\nCurrent IP for ${domain} is: ${site_a_entry}"
    echo "This machine external IP (best guess): ${server_ip}"

    echo "\
\nPlease ensure DNS A entries are pointing to this machine external IP: \
https://connect.yandex.ru/portal/services/webmaster/resources/${domain} \
"
  else
    echo "Server IP (${server_ip}) matches A entry for ${domain}, by now site should be working at https://${domain}"
  fi
}

backup_restore() {
  # Idempotency marker: gate on a flag the restore itself writes, NOT on the mere
  # existence of ./private — that directory is tracked in git (ships *.env.example,
  # phpstan/), so it is ALWAYS present on a fresh clone and a `[ -d ./private ]` check
  # silently skips the entire S3 restore on every run.
  restore_marker="${PWD}/.dr-file-restore-done"
  if [ -f "${restore_marker}" ]; then
    echo "file restore already completed (${restore_marker} present); skipping. Delete it to re-restore."
    return
  fi
  # duplicity 3.x (Ubuntu 24.04) REFUSES to restore into a non-empty target ("--force"
  # no longer covers restore as it did in 0.8.x), and the clone already populated ${PWD}.
  # So restore into an empty staging dir, then merge over the clone — the real private/
  # secrets, web/prod and the override symlink overwrite the tracked placeholders.
  echo "Restoring file backup to staging directory..."
  staging="${PWD}/.dr-restore"
  rm -rf "${staging}"
  mkdir -p "${staging}" "${PWD}/logs"
  HOME=/home/admin duplicity \
    --no-encryption \
    --s3-endpoint-url https://storage.yandexcloud.net \
    --log-file "${PWD}/logs/duplicity.log" \
    --archive-dir /root/.cache/duplicity \
    --force \
    "${duplicity_backup_location}" "${staging}"
  # duplicity 3.x prints no completion summary, so assert the restore actually produced
  # the secrets we depend on before merging (catches a silent/partial restore).
  if [ ! -f "${staging}/private/environment/mysql.env" ]; then
    echo "ERROR: restore did not produce private/environment/mysql.env — aborting." >&2
    exit 49
  fi
  echo "merging restored files into ${PWD} (this can take a few minutes)..."
  cp -a "${staging}/." "${PWD}/"
  rm -rf "${staging}"
  touch "${restore_marker}"
  echo "Server has latest backup of files restored!"
  echo "Linking logrotate configuration to /etc/logrotate.d/..."
  ln -sf /web/config/logrotate/* /etc/logrotate.d/
  ./scripts/fix-rights.sh
}

restore_mysql() {
  rm -f ./private/mysql-data/deleteme_* || true
  backup_directory_path="./backup/"

  # retrieving last backup from the S3
  # Select the most-recent DATED daily dump that is large enough to be real:
  #  - grep keeps only keys under a /YYYY-MM-DD/ folder, excluding ad-hoc dumps like
  #    pre-8.4-upgrade/ (which otherwise sorts LAST lexically and would be picked by a
  #    naive `tail -1`, restoring a months-old DB).
  #  - awk '$3 > 1000000' drops empty/broken dumps (a failed mysqldump yields a ~20-byte
  #    gzip; see the size guard in scripts/mysql-dump.sh).
  #  - sort -k1,2 orders by the object's upload date+time so tail -1 is the newest good one.
  echo -n "looking for the last mysql backup in S3..."
  backup_filepath=$(HOME=/home/admin /usr/local/bin/aws \
    --endpoint-url=https://storage.yandexcloud.net \
    --recursive \
    s3 ls "s3://${backup_s3_directory}/mysql_${mysql_restore_hostname}/" |
    grep -E "/[0-9]{4}-[0-9]{2}-[0-9]{2}/.*-mysqldump\.sql\.gz$" |
    awk '$3 > 1000000' |
    sort -k1,2 |
    tail -1 |
    cut -d '/' -f 2-)
  [ -n "${backup_filepath}" ] || { echo " no valid (>1MB, dated) mysql dump found in S3!" && exit 48; }
  echo " found s3://${backup_s3_directory}/mysql_${mysql_restore_hostname}/${backup_filepath}"
  backup_dir=$(echo "${backup_filepath}" | cut -d "/" -f -1)
  if [ ! -f "${backup_directory_path}${backup_filepath}" ]; then
    HOME=/home/admin /usr/local/bin/aws \
      --endpoint-url=https://storage.yandexcloud.net \
      s3 cp \
      "s3://${backup_s3_directory}/mysql_${mysql_restore_hostname}/${backup_filepath}" \
      "${backup_directory_path}${backup_dir}/" >/dev/null
    echo "mysql backup downloaded to ${backup_directory_path}${backup_filepath}"
  fi
  # restoring the backup
  . ./private/environment/mysql.env

  # create temp file to store mysql login and password for the time of the script
  # location for it should be the directory which is passed inside the container
  mysql_config_file=$(
    echo 'mkstemp(template)' |
      m4 -D template="./private/mysql-data/deleteme_XXXXXX"
  ) || exit

  mysql_config_inside_container="/var/lib/mysql/${mysql_config_file##*/}"
  echo "[client]\nuser = root\npassword = ${MYSQL_ROOT_PASSWORD}\ndefault-character-set = utf8mb4" >"${mysql_config_file}"
  trap 'rm -f -- "${mysql_config_file}"' EXIT

  # start_services() returns as soon as `up -d` exits, but MySQL needs ~30s to initialise
  # and accept socket connections. Without this wait the first query fails with
  # "ERROR 2002 ... Can't connect ... through socket" and set -e aborts the whole restore.
  echo -n "waiting for MySQL to accept connections..."
  wait_i=0
  until docker exec mysql mysqladmin ping --silent >/dev/null 2>&1; do
    wait_i=$((wait_i + 1))
    if [ "${wait_i}" -gt 60 ]; then echo " timeout after 180s" && exit 50; fi
    sleep 3
  done
  echo " ready"

  prod_db_tables=$(
    docker exec -u0 mysql /bin/mysql \
      --defaults-extra-file="${mysql_config_inside_container}" \
      -N \
      -e "select count(*) from information_schema.tables where table_schema = '${mysql_restore_db}';"
  )
  if [ "${prod_db_tables}" -ne 0 ]; then
    echo "There are ${prod_db_tables} tables already in ${mysql_restore_db}, not restoring the DB"
    rm -f "${mysql_config_file}"
    return
  fi
  echo "restoring the MySQL backup..."
  # The archive is checked before the import, and the import runs under bash with
  # pipefail (sh has none): without it a zcat that dies mid-stream leaves mysql to
  # load the prefix and exit 0, and a partial database would be reported as restored.
  gzip -t "${backup_directory_path}${backup_filepath}"
  bash -o pipefail -c 'zcat "$1" | docker exec -u0 -i mysql /bin/mysql --defaults-extra-file="$2" "$3"' \
    restore-mysql "${backup_directory_path}${backup_filepath}" "${mysql_config_inside_container}" "${mysql_restore_db}"
  rm -f "${mysql_config_file}"
  echo "MySQL backup is restored"
}

start_services() {
  # The production overlay makes nginx depend on profile-gated services (adminer=dbadmin,
  # updater=hooks), so a bare `docker compose <cmd>` errors at project load with
  # "service nginx depends on undefined service updater". Default to the full prod set;
  # an operator can override BEFORE running (e.g. a rehearsal that must not touch the live
  # DNS zone or Zabbix exports COMPOSE_PROFILES=dbadmin,hooks to skip certs+monitoring).
  # FTP is deliberately excluded and is started only through its manual profile.
  : "${COMPOSE_PROFILES:=certs,dbadmin,monitoring,hooks}"
  export COMPOSE_PROFILES
  echo "starting services with COMPOSE_PROFILES=${COMPOSE_PROFILES}"
  echo "pulling docker images..."
  docker compose pull >/dev/null 2>&1 || true
  echo "building docker images..."
  docker compose build >/dev/null 2>&1 || true
  echo "starting services..."
  docker compose up -d
  echo "docker setup is complete"
}

check_zabbix_hostname() {
  default_zabbix_hostname="favor-group.ru.docker"
  if [ "$(grep ZBX_HOSTNAME docker-compose.yml | cut -d '=' -f 2)" = "${default_zabbix_hostname}" ]; then
    echo "\
\n\nChange ZBX_HOSTNAME=${default_zabbix_hostname} to other hostname in docker-compose.yml \
and run 'docker-compose up -d' to prevent having two hosts sending data to same Zabbix hostname.
"
  fi
}

wait_for_apt_lock() {
  # Fresh Ubuntu cloud images run unattended-upgrades at boot, which holds the dpkg lock
  # for ~1-2 min. Without waiting, the first apt-get install (docker) fails and aborts the
  # whole unattended run. Poll until the lock clears (cap 5 min). No-op if fuser is absent.
  command -v fuser >/dev/null 2>&1 || return 0
  i=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    [ "${i}" -eq 0 ] && echo -n "waiting for dpkg lock (unattended-upgrades) to clear..."
    i=$((i + 1))
    if [ "${i}" -gt 60 ]; then echo " timeout after 300s" && exit 51; fi
    sleep 5
  done
  [ "${i}" -ne 0 ] && echo " cleared"
  return 0
}

### Main script logic

# Pre-setup
wait_for_apt_lock
install_host_packages
set_mtu_1450_if_not_set
install_docker_if_not_installed
install_docker_compose_if_not_installed
admin_user_setup
zabbix_setup
set_up_duplicity
setup_aws
memcached_user_setup
mysql_user_setup

# Backup restoration
backup_restore
start_services
restore_mysql
create_host_cronjob_if_not_exist
updater_access_setup

# Final recommendations
echo "\n\n=== Recommendations ==="
final_ip_check
check_second_backup_destination
check_zabbix_hostname
