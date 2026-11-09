#!/bin/bash
set -e

# Detect OS (debian / ubuntu, including derivatives)
. /etc/os-release
case "${ID}" in
    debian|ubuntu) DOCKER_OS="${ID}" ;;
    *)
        case "${ID_LIKE}" in
            *ubuntu*) DOCKER_OS="ubuntu" ;;
            *debian*) DOCKER_OS="debian" ;;
            *) echo "Unsupported OS: ${ID}"; exit 1 ;;
        esac
        ;;
esac

# Ubuntu derivatives (e.g. Linux Mint) expose the Ubuntu codename here
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

echo "==> Detected ${PRETTY_NAME:-$ID}: using Docker repo for ${DOCKER_OS} (${CODENAME})"

apt-get update
apt-get install ca-certificates curl -y
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${DOCKER_OS}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_OS} \
  ${CODENAME} stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
