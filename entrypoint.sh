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
Docker assigns the network addresses automatically: the original
Docker gateway is captured at startup, the Gluetun gateway is
resolved from the "gluetun" service name on every route apply, and
Tailscale's own marked packets use the Docker gateway while Exit Node
forwarded traffic uses the Proton VPN gateway.

Variables:
    TS_AUTHKEY    Initial Tailscale authentication key.
    TS_STATE_DIR  Persistent Tailscale state directory.
    GLUETUN_NAME  Service name of the Gluetun container (default gluetun).
    PROTON_GW     Optional fixed VPN gateway IPv4 override.
    PROTON_GW6    Optional fixed VPN gateway IPv6 override.
    TS_FWMARK     tailscaled bypass fwmark (default: auto-detect,
                  fallback 0x80000/0xff0000).
    UNDERLAY_TABLE  Routing table for Tailscale's own traffic (default 100).
    UNDERLAY_PRIO   ip rule priority for that table (default 5200).
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
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
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
# 4. ルーティング・NAT 設定
#    - Dockerネットワークのアドレスは自動割り当てのため固定しない
#    - 通常のDockerゲートウェイは、デフォルト経路をGluetunへ
#      書き換える前に検出して保持する (ORIG_GW / ORIG_GW6)
#    - Gluetunのアドレスはサービス名 "gluetun" を都度名前解決し、
#      コンテナ再作成でIPが変わっても追随する
#    - tailscaled自身の通信 (fwmark付き) は専用テーブルで通常の
#      Dockerゲートウェイへ送る。専用テーブルで解決できない場合は
#      unreachable とし、VPN側へフォールバックさせない (fail-closed)
#    - マークなし通信 (Exit Node転送) はメインのデフォルト経路で
#      Gluetunへ送る
# ------------------------------------------------------------
GLUETUN_NAME="${GLUETUN_NAME:-gluetun}"
PROTON_GW_OVERRIDE="${PROTON_GW:-}"
PROTON_GW6_OVERRIDE="${PROTON_GW6:-}"
UPLINK_DEV="${UPLINK_DEV:-eth0}"

# tailscaledの bypass fwmark (tsconst: LinuxBypassMark=0x80000 / LinuxFwmarkMask=0xff0000)
# TS_FWMARKが未指定なら tailscaled が実際に導入したルールから検出し、
# 検出できない場合のみ既定値を使う
TS_FWMARK="${TS_FWMARK:-}"
TS_FWMARK_DEFAULT="0x80000/0xff0000"
UNDERLAY_TABLE="${UNDERLAY_TABLE:-100}"
UNDERLAY_PRIO="${UNDERLAY_PRIO:-5200}"    # tailscaledの5210より小さい (優先される) こと

# 起動時に保持する元のゲートウェイ (Gluetunへ書き換える前の値)
ORIG_GW=""
ORIG_GW6=""
ORIG_DEV=""

# 現在解決できるGluetunのアドレス (apply_routesのたびに更新)
RESOLVED_GW=""
RESOLVED_GW6=""

# Gluetunのアドレスを名前解決する ($1: "4" または "6")
# 上書き指定があればそれを使い、なければ getent、最後に ping の名前解決を使う
resolve_gluetun() {
    if [ "$1" = "4" ]; then
        if [ -n "$PROTON_GW_OVERRIDE" ]; then
            echo "$PROTON_GW_OVERRIDE"
            return
        fi
    else
        if [ -n "$PROTON_GW6_OVERRIDE" ]; then
            echo "$PROTON_GW6_OVERRIDE"
            return
        fi
    fi
    addr=""
    if command -v getent >/dev/null 2>&1; then
        if [ "$1" = "4" ]; then
            addr=$(getent ahosts "$GLUETUN_NAME" 2>/dev/null | awk '$2=="STREAM" && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')
        else
            addr=$(getent ahosts "$GLUETUN_NAME" 2>/dev/null | awk '$2=="STREAM" && $1 ~ /:/ {print $1; exit}')
        fi
    fi
    if [ -z "$addr" ]; then
        if [ "$1" = "4" ]; then
            addr=$(ping -c 1 -W 1 "$GLUETUN_NAME" 2>/dev/null | head -n 1 | sed -n 's/^[^(]*(\([0-9.]*\)).*/\1/p')
        else
            addr=$(ping -6 -c 1 -W 1 "$GLUETUN_NAME" 2>/dev/null | head -n 1 | sed -n 's/^[^(]*(\([^)]*\)).*/\1/p')
        fi
    fi
    echo "$addr"
}

