#!/bin/sh
set -eu

# ============================================================
# Tailscale + Proton VPN Exit Node エントリーポイント
# ============================================================

show_help() {
    cat <<'EOF'
Usage: entrypoint.sh [-h|--help]

Starts the Tailscale container for the Proton VPN Exit Node.
The setup reuses the saved Tailscale authentication state, configures
IPv4/IPv6 routing, NAT, MSS clamping and gateway-recovery watchdog.
Tailscale's own marked packets use the Docker gateway; Exit Node
forwarded traffic uses the Proton VPN gateway.

Variables:
    TS_AUTHKEY    Initial Tailscale authentication key.
    TS_STATE_DIR  Persistent Tailscale state directory.
    PROTON_GW     VPN gateway IPv4 (default 10.1.0.2).
    PROTON_GW6    VPN gateway IPv6 (default fd6a:204b:1e8d::2).
EOF
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
esac


# ------------------------------------------------------------
# 1. ホスト名の設定
# ------------------------------------------------------------
if [ -s /host_hostname ]; then
    host_name=$(tr -d '\r\n' < /host_hostname)
    export TS_HOSTNAME="proton--$host_name"
else
    export TS_HOSTNAME="proton--docker"
fi
echo "Hostname set to: $TS_HOSTNAME"

# TailscaleのインターフェースMTUを少し下げる（IPv6の最小値1280ギリギリを攻める）
export TS_DEBUG_MTU=1280

# ------------------------------------------------------------
# 2. Tailscale認証キーのスマート処理
#    - 既に認証済み（状態が保存されている）場合はTS_AUTHKEYを無視する
#    - これによりAuth Keyが期限切れでも再起動できる
# ------------------------------------------------------------
TS_STATE_FILE="${TS_STATE_DIR}/tailscaled.state"

if [ -f "$TS_STATE_FILE" ] && [ -s "$TS_STATE_FILE" ]; then
    echo "Tailscale state found at $TS_STATE_FILE — skipping auth key (already registered)."
    unset TS_AUTHKEY
else
    if [ -z "${TS_AUTHKEY:-}" ]; then
        echo "ERROR: No Tailscale state found and TS_AUTHKEY is not set."
        echo "       Please set TS_AUTHKEY in your .env file for initial registration."
        exit 1
    fi
    echo "No existing Tailscale state — using TS_AUTHKEY for initial registration."
fi

# ------------------------------------------------------------
# 3. nftables互換性の設定
#    Alpine/Tailscaleイメージ内のiptablesをiptables-nftに切り替える
# ------------------------------------------------------------
if [ -x /usr/sbin/iptables-nft ]; then
    ln -sf /usr/sbin/iptables-nft /usr/sbin/iptables
fi
if [ -x /usr/sbin/ip6tables-nft ]; then
    ln -sf /usr/sbin/ip6tables-nft /usr/sbin/ip6tables
fi

# ------------------------------------------------------------
# 4. ルーティング・NAT 設定関数
# ------------------------------------------------------------
PROTON_GW="${PROTON_GW:-10.1.0.2}"
PROTON_GW6="${PROTON_GW6:-fd6a:204b:1e8d::2}"
DOCKER_GW="10.1.0.1"
DOCKER_GW6="fd6a:204b:1e8d::1"


apply_routes() {
    # tailscaled自身の通信 (fwmark 0x80000) は通常のDockerゲートウェイから送る。
    # Exit Nodeの転送通信にはマークがないため、Proton VPNゲートウェイへ送る。
    ip route replace default via "$DOCKER_GW" dev eth0 table 100
    if ! ip -4 rule show | grep -q '100:.*fwmark 0x80000/0xff0000.*lookup 100'; then
        ip -4 rule add priority 100 fwmark 0x80000/0xff0000 lookup 100
    fi
    ip -6 route replace default via "$DOCKER_GW6" dev eth0 table 100
    if ! ip -6 rule show | grep -q '100:.*fwmark 0x80000/0xff0000.*lookup 100'; then
        ip -6 rule add priority 100 fwmark 0x80000/0xff0000 lookup 100
    fi

    # NAT (Masquerade) — 重複追加を防ぐためチェック
    if ! iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    fi
    if ! ip6tables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; then
        ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE || echo "WARNING: IPv6 NAT failed."
    fi

    # MSS Clamping — 重複追加を防ぐためチェック
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 2>/dev/null; then
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120
    fi
    if ! ip6tables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 2>/dev/null; then
        ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 || true
    fi

    # デフォルトゲートウェイをProton VPNに向ける
    current_gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [ "$current_gw" != "$PROTON_GW" ]; then
        ip route del default 2>/dev/null || true
        ip route add default via "$PROTON_GW"
        echo "Route: Default gateway set to $PROTON_GW"
    fi

    current_gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [ "$current_gw6" != "$PROTON_GW6" ]; then
        ip -6 route del default 2>/dev/null || true
        ip -6 route add default via "$PROTON_GW6"
        echo "Route: Default IPv6 gateway set to $PROTON_GW6"
    fi
}

# ------------------------------------------------------------
# 5. 初期セットアップ（遅延実行）
#    Tailscaleが起動しルーティングテーブルを書き換えた後に
#    Proton VPN向けのルーティングとNAT設定を上書きする
# ------------------------------------------------------------
initial_setup() {
    echo "Background: Waiting 10s for Tailscale to start..."
    sleep 10

    echo "Background: Applying routes, NAT & MSS Clamping..."
    apply_routes

    echo "Background: Initial setup COMPLETE. Traffic should now go via Proton VPN."
}

# ------------------------------------------------------------
# 6. ネットワーク監視ウォッチドッグ
#    - Proton VPNゲートウェイへの疎通を定期的に確認
#    - ネットワーク復旧を検知したらルートを再適用し、
#      tailscaledにSIGHUPを送って再接続を促す
# ------------------------------------------------------------
WATCHDOG_INTERVAL=15    # チェック間隔（秒）
WATCHDOG_START_DELAY=30 # 初期セットアップ完了を待つ（秒）

network_watchdog() {
    sleep "$WATCHDOG_START_DELAY"
    echo "Watchdog: Started (interval=${WATCHDOG_INTERVAL}s)"

    was_down=0

    while true; do
        sleep "$WATCHDOG_INTERVAL"

        # Proton VPNゲートウェイへの疎通チェック（ping 1回、タイムアウト3秒）
        if ping -c 1 -W 3 "$PROTON_GW" >/dev/null 2>&1; then
            if [ "$was_down" -eq 1 ]; then
                echo "Watchdog: Network recovered! Re-applying routes..."
                apply_routes

                # tailscaledにSIGHUPを送り、ネットワーク変更を通知
                # これによりDERPサーバーへの再接続が即座にトリガーされる
                if pid=$(pidof tailscaled 2>/dev/null); then
                    kill -HUP "$pid" 2>/dev/null && \
                        echo "Watchdog: Sent SIGHUP to tailscaled (pid=$pid)"
                fi

                was_down=0
                echo "Watchdog: Recovery actions completed."
            fi
        else
            if [ "$was_down" -eq 0 ]; then
                echo "Watchdog: Proton VPN gateway unreachable — network may be down."
                was_down=1
            fi
        fi
    done
}

# ------------------------------------------------------------
# 7. バックグラウンド処理を開始
# ------------------------------------------------------------
# 起動直後からExit Node転送のデフォルト経路をVPN側へ固定する。
apply_routes
initial_setup &
network_watchdog &

# ------------------------------------------------------------
# 8. Tailscale本体を起動
# ------------------------------------------------------------
echo "Starting Tailscale..."
exec /usr/local/bin/containerboot
