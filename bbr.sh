#!/bin/bash

set -e

echo "==> Updating system packages"
apt update
apt -y upgrade

echo "==> Installing linux-image-amd64"
apt -y install linux-image-amd64

SYSCTL_CONF="/etc/sysctl.conf"

echo "==> Configuring BBR in $SYSCTL_CONF"

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

add_sysctl_if_missing "net.core.default_qdisc" "fq"
add_sysctl_if_missing "net.ipv4.tcp_congestion_control" "bbr"

echo "==> Creating /etc/sysctl.d/99-proxy.conf"

cat > /etc/sysctl.d/99-proxy.conf <<EOF
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60
EOF

echo "==> Applying sysctl settings"
sysctl --system

echo "==> Done."
echo "⚠️  Reboot is REQUIRED to boot into the new kernel and fully enable BBR."