# 元のデフォルトゲートウェイを保持する
# Gluetunへ書き換えた後の値を「元のゲートウェイ」と誤認しないよう、
# 保持済みの場合と現在値がGluetun自身の場合は上書きしない (冪等)
capture_default_gateways() {
    if [ -z "$ORIG_GW" ]; then
        gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
        if [ -n "$gw" ] && [ "$gw" != "${RESOLVED_GW:-}" ]; then
            ORIG_GW="$gw"
        fi
    fi
    if [ -z "$ORIG_GW6" ]; then
        gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
        if [ -n "$gw6" ] && [ "$gw6" != "${RESOLVED_GW6:-}" ]; then
            ORIG_GW6="$gw6"
        fi
    fi
    if [ -z "$ORIG_DEV" ]; then
        ORIG_DEV=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
        if [ -z "$ORIG_DEV" ]; then
            ORIG_DEV="$UPLINK_DEV"
        fi
    fi
}

# tailscaledが使う bypass fwmark を返す
# 優先順位: 環境変数 TS_FWMARK > tailscaled導入済みルールからの検出 > 既定値
# 自分で入れたルール (lookup UNDERLAY_TABLE) を検出対象にしないため、
# 「lookup main」のルールだけを見る
detect_ts_fwmark() {
    if [ -n "$TS_FWMARK" ]; then
        echo "$TS_FWMARK"
        return
    fi
    mark=$(ip rule show 2>/dev/null | awk '/fwmark/ && /lookup main/ {for(i=1;i<=NF;i++) if($i=="fwmark") {print $(i+1); exit}}')
    if [ -z "$mark" ]; then
        mark=$(ip -6 rule show 2>/dev/null | awk '/fwmark/ && /lookup main/ {for(i=1;i<=NF;i++) if($i=="fwmark") {print $(i+1); exit}}')
    fi
    if [ -n "$mark" ]; then
        echo "$mark"
    else
        echo "$TS_FWMARK_DEFAULT"
    fi
}

# 指定デバイスの接続済みルート (サブネット直結ルート) を専用テーブルへ複写する
# ゲートウェイへの到達性そのものを専用テーブル内でも保証するために必要
# $1: "" (IPv4) または "-6" / $2: デバイス名
# shellcheck disable=SC2086 # $famは "" か "-6" で、単語分割が前提
copy_connected_routes() {
    fam="$1"
    dev="$2"
    ip $fam -o route show dev "$dev" 2>/dev/null | awk '{print $1}' | while read -r pfx; do
        case "$pfx" in
            ""|default|unreachable|prohibit|blackhole|throw|local|broadcast|multicast|anycast|nat)
                continue
                ;;
        esac
        ip $fam route replace "$pfx" dev "$dev" table "$UNDERLAY_TABLE" 2>/dev/null || true
    done
}

# fwmark付きパケットを専用テーブルへ振り分けるルールを入れる (冪等)
# $1: "" (IPv4) または "-6" / $2: fwmark
# shellcheck disable=SC2086 # $famは "" か "-6" で、単語分割が前提
add_underlay_rules() {
    fam="$1"
    mark="$2"
    guard_prio=$((UNDERLAY_PRIO + 1))

    if ! ip $fam rule show 2>/dev/null | grep -q "^${UNDERLAY_PRIO}:.*fwmark ${mark}.*lookup ${UNDERLAY_TABLE}"; then
        ip $fam rule del priority "$UNDERLAY_PRIO" 2>/dev/null || true
        ip $fam rule add fwmark "$mark" lookup "$UNDERLAY_TABLE" priority "$UNDERLAY_PRIO" 2>/dev/null || \
            echo "WARNING: Failed to add underlay ip rule (family='${fam:-4}')."
    fi
    # 専用テーブルで解決できないfwmark付きパケットは破棄する
    # ここでmain (Gluetun経由) へ落とすと経路分離が崩れるため unreachable にする
    if ! ip $fam rule show 2>/dev/null | grep -q "^${guard_prio}:.*fwmark ${mark}.*unreachable"; then
        ip $fam rule del priority "$guard_prio" 2>/dev/null || true
        ip $fam rule add fwmark "$mark" unreachable priority "$guard_prio" 2>/dev/null || true
    fi
}

