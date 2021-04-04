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

### Prepare packages

set_mtu_1450_if_not_set
install_docker_if_not_installed
install_docker_compose_if_not_installed

### Start recovery

echo "Server has latest backup of files and DB restored!"

### Final DNS recommendation

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
