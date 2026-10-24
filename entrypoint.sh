#!/bin/sh
set -eu

show_help() {
    cat <<'EOF'
Tailscale container entrypoint for the Proton VPN exit node.

Usage:
    entrypoint.sh [--help|-h]

Normally started automatically by Docker Compose.
It restores the saved Tailscale identity, sets a default hostname, and launches
the official Tailscale containerboot process.
EOF
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
esac

if [ -z "${TS_HOSTNAME:-}" ]; then
    if [ -s /host_hostname ]; then
        host_name=$(tr -d '\r\n' < /host_hostname)
        export TS_HOSTNAME="proton--${host_name}"
    else
        export TS_HOSTNAME="proton--docker"
    fi
fi
printf 'Tailscale hostname: %s\n' "$TS_HOSTNAME"

state_file="${TS_STATE_DIR:-/var/lib/tailscale}/tailscaled.state"
if [ -s "$state_file" ]; then
    echo "Existing Tailscale state detected; ignoring expired TS_AUTHKEY."
    unset TS_AUTHKEY
elif [ -z "${TS_AUTHKEY:-}" ]; then
    echo "ERROR: set TS_AUTHKEY for first-time registration." >&2
    exit 1
fi

# Use iptables-nft where it is available for compatibility with Gluetun.
if [ -x /usr/sbin/iptables-nft ]; then
    ln -sf /usr/sbin/iptables-nft /usr/sbin/iptables
fi
if [ -x /usr/sbin/ip6tables-nft ]; then
    ln -sf /usr/sbin/ip6tables-nft /usr/sbin/ip6tables
fi

exec /usr/local/bin/containerboot