# 経路分離を (再) 適用する: 元ゲートウェイ保持 → 専用テーブル → fwmarkルール
# 失敗してもTailscaleの起動自体は止めない (警告のみ)。分離の成否は
# verify-routing.sh で確認できる
setup_underlay() {
    capture_default_gateways
    mark=$(detect_ts_fwmark)
    dev="${ORIG_DEV:-$UPLINK_DEV}"

    if [ -n "$ORIG_GW" ]; then
        copy_connected_routes "" "$dev"
        if ip route replace default via "$ORIG_GW" dev "$dev" table "$UNDERLAY_TABLE" 2>/dev/null; then
            add_underlay_rules "" "$mark"
            echo "Underlay: Tailscale traffic (fwmark $mark) -> $ORIG_GW via table $UNDERLAY_TABLE"
        else
            echo "WARNING: Failed to set underlay IPv4 default route via $ORIG_GW (table $UNDERLAY_TABLE)."
        fi
    else
        echo "WARNING: Original IPv4 gateway unknown — cannot separate Tailscale traffic (IPv4)."
    fi

    if [ -n "$ORIG_GW6" ]; then
        copy_connected_routes "-6" "$dev"
        if ip -6 route replace default via "$ORIG_GW6" dev "$dev" table "$UNDERLAY_TABLE" 2>/dev/null; then
            add_underlay_rules "-6" "$mark"
            echo "Underlay: Tailscale traffic (fwmark $mark) -> $ORIG_GW6 via table $UNDERLAY_TABLE (IPv6)"
        else
            echo "WARNING: Failed to set underlay IPv6 default route via $ORIG_GW6 (table $UNDERLAY_TABLE)."
        fi
    else
        echo "WARNING: Original IPv6 gateway unknown — cannot separate Tailscale traffic (IPv6)."
    fi
}

apply_routes() {
    # Gluetunのアドレスを都度解決する (再作成によるIP変更へ追随するため、
    # 元ゲートウェイ保持より先に解決し、誤認防止に使う)
    RESOLVED_GW=$(resolve_gluetun 4)
    RESOLVED_GW6=$(resolve_gluetun 6)

    # 経路分離を先に (再) 適用する
    # mainのデフォルトをGluetunへ書き換える前に元ゲートウェイを保持するため、
    # 必ずGluetun向けルート変更より前に呼ぶこと
    setup_underlay

    # NAT (Masquerade) — 重複追加を防ぐためチェック
    # 失敗しても起動は止めず、ウォッチドッグで再適用する
    if ! iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE || echo "WARNING: IPv4 NAT failed."
    fi
    if ! ip6tables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; then
        ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE || echo "WARNING: IPv6 NAT failed."
    fi

    # MSS Clamping — 重複追加を防ぐためチェック
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 2>/dev/null; then
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 || echo "WARNING: IPv4 MSS clamping failed."
    fi
    if ! ip6tables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 2>/dev/null; then
        ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 || echo "WARNING: IPv6 MSS clamping failed."
    fi

    # デフォルトゲートウェイをGluetunに向ける
    # これはマークなし通信 (Exit Node転送) 用。tailscaled自身の通信は
    # 上記 ip rule により main より先に専用テーブルで処理される
    # VPN障害時もこのデフォルトはGluetunのままにし、通常回線へ
    # フォールバックさせない (Exit Node通信の漏洩防止)
    # 名前解決できない場合はデフォルト経路を変更しない (fail-closed)
    if [ -n "$RESOLVED_GW" ]; then
        current_gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
        if [ "$current_gw" != "$RESOLVED_GW" ]; then
            if ip route replace default via "$RESOLVED_GW" dev "$UPLINK_DEV" 2>/dev/null; then
                echo "Route: Default gateway set to $RESOLVED_GW"
            else
                echo "WARNING: Failed to set default gateway to $RESOLVED_GW."
            fi
        fi
    else
        echo "WARNING: Could not resolve $GLUETUN_NAME (IPv4) — default route unchanged."
    fi

    if [ -n "$RESOLVED_GW6" ]; then
        current_gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
        if [ "$current_gw6" != "$RESOLVED_GW6" ]; then
            if ip -6 route replace default via "$RESOLVED_GW6" dev "$UPLINK_DEV" 2>/dev/null; then
                echo "Route: Default IPv6 gateway set to $RESOLVED_GW6"
            else
                echo "WARNING: Failed to set default IPv6 gateway to $RESOLVED_GW6."
            fi
        fi
    else
        echo "WARNING: Could not resolve $GLUETUN_NAME (IPv6) — default IPv6 route unchanged."
    fi
}

