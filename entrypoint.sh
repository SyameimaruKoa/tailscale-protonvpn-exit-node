#!/bin/sh
set -eu

# Tailscale Exit Node with Proton VPN
# Routing, NAT and watchdog are handled here, as in a two-container gateway design.

show_help() {
    cat <<'EOF'
Usage: entrypoint.sh [-h|--help]

Docker Compose starts this script automatically. It:
  - Restores an existing Tailscale identity without requiring a valid auth key.
  - Applies forwarding, NAT, MSS clamping and Tailscale return routes.
  - Reapplies these rules every 15 seconds if Gluetun changes its firewall.

Environment:
  TS_AUTHKEY       Required only on first Tailscale registration.
  TS_STATE_DIR     Persistent Tailscale state directory.
  TS_HOSTNAME      Optional name, otherwise proton--<host hostname>.
  VPN_TYPE         wireguard (default) or openvpn.
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
        export TS_HOSTNAME="proton--$host_name"
    else
        export TS_HOSTNAME="proton--docker"
    fi
fi

state_file="${TS_STATE_DIR:-/var/lib/tailscale}/tailscaled.state"
if [ -s "$state_file" ]; then
    echo "Tailscale state found; saved authentication will be reused."
    unset TS_AUTHKEY
elif [ -z "${TS_AUTHKEY:-}" ]; then
    echo "ERROR: TS_AUTHKEY is required for the first registration." >&2
    exit 1
fi

# Gluetun uses wg0 for WireGuard and tun0 for OpenVPN.
case "${VPN_TYPE:-wireguard}" in
    wireguard)
        vpn_interface=wg0
        ;;
    openvpn)
        vpn_interface=tun0
        ;;
    *)
        echo "ERROR: unsupported VPN_TYPE: $VPN_TYPE" >&2
        exit 1
        ;;
esac

if [ -x /usr/sbin/iptables-nft ]; then
    ln -sf /usr/sbin/iptables-nft /usr/sbin/iptables
fi
if [ -x /usr/sbin/ip6tables-nft ]; then
    ln -sf /usr/sbin/ip6tables-nft /usr/sbin/ip6tables
fi

ensure_rule() {
    tool="$1"
    chain="$2"
    shift 2
    "$tool" -C "$chain" "$@" >/dev/null 2>&1 ||
        "$tool" -A "$chain" "$@"
}

ensure_first_rule() {
    tool="$1"
    chain="$2"
    shift 2
    expected="-A $chain $*"
    current=$("$tool" -S "$chain" | sed -n '/^-A /{p;q;}')
    if [ "$current" != "$expected" ]; then
        "$tool" -D "$chain" "$@" >/dev/null 2>&1 || true
        "$tool" -I "$chain" 1 "$@"
    fi
}

apply_forwarding() {
    tool="$1"
    family="$2"
    subnet="$3"

    "$tool" -P FORWARD DROP
    "$tool" -N TS_PROTON_FWD 2>/dev/null || true

    # A forwarded Exit Node packet may leave ONLY via the Proton VPN interface.
    ensure_rule "$tool" TS_PROTON_FWD -i tailscale0 ! -o "$vpn_interface" -j DROP
    ensure_rule "$tool" TS_PROTON_FWD -i tailscale0 -o "$vpn_interface" -j ACCEPT
    ensure_rule "$tool" TS_PROTON_FWD -i "$vpn_interface" -o tailscale0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ensure_first_rule "$tool" FORWARD -j TS_PROTON_FWD
    ensure_first_rule "$tool" INPUT -i tailscale0 -j ACCEPT

    if ! "$tool" -t nat -C POSTROUTING -s "$subnet" -o "$vpn_interface" -j MASQUERADE 2>/dev/null; then
        "$tool" -t nat -A POSTROUTING -s "$subnet" -o "$vpn_interface" -j MASQUERADE
    fi
    if ! "$tool" -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "$vpn_interface" -j TCPMSS --set-mss 1120 2>/dev/null; then
        "$tool" -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "$vpn_interface" -j TCPMSS --set-mss 1120
    fi

    # Gluetun's policy rules outrank Tailscale's table 52 unless repaired.
    # Direct tailnet replies back into Tailscale instead of the VPN tunnel.
    if ! ip "$family" rule show | grep -F "to $subnet lookup 52" >/dev/null 2>&1; then
        ip "$family" rule add to "$subnet" table 52 priority 90
    fi
}

apply_routes() {
    apply_forwarding iptables -4 100.64.0.0/10
    if command -v ip6tables >/dev/null 2>&1; then
        apply_forwarding ip6tables -6 fd7a:115c:a1e0::/48
    fi
}

# Install forwarding restrictions before starting Tailscale.
apply_routes || echo "WARNING: Initial route setup failed; watchdog will retry." >&2

watchdog() {
    previous_up=1
    while true; do
        sleep 15
        apply_routes || echo "WARNING: Could not reapply forwarding rules." >&2

        if ip link show "$vpn_interface" >/dev/null 2>&1; then
            if [ "$previous_up" -eq 0 ]; then
                echo "Proton VPN interface restored; notifying Tailscale."
                if pid=$(pidof tailscaled 2>/dev/null); then
                    kill -HUP "$pid" 2>/dev/null || true
                fi
            fi
            previous_up=1
        else
            previous_up=0
        fi
    done
}

watchdog &
echo "Starting Tailscale Exit Node via Proton VPN ($vpn_interface)"
exec /usr/local/bin/containerboot
