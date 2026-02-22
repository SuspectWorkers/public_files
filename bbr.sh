#!/bin/bash

set -e

### ==============================
### SWAP MANAGEMENT
### ==============================

echo "==> Checking swap status..."

SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')

if [ "$SWAP_TOTAL" -gt 0 ]; then
    echo "Swap is ENABLED. Size: ${SWAP_TOTAL}MB"
    echo "1) Change swap size"
    echo "2) Disable swap"
    echo "3) Keep as is"
    read -p "Choose option [1-3]: " swap_choice

    if [ "$swap_choice" = "1" ]; then
        read -p "Enter new swap size in MB (e.g. 1024): " NEWSWAP
        swapoff -a || true
        rm -f /swapfile
        fallocate -l ${NEWSWAP}M /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' > /etc/fstab
        echo "Swap resized to ${NEWSWAP}MB"

    elif [ "$swap_choice" = "2" ]; then
        swapoff -a || true
        rm -f /swapfile
        sed -i '/swapfile/d' /etc/fstab
        echo "Swap disabled"

    else
        echo "Keeping current swap"
    fi

else
    echo "Swap is DISABLED."
    read -p "Do you want to create and enable swap? (y/n): " create_swap

    if [[ "$create_swap" =~ ^[Yy]$ ]]; then
        read -p "Enter swap size in MB (e.g. 1024): " NEWSWAP
        fallocate -l ${NEWSWAP}M /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' > /etc/fstab
        echo "Swap enabled with size ${NEWSWAP}MB"
    fi
fi

echo
echo "Current swap status:"
free -m
echo

### ==============================
### CONNTRACK SIZE SELECTION
### ==============================

echo "==> Select conntrack size:"
echo "1) 262144  (recommended for 1GB RAM)"
echo "2) 524288  (medium load)"
echo "3) 1048576 (high load, needs swap / 2GB+ RAM)"
read -p "Enter option [1-3]: " choice

case $choice in
    1) CONNTRACK_SIZE=262144 ;;
    2) CONNTRACK_SIZE=524288 ;;
    3) CONNTRACK_SIZE=1048576 ;;
    *) echo "Invalid option"; exit 1 ;;
esac

echo "Using conntrack size: $CONNTRACK_SIZE"

### ==============================
### SYSTEM UPDATE
### ==============================

echo "==> Updating system packages"
apt update

echo "==> Installing linux-image-amd64"
apt -y install linux-image-amd64

SYSCTL_CONF="/etc/sysctl.conf"

add_sysctl_if_missing() {
    local key="$1"
    local value="$2"

    if ! grep -q "^${key}=" "$SYSCTL_CONF"; then
        echo "${key}=${value}" >> "$SYSCTL_CONF"
        echo "  added: ${key}=${value}"
    else
        echo "  exists: ${key}"
    fi
}

echo "==> Configuring BBR"
add_sysctl_if_missing "net.core.default_qdisc" "fq"
add_sysctl_if_missing "net.ipv4.tcp_congestion_control" "bbr"

echo "==> Creating /etc/sysctl.d/99-proxy.conf"

cat > /etc/sysctl.d/99-proxy.conf <<EOF
net.netfilter.nf_conntrack_max = ${CONNTRACK_SIZE}
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60
EOF

echo "==> Ensuring nf_conntrack loads at boot"
echo nf_conntrack > /etc/modules-load.d/conntrack.conf

### ==============================
### AUTO TCP TUNING (RAM + SWAP)
### ==============================

echo "==> Detecting memory..."

RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
SWAP_MB=$(free -m | awk '/^Swap:/ {print $2}')

TOTAL_MB=$((RAM_MB + SWAP_MB))

echo "RAM:  ${RAM_MB}MB"
echo "Swap: ${SWAP_MB}MB"
echo "Total usable memory: ${TOTAL_MB}MB"

# Формула: 32 orphan на 1MB RAM
ORPHAN_LIMIT=$((RAM_MB * 32))

# Ограничения
if [ "$ORPHAN_LIMIT" -gt 262144 ]; then
    ORPHAN_LIMIT=262144
fi

if [ "$ORPHAN_LIMIT" -lt 16384 ]; then
    ORPHAN_LIMIT=16384
fi

# TIME_WAIT делаем чуть больше orphan
TW_BUCKETS=$((ORPHAN_LIMIT * 2))

echo "Calculated tcp_max_orphans: $ORPHAN_LIMIT"
echo "Calculated tcp_max_tw_buckets: $TW_BUCKETS"

SYSCTL_FILE="/etc/sysctl.d/99-proxy.conf"

add_or_update() {
    KEY=$1
    VALUE=$2
    if grep -q "^$KEY" "$SYSCTL_FILE" 2>/dev/null; then
        sed -i "s|^$KEY.*|$KEY = $VALUE|" "$SYSCTL_FILE"
    else
        echo "$KEY = $VALUE" >> "$SYSCTL_FILE"
    fi
}

echo "==> Applying TCP optimizations"

add_or_update net.ipv4.tcp_max_orphans $ORPHAN_LIMIT
add_or_update net.ipv4.tcp_max_tw_buckets $TW_BUCKETS
add_or_update net.ipv4.tcp_fin_timeout 15
add_or_update net.ipv4.tcp_tw_reuse 1
add_or_update net.core.somaxconn 65535
add_or_update net.ipv4.tcp_max_syn_backlog 262144

modprobe nf_conntrack || true
systemctl restart systemd-sysctl || true

echo "==> Applying sysctl settings"
sysctl --system

echo
echo "==> Verification"
lsmod | grep conntrack || true
cat /proc/sys/net/netfilter/nf_conntrack_max || true
cat /proc/sys/net/ipv4/tcp_max_orphans
cat /proc/sys/net/ipv4/tcp_max_tw_buckets

echo
echo "==> Done."
echo "⚠️  Reboot is REQUIRED to boot into the new kernel and fully enable BBR."