# 経路分離が生きているか確認する (ウォッチドッグ用)
# fwmark付きの経路検索が元のゲートウェイを向いていれば正常
underlay_intact() {
    [ -n "$ORIG_GW" ] || return 1
    ip rule show 2>/dev/null | grep -q "^${UNDERLAY_PRIO}:.*lookup ${UNDERLAY_TABLE}" || return 1
    mark=$(detect_ts_fwmark)
    mark_value="${mark%%/*}"
    got=$(ip route get 1.1.1.1 mark "$mark_value" 2>/dev/null | head -1)
    case "$got" in
        *"$ORIG_GW"*) ;;
        *) return 1 ;;
    esac
    if [ -n "$ORIG_GW6" ]; then
        ip -6 rule show 2>/dev/null | grep -q "^${UNDERLAY_PRIO}:.*lookup ${UNDERLAY_TABLE}" || return 1
        got6=$(ip -6 route get 2606:4700:4700::1111 mark "$mark_value" 2>/dev/null | head -1)
        case "$got6" in
            *"$ORIG_GW6"*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

# tailscaledにSIGHUPを送り、ネットワーク変更を通知する
notify_tailscaled() {
    if pid=$(pidof tailscaled 2>/dev/null); then
        kill -HUP "$pid" 2>/dev/null && \
            echo "Watchdog: Sent SIGHUP to tailscaled (pid=$pid)"
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
    apply_routes || echo "WARNING: Background route setup failed; watchdog will retry."

    echo "Background: Initial setup COMPLETE. Traffic should now go via Proton VPN."
}

# ------------------------------------------------------------
# 6. ネットワーク監視ウォッチドッグ
#    - 経路分離の維持とGluetunのIP変更を定期的に確認し、
#      崩れていればルートを再適用する
#    - Gluetunへのpingはコンテナ到達性の確認に限る。
#      VPNトンネル自体の正常性はGluetunのhealthcheckが判定する
# ------------------------------------------------------------
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-15}"    # チェック間隔（秒）
WATCHDOG_START_DELAY="${WATCHDOG_START_DELAY:-30}" # 初期セットアップ完了を待つ（秒）

network_watchdog() {
    sleep "$WATCHDOG_START_DELAY"
    echo "Watchdog: Started (interval=${WATCHDOG_INTERVAL}s)"

    was_down=0

    while true; do
        sleep "$WATCHDOG_INTERVAL"

        # 経路分離の維持確認
        # tailscaledの再起動等でルールやテーブルが消えていたら再適用する
        # (この確認自体はGluetun疎通の成否に依存しない)
        if ! underlay_intact; then
            echo "Watchdog: Routing separation lost — re-applying routes..."
            apply_routes || echo "WARNING: Watchdog route re-apply failed."
        fi

        # GluetunのIP変更確認
        # コンテナ再作成でIPが変わっていたらデフォルト経路を追随させる
        resolved_now=$(resolve_gluetun 4)
        current_default=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
        resolved6_now=$(resolve_gluetun 6)
        current_default6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
        if { [ -n "$resolved_now" ] && [ "$resolved_now" != "$current_default" ]; } || \
           { [ -n "$resolved6_now" ] && [ "$resolved6_now" != "$current_default6" ]; }; then
            echo "Watchdog: Gluetun address changed — re-applying routes..."
            apply_routes || echo "WARNING: Watchdog route re-apply failed."
            notify_tailscaled
        fi

        # Gluetunコンテナへの到達性チェック (ping 1回、タイムアウト3秒)
        # 到達性の回復を検知したらルート再適用とSIGHUPを行う
        ping_target="${resolved_now:-$current_default}"
        if [ -n "$ping_target" ] && ping -c 1 -W 3 "$ping_target" >/dev/null 2>&1; then
            if [ "$was_down" -eq 1 ]; then
                echo "Watchdog: Network recovered! Re-applying routes..."
                apply_routes || echo "WARNING: Watchdog route re-apply failed."
                notify_tailscaled
                was_down=0
                echo "Watchdog: Recovery actions completed."
            fi
        else
            if [ "$was_down" -eq 0 ]; then
                echo "Watchdog: Gluetun gateway unreachable — network may be down."
                was_down=1
            fi
        fi
    done
}

# ------------------------------------------------------------
# 7. バックグラウンド処理を開始
# ------------------------------------------------------------
# 起動直後からExit Node転送のデフォルト経路をVPN側へ固定する。
# 初期ルート設定が失敗してもTailscale本体の起動は止めない
capture_default_gateways
apply_routes || echo "WARNING: Initial route setup failed; watchdog will retry."
initial_setup &
network_watchdog &

# ------------------------------------------------------------
# 8. Tailscale本体を起動
# ------------------------------------------------------------
echo "Starting Tailscale..."
exec /usr/local/bin/containerboot
