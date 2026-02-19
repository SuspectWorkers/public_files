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

modprobe nf_conntrack || true
systemctl restart systemd-sysctl || true

echo "==> Applying sysctl settings"
sysctl --system

echo
echo "==> Verification"
lsmod | grep conntrack || true
cat /proc/sys/net/netfilter/nf_conntrack_max || true

echo
echo "==> Done."
echo "⚠️  Reboot is REQUIRED to boot into the new kernel and fully enable BBR."
