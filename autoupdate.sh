#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Автообновление системы (ядро + Docker) и Hawser для Debian/Ubuntu.
#
#  - ставит и настраивает unattended-upgrades под текущую ОС (Debian / Ubuntu
#    и производные); ядро и docker-ce обновляются через apt;
#  - включает Docker live-restore (контейнеры переживают обновление docker);
#  - создаёт /usr/local/sbin/hawser-update.sh + systemd service + timer;
#  - автоперезагрузка после обновления ядра (по умолчанию в 04:00).
#
# Запуск:
#   bash -c "$(curl -L https://raw.githubusercontent.com/SuspectWorkers/public_files/refs/heads/main/autoupdate.sh)"
#
# Переменные окружения (необязательно):
#   AUTO_REBOOT=true|false     перезагрузка при необходимости (по умолчанию true)
#   REBOOT_TIME=04:00          время перезагрузки
#   HAWSER_UPDATE_TIME=03:30   время запуска обновления Hawser
#   HAWSER_UPDATE_DELAY=30m    случайная задержка таймера Hawser
# ---------------------------------------------------------------------------
set -euo pipefail

AUTO_REBOOT="${AUTO_REBOOT:-true}"
REBOOT_TIME="${REBOOT_TIME:-04:00}"
HAWSER_UPDATE_TIME="${HAWSER_UPDATE_TIME:-03:30}"
HAWSER_UPDATE_DELAY="${HAWSER_UPDATE_DELAY:-30m}"

UPDATER=/usr/local/sbin/hawser-update.sh

if [[ $EUID -ne 0 ]]; then
  echo "Запустите от root (sudo bash $0)" >&2
  exit 1
fi

# --- определение ОС ---------------------------------------------------------
. /etc/os-release
case "${ID}" in
  debian|ubuntu) OS_FAMILY="${ID}" ;;
  *)
    case "${ID_LIKE:-}" in
      *ubuntu*) OS_FAMILY="ubuntu" ;;
      *debian*) OS_FAMILY="debian" ;;
      *) echo "Unsupported OS: ${ID}" >&2; exit 1 ;;
    esac
    ;;
esac
echo "==> ${PRETTY_NAME:-$ID}: профиль ${OS_FAMILY}"

# --- unattended-upgrades -----------------------------------------------------
echo "==> Установка unattended-upgrades"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq unattended-upgrades apt-listchanges ca-certificates curl tar >/dev/null

if [[ "$OS_FAMILY" == "ubuntu" ]]; then
  ORIGINS='    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";'
else
  ORIGINS='    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-updates";'
fi

# Docker-репозиторий добавляем, только если он подключён
if grep -rqs "download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  ORIGINS="${ORIGINS}
    \"origin=Docker,label=Docker CE\";"
  echo "    Docker-репозиторий найден: docker-ce будет обновляться автоматически"
fi

echo "==> Запись /etc/apt/apt.conf.d/52autoupdate-custom"
cat > /etc/apt/apt.conf.d/52autoupdate-custom <<EOF
// Создано autoupdate.sh
Unattended-Upgrade::Origins-Pattern {
${ORIGINS}
};

// Ядро применяется только после перезагрузки
Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

# --- Docker live-restore -----------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  DAEMON_JSON=/etc/docker/daemon.json
  mkdir -p /etc/docker
  if [[ ! -s "$DAEMON_JSON" ]]; then
    echo "==> Docker: включаю live-restore"
    echo '{ "live-restore": true }' > "$DAEMON_JSON"
    systemctl reload docker 2>/dev/null || true
  elif grep -q '"live-restore"' "$DAEMON_JSON"; then
    echo "==> Docker: live-restore уже задан в ${DAEMON_JSON}"
  elif command -v python3 >/dev/null 2>&1; then
    echo "==> Docker: добавляю live-restore в существующий ${DAEMON_JSON}"
    cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)"
    python3 - "$DAEMON_JSON" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["live-restore"] = True
json.dump(d, open(p, "w"), indent=2)
PY
    systemctl reload docker 2>/dev/null || true
  else
    echo "==> Docker: добавьте \"live-restore\": true в ${DAEMON_JSON} вручную (нет python3)"
  fi
