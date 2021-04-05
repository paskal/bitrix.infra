#!/usr/bin/env sh
set -e -u

# This script sets up clean Ubuntu host machine for bitrix.infra
# and recovers site files and the DB content from the backup.

domain="favor-group.ru"

### Pre-checks

# Check the current running folder
[ -d "./scripts" ] || (echo "./scripts locations is absent, please run from parent directory of this script" && exit 45)

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo, 'sudo $0'"
  exit
fi

### Functions

install_docker_if_not_installed() {
  command -v docker >/dev/null && return
  echo "docker is installing..."
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
  command -v docker-compose >/dev/null && return
  echo "docker-compose is installing..."
  curl -sL "https://github.com/docker/compose/releases/download/1.28.6/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  echo "docker-compose is installed"
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
  [ -f "/etc/cron.d/bitrix_infra" ] && return
  echo "creating /etc/cron.d/bitrix_infra from ./config/cron/host.cron..."
  ln -s "${PWD}/config/cron/host.cron" /etc/cron.d/bitrix_infra
  echo "created /etc/cron.d/bitrix_infra"
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

set_up_duplicity() {
  command -v duplicity >/dev/null && return
  echo "installing duplicity for backups..."
  apt-get -y install duplicity >/dev/null
  echo "done setting up duplicity"
}

final_ip_check() {
  server_ip=$(dig +short myip.opendns.com @resolver1.opendns.com)
  site_a_entry=$(dig +short ${domain})

  if [ "${server_ip}" != "${site_a_entry}" ]; then
    echo "Current IP for ${domain} is: ${site_a_entry}"
    echo "This machine external IP (best guess): ${server_ip}"

    echo "\
Please ensure DNS A entries are pointing to this machine external IP: \
https://connect.yandex.ru/portal/services/webmaster/resources/${domain} \
"
  else
    echo "Server IP (${server_ip}) matches A entry for ${domain}, by now site should be working at https://${domain}"
  fi
}

### Main script logic

# Pre-setup
set_mtu_1450_if_not_set
install_docker_if_not_installed
install_docker_compose_if_not_installed
zabbix_setup
set_up_duplicity

# Backup restoration
create_host_cronjob_if_not_exist

echo "Server has latest backup of files and DB restored!"

# Final DNS recommendation
final_ip_check
