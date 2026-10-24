#!/bin/sh
set -eu

show_help() {
    cat <<'EOF'
Maintain fail-closed Tailscale Exit Node forwarding into Proton VPN.

Usage:
    route-guard.sh [--help|-h]

Normally started automatically by Docker Compose in Gluetun's network namespace.

Environment:
    VPN_INTERFACE          VPN tunnel interface (default: tun0)
    ENABLE_IPV6_EGRESS     auto (default), true or false; always VPN-route guarded
    ROUTE_GUARD_INTERVAL   Reapply checks every N seconds (default: 15)

The script sends internet-bound Tailscale forwarding exclusively to the VPN
interface, performs masquerading, and restores tailnet return routes.
EOF
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
esac

VPN_INTERFACE="${VPN_INTERFACE:-tun0}"
ENABLE_IPV6_EGRESS="${ENABLE_IPV6_EGRESS:-auto}"
ROUTE_GUARD_INTERVAL="${ROUTE_GUARD_INTERVAL:-15}"

case "$ROUTE_GUARD_INTERVAL" in
    ''|*[!0-9]*|0)
        echo "Invalid ROUTE_GUARD_INTERVAL: $ROUTE_GUARD_INTERVAL" >&2
        exit 1
        ;;
esac
case "$VPN_INTERFACE" in
    ''|*[!a-zA-Z0-9_.-]*)
        echo "Invalid VPN_INTERFACE: $VPN_INTERFACE" >&2
        exit 1
        ;;
esac
case "$ENABLE_IPV6_EGRESS" in
    auto|true|false)
        ;;
    *)
        echo "Invalid ENABLE_IPV6_EGRESS: $ENABLE_IPV6_EGRESS (expected auto, true or false)" >&2
        exit 1
        ;;
esac

log() {
    printf 'route-guard: %s\n' "$*" >&2
}

ensure_append() {
    command_name="$1"
    chain="$2"
    shift 2
    "$command_name" -C "$chain" "$@" >/dev/null 2>&1 ||
        "$command_name" -A "$chain" "$@"
}

ensure_head() {
    command_name="$1"
    chain="$2"
    shift 2
    desired="-A $chain"
    for token in "$@"; do
        desired="$desired $token"
    done
    actual=$("$command_name" -S "$chain" 2>/dev/null | sed -n '2p')
    if [ "$actual" != "$desired" ]; then
        "$command_name" -D "$chain" "$@" >/dev/null 2>&1 || true
        "$command_name" -I "$chain" 1 "$@"
    fi
}

ensure_tailnet_route() {
    family="$1"
    subnet="$2"
    if ! ip "$family" rule show | grep -F "to $subnet lookup 52" >/dev/null 2>&1; then
        if ip "$family" rule add to "$subnet" table 52 priority 90; then
            log "Installed $family tailnet route to table 52: $subnet"
        else
            log "WARNING: Could not install $family tailnet return route"
        fi
    fi
}

ensure_nat() {
    tool="$1"
    subnet="$2"
    "$tool" -t nat -C POSTROUTING -s "$subnet" -o "$VPN_INTERFACE" -j MASQUERADE >/dev/null 2>&1 ||
        "$tool" -t nat -A POSTROUTING -s "$subnet" -o "$VPN_INTERFACE" -j MASQUERADE
}

vpn_ipv6_ready() {
    # Checking the interface and the selected route prevents accidentally
    # forwarding IPv6 through the Docker bridge instead of the VPN tunnel.
    ip -6 addr show dev "$VPN_INTERFACE" scope global 2>/dev/null |
        grep -q 'inet6 ' || return 1
    ip -6 route get 2606:4700:4700::1111 2>/dev/null |
        grep -Eq "(^|[[:space:]])dev[[:space:]]+$VPN_INTERFACE([[:space:]]|$)"
}

ensure_ipv4() {
    iptables -P FORWARD DROP
    iptables -N TS_PROTON_FWD 2>/dev/null || true
    if ! iptables -C TS_PROTON_FWD -i tailscale0 ! -o "$VPN_INTERFACE" -j DROP >/dev/null 2>&1; then
        iptables -I TS_PROTON_FWD 1 -i tailscale0 ! -o "$VPN_INTERFACE" -j DROP
    fi
    ensure_append iptables TS_PROTON_FWD -i tailscale0 -o "$VPN_INTERFACE" -j ACCEPT
    ensure_append iptables TS_PROTON_FWD -i "$VPN_INTERFACE" -o tailscale0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ensure_head iptables FORWARD -j TS_PROTON_FWD
    ensure_head iptables INPUT -i tailscale0 -j ACCEPT
    ensure_nat iptables 100.64.0.0/10
    ensure_tailnet_route -4 100.64.0.0/10
}

ensure_ipv6() {
    if ! command -v ip6tables >/dev/null 2>&1; then
        log "WARNING: ip6tables unavailable. IPv6 forwarding is not configured."
        return
    fi
    ip6tables -P FORWARD DROP || return
    ip6tables -N TS_PROTON_FWD 2>/dev/null || true

    if [ "$ENABLE_IPV6_EGRESS" = "false" ] || ! vpn_ipv6_ready; then
        # Fail closed if disabled or if the selected route is not through
        # an IPv6-capable VPN tunnel. This is checked every watchdog cycle.
        ensure_head ip6tables FORWARD -i tailscale0 -j DROP
        ensure_head ip6tables INPUT -i tailscale0 -j ACCEPT
        return
    fi

    ip6tables -D FORWARD -i tailscale0 -j DROP >/dev/null 2>&1 || true
    if ! ip6tables -C TS_PROTON_FWD -i tailscale0 ! -o "$VPN_INTERFACE" -j DROP >/dev/null 2>&1; then
        ip6tables -I TS_PROTON_FWD 1 -i tailscale0 ! -o "$VPN_INTERFACE" -j DROP
    fi
    ensure_append ip6tables TS_PROTON_FWD -i tailscale0 -o "$VPN_INTERFACE" -j ACCEPT
    ensure_append ip6tables TS_PROTON_FWD -i "$VPN_INTERFACE" -o tailscale0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ensure_head ip6tables FORWARD -j TS_PROTON_FWD
    ensure_head ip6tables INPUT -i tailscale0 -j ACCEPT
    ensure_nat ip6tables fd7a:115c:a1e0::/48
    ensure_tailnet_route -6 fd7a:115c:a1e0::/48
}

log "Starting; interface=$VPN_INTERFACE, IPv6 egress=$ENABLE_IPV6_EGRESS"
while :; do
    if ip link show tailscale0 >/dev/null 2>&1; then
        ensure_ipv4 || log "WARNING: IPv4 route/firewall synchronization failed"
        ensure_ipv6 || log "WARNING: IPv6 route/firewall synchronization failed"
    fi
    sleep "$ROUTE_GUARD_INTERVAL"
done
