#!/usr/bin/env bash
#
# network_health_check.sh
# Комплексная проверка стабильности сети и потери пакетов на сервере.
# Собирает все результаты в один каталог с логами — удобно приложить к тикету хостеру.
#
# Требуемые утилиты: mtr, iperf3, ping, traceroute, ss, ethtool, dig/nslookup, curl
# Установка недостающего (Debian/Ubuntu):
#   apt-get install -y mtr-tiny iperf3 iputils-ping traceroute iproute2 ethtool dnsutils curl
#
# Использование:
#   chmod +x network_health_check.sh
#   ./network_health_check.sh [цель1] [цель2] ...
#   Если цели не указаны — используются дефолтные публичные iperf3-сервера.

set -uo pipefail

# ---------- Настройки ----------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="./netcheck_${TIMESTAMP}"
mkdir -p "$OUTDIR"

PING_COUNT=1000                 # кол-во пакетов для ping/mtr (не 50!)
MTR_CYCLES=500
IPERF_DURATION=20               # секунд на один iperf3-прогон
UDP_BANDWIDTH="200M"            # для UDP-теста потерь

# Дефолтные цели, если не переданы аргументом
# (список публичных iperf3-серверов: https://iperf3serverlist.net)
DEFAULT_TARGETS=(
  "iperf.he.net"
  "ping.online.net"
  "speedtest.serverius.net"
)

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
[ -z "$IFACE" ] && IFACE="eth0"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ---------- 0. Общая информация ----------
{
  echo "=== Network Health Check ==="
  echo "Дата: $(date -u)"
  echo "Хост: $(hostname)"
  echo "Интерфейс: $IFACE"
  echo "Публичный IP: $(curl -s -m 5 ifconfig.me || echo 'н/д')"
  echo "Цели: ${TARGETS[*]}"
  echo "============================"
} | tee "$OUTDIR/00_info.txt"

# ---------- 1. Локальная диагностика хоста (дропы на самой NIC) ----------
log "1/7: Локальная диагностика интерфейса и стека TCP..."
{
  echo "--- ethtool -S $IFACE (ошибки/дропы на карте) ---"
  ethtool -S "$IFACE" 2>/dev/null | grep -iE 'drop|error|discard|overrun|fifo' || echo "ethtool недоступен или нет таких счётчиков"
  echo
  echo "--- netstat -s (ретрансмиты/дропы TCP на уровне ядра) ---"
  netstat -s 2>/dev/null | grep -iE 'retrans|drop|overflow|listen queue' || ss -s
  echo
  echo "--- dmesg (ошибки сетевой карты за последнее время) ---"
  dmesg 2>/dev/null | grep -iE 'eth|nic|link|drop' | tail -n 30 || echo "dmesg недоступен без root"
} > "$OUTDIR/01_local_nic_stack.txt"

# ---------- 2. Долгий ping (базовая потеря пакетов, без TCP-маскировки ретрансмитом) ----------
log "2/7: Долгий ping до всех целей ($PING_COUNT пакетов каждая, это займёт время)..."
for t in "${TARGETS[@]}"; do
  fname=$(echo "$t" | tr -c 'a-zA-Z0-9.' '_')
  log "  ping -> $t"
  ping -c "$PING_COUNT" -i 0.2 "$t" > "$OUTDIR/02_ping_${fname}.txt" 2>&1 &
done
wait

# ---------- 3. Долгий mtr (TCP, чтобы обойти возможный ICMP rate-limit) ----------
log "3/7: mtr (TCP режим, $MTR_CYCLES циклов) до всех целей..."
for t in "${TARGETS[@]}"; do
  fname=$(echo "$t" | tr -c 'a-zA-Z0-9.' '_')
  log "  mtr -> $t"
  mtr --tcp -P 443 -rw -c "$MTR_CYCLES" "$t" > "$OUTDIR/03_mtr_tcp_${fname}.txt" 2>&1
  # Дублируем в ICMP-режиме для сравнения (иногда TCP и ICMP по-разному режутся провайдером)
  mtr -rw -c "$MTR_CYCLES" "$t" > "$OUTDIR/03_mtr_icmp_${fname}.txt" 2>&1
