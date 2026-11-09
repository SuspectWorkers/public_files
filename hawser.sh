#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hawser (Edge mode) installer for Debian
# Docs: https://github.com/Finsys/hawser
#
# Usage:
#   sudo bash install-hawser-edge.sh
#
# Если GitHub не отдаёт архив (504) - скачайте hawser_<ver>_linux_amd64.tar.gz
# на другой машине, скопируйте на сервер и запустите с HAWSER_TARBALL=/путь/к/архиву
# (или задайте зеркало через HAWSER_DOWNLOAD_URL).
#
# Non-interactive (e.g. provisioning/CI):
#   sudo HAWSER_SERVER_URL="wss://dockhand.example.com/api/hawser/connect" \
#        HAWSER_TOKEN="xxxxx" bash install-hawser-edge.sh
# ---------------------------------------------------------------------------
set -euo pipefail

HAWSER_HOME="/var/lib/hawser"
CONFIG_DIR="/etc/hawser"
CONFIG_FILE="${CONFIG_DIR}/config"
STACKS_DIR="/data/stacks"
INSTALL_DIR="/usr/local/bin"
VERSION="${HAWSER_VERSION:-latest}"

# --- must be root ------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (e.g. sudo bash $0)" >&2
  exit 1
fi

# --- must be Debian ------------------------------------------------------------
if [[ ! -f /etc/debian_version ]]; then
  echo "This script targets Debian; /etc/debian_version not found." >&2
  exit 1
fi

echo "==> Installing prerequisites"
apt-get update -qq
apt-get install -y -qq curl tar ca-certificates >/dev/null

# --- collect Edge mode connection details -------------------------------------
DOCKHAND_SERVER_URL="${HAWSER_SERVER_URL:-}"
TOKEN="${HAWSER_TOKEN:-}"

if [[ -z "$DOCKHAND_SERVER_URL" ]]; then
  read -rp "Dockhand server URL (wss://<host>/api/hawser/connect): " DOCKHAND_SERVER_URL
fi
if [[ -z "$TOKEN" ]]; then
  read -rsp "Agent token (from Dockhand -> Settings -> Environments): " TOKEN
  echo
fi
if [[ -z "$DOCKHAND_SERVER_URL" || -z "$TOKEN" ]]; then
  echo "Both server URL and token are required for Edge mode." >&2
  exit 1
fi

# --- arch / os detection -------------------------------------------------------
OS="linux"
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l|armv7|arm) ARCH="arm" ;;
  *) echo "Unsupported architecture: $ARCH_RAW" >&2; exit 1 ;;
esac

# curl с повторами: GitHub иногда отдаёт временные 502/503/504
CURL=(curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 20)

echo "==> Fetching Hawser (${OS}/${ARCH}, version: ${VERSION})"
if [[ "$VERSION" == "latest" ]]; then
  # Сначала через API, при сбое/лимите - через редирект releases/latest
  LATEST_VERSION=$("${CURL[@]}" "https://api.github.com/repos/Finsys/hawser/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/' || true)
  if [[ -z "$LATEST_VERSION" ]]; then
    LATEST_VERSION=$("${CURL[@]}" -o /dev/null -w '%{url_effective}' "https://github.com/Finsys/hawser/releases/latest" \
      | sed -E 's|.*/tag/v?||' || true)
  fi
  if [[ -z "$LATEST_VERSION" ]]; then
    echo "Could not determine latest version" >&2
    exit 1
  fi
  echo "    Latest version: $LATEST_VERSION"
  DOWNLOAD_URL="https://github.com/Finsys/hawser/releases/download/v${LATEST_VERSION}/hawser_${LATEST_VERSION}_${OS}_${ARCH}.tar.gz"
else
  V="${VERSION#v}"
  DOWNLOAD_URL="https://github.com/Finsys/hawser/releases/download/v${V}/hawser_${V}_${OS}_${ARCH}.tar.gz"
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
if [[ -n "${HAWSER_TARBALL:-}" ]]; then
  # Готовый архив, скачанный вручную (если GitHub недоступен с этого сервера)
  [[ -f "$HAWSER_TARBALL" ]] || { echo "Файл не найден: $HAWSER_TARBALL" >&2; exit 1; }
  echo "    Используется локальный архив: $HAWSER_TARBALL"
  cp "$HAWSER_TARBALL" "$TMP_DIR/hawser.tar.gz"
else
  # HAWSER_DOWNLOAD_URL - свой URL/зеркало вместо github.com
  "${CURL[@]}" "${HAWSER_DOWNLOAD_URL:-$DOWNLOAD_URL}" -o "$TMP_DIR/hawser.tar.gz"
fi
tar -xzf "$TMP_DIR/hawser.tar.gz" -C "$TMP_DIR"
install -m 755 "$TMP_DIR/hawser" "${INSTALL_DIR}/hawser"

# --- directories ---------------------------------------------------------------
echo "==> Creating directories"
mkdir -p "$CONFIG_DIR"
mkdir -p "$STACKS_DIR"
mkdir -p "${HAWSER_HOME}/.docker"

# --- config file (Edge mode) ----------------------------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
  BACKUP="${CONFIG_FILE}.bak.$(date +%s)"
  echo "==> Existing config found, backing up to ${BACKUP}"
  cp "$CONFIG_FILE" "$BACKUP"
fi

echo "==> Writing ${CONFIG_FILE}"
cat > "$CONFIG_FILE" <<EOF
# Hawser Configuration - Edge Mode
# See https://github.com/Finsys/hawser for documentation
DOCKER_SOCKET=/var/run/docker.sock
DOCKHAND_SERVER_URL=${DOCKHAND_SERVER_URL}
TOKEN=${TOKEN}
BIND_ADDRESS=127.0.0.1
EOF
chmod 600 "$CONFIG_FILE"

# --- systemd unit ----------------------------------------------------------------
echo "==> Installing systemd service"
cat > /etc/systemd/system/hawser.service <<EOF
[Unit]
Description=Hawser - Remote Docker Agent for Dockhand
Documentation=https://github.com/Finsys/hawser
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/hawser
Restart=always
RestartSec=10
EnvironmentFile=${CONFIG_FILE}
Environment=DOCKER_CONFIG=${HAWSER_HOME}/.docker
Environment=HOME=${HAWSER_HOME}

# Security hardening
NoNewPrivileges=false
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/run/docker.sock ${STACKS_DIR} ${HAWSER_HOME} /tmp

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hawser

echo ""
echo "Hawser installed and running in Edge mode."
echo "  Config:  ${CONFIG_FILE}"
echo "  Status:  systemctl status hawser"
echo "  Logs:    journalctl -u hawser -f"