fi

# --- Hawser: скрипт обновления + systemd ------------------------------------
if [[ -x /usr/local/bin/hawser || -f /etc/systemd/system/hawser.service ]]; then
  echo "==> Hawser найден: настраиваю автообновление"

  mkdir -p /var/lib/hawser
  cat > "$UPDATER" <<'EOF'
#!/usr/bin/env bash
# Обновляет Hawser до последней версии из GitHub с откатом при неудаче.
set -euo pipefail

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l|armv7|arm) ARCH=arm ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

BIN=/usr/local/bin/hawser
STATE=/var/lib/hawser/version

CURL=(curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 20)

# Версия: сначала через API, при сбое/лимите - через редирект releases/latest
LATEST=$("${CURL[@]}" "https://api.github.com/repos/Finsys/hawser/releases/latest" 2>/dev/null \
  | grep '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/' || true)
if [[ -z "$LATEST" ]]; then
  LATEST=$("${CURL[@]}" -o /dev/null -w '%{url_effective}' "https://github.com/Finsys/hawser/releases/latest" \
    | sed -E 's|.*/tag/v?||' || true)
fi
[[ -n "$LATEST" ]] || { echo "Не удалось определить последнюю версию" >&2; exit 1; }

CURRENT=$(cat "$STATE" 2>/dev/null || true)
if [[ "$CURRENT" == "$LATEST" ]]; then
  echo "Hawser актуален (${LATEST})"
  exit 0
fi
echo "Обновление Hawser: ${CURRENT:-неизвестно} -> ${LATEST}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"${CURL[@]}" "https://github.com/Finsys/hawser/releases/download/v${LATEST}/hawser_${LATEST}_linux_${ARCH}.tar.gz" -o "$TMP/hawser.tar.gz"
tar -xzf "$TMP/hawser.tar.gz" -C "$TMP"
[[ -f "$TMP/hawser" ]] || { echo "В архиве нет бинарника hawser" >&2; exit 1; }

[[ -f "$BIN" ]] && cp "$BIN" "${BIN}.prev"
install -m 755 "$TMP/hawser" "$BIN"
systemctl restart hawser
sleep 5

if systemctl is-active --quiet hawser; then
  echo "$LATEST" > "$STATE"
  echo "Hawser обновлён до ${LATEST}"
else
  echo "Новая версия не стартует, откат" >&2
  if [[ -f "${BIN}.prev" ]]; then
    install -m 755 "${BIN}.prev" "$BIN"
    systemctl restart hawser || true
  fi
  exit 1
fi
EOF
  chmod 755 "$UPDATER"

  cat > /etc/systemd/system/hawser-update.service <<EOF
[Unit]
Description=Update Hawser agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${UPDATER}
EOF

  cat > /etc/systemd/system/hawser-update.timer <<EOF
[Unit]
Description=Daily Hawser update

[Timer]
OnCalendar=*-*-* ${HAWSER_UPDATE_TIME}
RandomizedDelaySec=${HAWSER_UPDATE_DELAY}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now hawser-update.timer
  echo "    Первый запуск проверки..."
  systemctl start hawser-update.service || echo "    (проверьте: journalctl -u hawser-update)"
else
  echo "==> Hawser не найден, пропускаю (сначала запустите hawser.sh, затем повторите этот скрипт)"
fi

# --- проверка ---------------------------------------------------------------
echo
echo "==> Проверка unattended-upgrades (dry-run)"
unattended-upgrade --dry-run 2>&1 | tail -n 5 || true

echo
echo "Готово."
echo "  Обновления ОС/ядра/Docker: unattended-upgrades (авторебут: ${AUTO_REBOOT}, ${REBOOT_TIME})"
echo "  Лог apt:        /var/log/unattended-upgrades/unattended-upgrades.log"
echo "  Таймеры:        systemctl list-timers 'apt-daily*' hawser-update.timer"
echo "  Лог Hawser:     journalctl -u hawser-update"