done

# ---------- 4. iperf3: TCP в обе стороны ----------
log "4/7: iperf3 TCP (upload и download) по каждой цели..."
for t in "${TARGETS[@]}"; do
  fname=$(echo "$t" | tr -c 'a-zA-Z0-9.' '_')
  log "  iperf3 TCP upload -> $t"
  iperf3 -c "$t" -p 5201 -t "$IPERF_DURATION" -P 1 > "$OUTDIR/04_iperf3_tcp_upload_${fname}.txt" 2>&1
  log "  iperf3 TCP download (-R) -> $t"
  iperf3 -c "$t" -p 5201 -t "$IPERF_DURATION" -P 1 -R > "$OUTDIR/04_iperf3_tcp_download_${fname}.txt" 2>&1
done

# ---------- 5. iperf3: UDP — честный процент потерь без TCP-ретрансмита ----------
log "5/7: iperf3 UDP (прямой замер % потери пакетов)..."
for t in "${TARGETS[@]}"; do
  fname=$(echo "$t" | tr -c 'a-zA-Z0-9.' '_')
  log "  iperf3 UDP -> $t"
  iperf3 -c "$t" -p 5201 -u -b "$UDP_BANDWIDTH" -t "$IPERF_DURATION" > "$OUTDIR/05_iperf3_udp_${fname}.txt" 2>&1
done

# ---------- 6. Bufferbloat / задержка под нагрузкой ----------
# Проверяем, не растёт ли задержка в разы, когда канал загружен (проблема буферов провайдера/CPE)
log "6/7: Тест на bufferbloat (задержка под нагрузкой vs в покое)..."
{
  t="${TARGETS[0]}"
  echo "--- Задержка в покое (10 пакетов) ---"
  ping -c 10 "$t"
  echo
  echo "--- Задержка во время нагрузки iperf3 (параллельно) ---"
  iperf3 -c "$t" -p 5201 -t 15 > /dev/null 2>&1 &
  IPERF_PID=$!
  sleep 2
  ping -c 10 "$t"
  wait $IPERF_PID 2>/dev/null
} > "$OUTDIR/06_bufferbloat_test.txt" 2>&1

# ---------- 7. DNS resolution time (иногда проблема не в сети, а в DNS) ----------
log "7/7: Проверка времени резолва DNS..."
{
  for t in "${TARGETS[@]}"; do
    echo "--- dig $t ---"
    dig "$t" | grep -E "Query time|SERVER|ANSWER" 2>/dev/null || nslookup "$t"
    echo
  done
} > "$OUTDIR/07_dns_resolution.txt"

# ---------- Сводка ----------
log "Готово. Формирую сводку..."
{
  echo "=== СВОДКА ==="
  echo
  echo "--- Потери в ping ---"
  for f in "$OUTDIR"/02_ping_*.txt; do
    echo "$(basename "$f"):"
    grep -E "packet loss|rtt" "$f"
    echo
  done
  echo "--- Потери в mtr (последний hop = потери до цели) ---"
  for f in "$OUTDIR"/03_mtr_tcp_*.txt; do
    echo "$(basename "$f"):"
    tail -n 3 "$f"
    echo
  done
  echo "--- iperf3 TCP retransmits ---"
  for f in "$OUTDIR"/04_iperf3_tcp_*.txt; do
    echo "$(basename "$f"):"
    grep -E "sender|receiver" "$f"
    echo
  done
  echo "--- iperf3 UDP реальный % потерь ---"
  for f in "$OUTDIR"/05_iperf3_udp_*.txt; do
    echo "$(basename "$f"):"
    grep -iE "lost|datagrams" "$f"
    echo
  done
} > "$OUTDIR/99_SUMMARY.txt"

log "Все результаты сохранены в: $OUTDIR"
log "Для тикета — приложи $OUTDIR/99_SUMMARY.txt и, при необходимости, полные логи из этой папки."
tar czf "${OUTDIR}.tar.gz" "$OUTDIR"
log "Также создан архив: ${OUTDIR}.tar.gz"
