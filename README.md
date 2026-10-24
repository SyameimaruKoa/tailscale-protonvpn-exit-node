# Tailscale Proton VPN Exit Node

**Tailscale Exit Node の通信を Proton VPN 経由でインターネットへ送信する、Docker Compose 構成。**

## 主な特徴

- **国指定・サーバー非固定**: `SERVER_COUNTRIES=Japan` などの条件に一致する Proton VPN サーバーからランダムに選択。ホスト名は固定しません。初期設定では無料サーバーから選択し、`FREE_ONLY=off` で有料サーバーも利用可能。
- **選択範囲の絞り込み**: 複数国、都市、地域、ストリーミング、P2P、Secure Core、Tor、無料サーバーなどを指定可能（契約プラン依存）。
- **WireGuard を標準使用**: Proton VPN の設定から `PrivateKey` を取得するだけ。OpenVPN にも対応。
- **Tailscale の登録状態を保存**: 初回登録後は `data_tailscale/` に保存され、Auth Key の失効後でも再起動可能。
- **VPN Kill Switch と転送制限**: Gluetun のファイアウォールを有効のまま使い、Tailscale からのインターネット転送は VPN トンネルインターフェース宛だけに制限。
- **自動再接続**: Gluetun の内蔵ヘルスチェック・VPN 再接続と、経路ルールを再適用する `route-guard` コンテナ。
- **IPv6 出口の切替**: 初期値はフェイルクローズ。Proton IPv6 トンネルを確認したあとに有効化できます。

> **注意**: これはネットワーク/ファイアウォール設定を伴う実験的構成です。実際の Proton VPN 認証情報と Tailscale クライアントを用いた E2E 検証は別途必要です。特に VPN 切断時の漏洩テストを実機で行ってください。

## 構成

```text
Tailscale client
    |
    | Tailscale overlay (100.64.0.0/10)
    v
+------------------------------------------------+
| Gluetun network namespace (Docker container)   |
|                                                |
|  tailscale: Tailscale kernel-mode Exit Node     |
|           tailscale0                            |
|               |                                |
|  route-guard:  | firewall / NAT / route repair  |
|               v                                |
|  gluetun: Proton VPN WireGuard (tun0)           |
+---------------+--------------------------------+
                |
                v
          Proton VPN server
                |
                v
             Internet
```

`tailscale` と `route-guard` は `network_mode: service:gluetun` で同一ネットワーク名前空間を共有します。ホストには VPN のトンネルを作成せず、Docker 内で分離します。Docker の `ports:` 公開もありません。

## 前提条件

- Linux ホスト（Docker Engine と **Docker Compose V2**）
- ホストで利用可能な `/dev/net/tun`
- Tailscale の Auth Key（初回のみ）
- Proton VPN アカウントと [WireGuard 設定](https://account.proton.me/u/0/vpn/WireGuard)。無料プランは国やサーバー、オプションに制約があります。
- IPv4 のみで使う場合、特別な IPv6 ホスト設定は不要です。IPv6 出口を使う場合はホストカーネルと Docker が IPv6 に対応している必要があります。

## セットアップ（通常は3項目だけ）

### 1. ダウンロード

```sh
git clone https://github.com/SyameimaruKoa/tailscale-protonvpn-exit-node.git
cd tailscale-protonvpn-exit-node
cp .env.example .env
```

### 2. `.env` の3項目を設定

```dotenv
TS_AUTHKEY=tskey-auth-xxxxxxxxxxxxxxxx
WIREGUARD_PRIVATE_KEY=取得したPrivateKey
SERVER_COUNTRIES=Japan
```

- **`TS_AUTHKEY`**: [Tailscale 管理画面](https://login.tailscale.com/admin/settings/keys)で発行。**初回登録時のみ必要**。以後は `data_tailscale/` に保存された認証状態を再利用します。
- **`WIREGUARD_PRIVATE_KEY`**: [Proton VPN の WireGuard 設定](https://account.proton.me/u/0/vpn/WireGuard)で設定ファイル（`.conf`）を生成し、`[Interface]` セクションの `PrivateKey = ...` の値だけをコピー。**`Address` や接続先サーバーのIPを毎回指定する必要はありません**。
- **`SERVER_COUNTRIES`**: 英語の国名（例: `Japan`、`United States`）。複数国の指定も可能。サーバー名は固定しません。

通常のIPv4接続では `WIREGUARD_ADDRESSES=10.2.0.2/32` を自動的に使用します。Proton VPNで異なるアドレスが発行された場合は、`.conf` の `Address` に合わせて `WIREGUARD_ADDRESSES` を追加してください。IPv6を使う場合の設定は後述します。

**Proton VPN無料プラン向けに、`FREE_ONLY=on` を初期設定**としてあります。有料プランで通常のサーバーも使う場合は、`.env` に `FREE_ONLY=off` を1行追加してください。無料プランの利用可能な国・サーバーにはProton側の制約があります。

**秘密鍵をGitHubにコミットしないこと。** `.env` は `.gitignore` に登録済みです。

### 3. 起動

```sh
docker compose config --quiet
docker compose up -d
docker compose ps
```

初回だけ、[Tailscale のマシン一覧](https://login.tailscale.com/admin/machines)で新しいノードを **Exit Node として承認**してください。ホスト名はデフォルトで `proton--<Linuxホスト名>` になり、必要なら `TS_HOSTNAME` で変更できます。

### 4. 動作確認

```sh
docker compose logs --tail=100 gluetun tailscale route-guard
docker compose exec gluetun wget -qO- https://api.ipify.org
docker compose exec tailscale tailscale status
```

TailscaleクライアントでこのExit Nodeを選択し、[ip.me](https://ip.me/) と [test-ipv6.com](https://test-ipv6.com/) で出口を確認してください。VPNを停止した際にホスト回線のIPが外部へ漏れないことも、実機で確認する必要があります。

高度なルーティング確認には次のコマンドも使用できます。

```sh
docker compose exec route-guard ip -4 rule show
docker compose exec route-guard iptables -S FORWARD
docker compose exec route-guard iptables -t nat -S POSTROUTING
```

## 国・サーバー選択

`.env` で指定します。

| 設定 | 例 | 説明 |
| --- | --- | --- |
| `SERVER_COUNTRIES` | `Japan` | 選択する国（英語） |
| `SERVER_COUNTRIES` | `Japan,United States` | 複数の国 |
| `SERVER_CITIES` | `Tokyo` | 都市で絞る（空欄なら制限なし） |
| `SERVER_REGIONS` | 空欄 | 地域で絞る |
| `FREE_ONLY` | `on`（初期値） / `off` | 無料サーバー限定 / 有料サーバーも選択 |
| `STREAM_ONLY` | `on` | ストリーミング対応に限定 |
| `SECURE_CORE_ONLY` | `on` | Secure Core に限定 |
| `TOR_ONLY` | `on` | Tor 対応に限定 |
| `PORT_FORWARD_ONLY` | `on` | P2P/ポート転送対応に限定 |
| `UPDATER_PERIOD` | `480h` | 利用可能なサーバー一覧を定期更新 |

選択方法は `SERVER_SELECTION_MODE=random` に設定済みです。**指定国の複数サーバーからランダムに選ぶ**ため、単一サーバーには固定されません。一方、これは速度や負荷を逐次測定した「最速サーバー自動選択」ではありません。また、再接続時に必ず前回と異なるサーバーになるわけでもありません。

国変更後は `docker compose up -d --force-recreate gluetun tailscale route-guard` で再構成してください。再作成で一時的に通信が切れます。対象国に利用可能なサーバーがなければ接続に失敗します。

### OpenVPN に変更

WireGuard 以外が必要なら `.env` で以下を指定します。

```dotenv
VPN_TYPE=openvpn
OPENVPN_USER=Proton専用OpenVPNユーザー名
OPENVPN_PASSWORD=Proton専用OpenVPNパスワード
OPENVPN_PROTOCOL=udp
```

**通常の Proton ログイン情報ではなく、専用の OpenVPN 認証情報が必要**です。[Protonの設定](https://account.proton.me/u/0/vpn/OpenVpn)を確認してください。

### ポートフォワーディング (Proton VPN)

対象プラン・P2P 対応サーバー・適切な WireGuard 設定が必要です。

```dotenv
PORT_FORWARD_ONLY=on
VPN_PORT_FORWARDING=on
```

WireGuard 設定を生成するときに **NAT-PMP (Port Forwarding)** を選択してください。Proton側で払い出されるポートは固定ではありません。これは Exit Node を使うだけなら不要です。また、ホスト側 Docker ポートを公開する設定でもありません。

## IPv6 について

IPv6 を利用するには、Proton VPN サーバーと Gluetun の双方が IPv6 に対応している必要があります。

**初期状態は `ENABLE_IPV6_EGRESS=false` で Tailscale クライアントからの IPv6 インターネット転送を遮断します**。これは IPv6 をホスト回線へ漏らさないためです。Tailscale による IPv6 宛の通信は失敗することがあります。

IPv6 を有効化するには:

1. 新しい Proton WireGuard 設定を生成し、`Address` に実際の IPv6 アドレスが含まれることを確認する。
2. `.env` の `WIREGUARD_ADDRESSES` を両方のアドレス（例: `10.2.0.2/32,2a07:b944::2:2/128`）に設定。
3. **Gluetun の `tun0` に IPv6 アドレスと VPN 内の IPv6 ルートが存在することを実機で確認してから** `ENABLE_IPV6_EGRESS=true` とする。
4. `docker compose up -d` で反映後、別クライアントから IPv6 接続と VPN 切断時の漏洩を確認する。

`route-guard` は IPv6 を有効化した場合のみ IPv6 NAT66 と VPN 限定 FORWARD ルールを設定します。Proton の IPv6 利用可否はサーバーによって異なります。

## VPN Kill Switch とルーティング

Gluetun のファイアウォールを無効にしません。`route-guard` では以下の対策を加えます。

- Tailscale の `--netfilter-mode=off` を指定し、Tailscale が独自の広い許可ルールを先頭へ差し戻す動作を抑止する。
- `tailscale0` からの転送は原則 `tun0` への転送に限定し、外側 `eth0` への転送を DROP。
- VPN トンネルから `tailscale0` への戻り通信は ESTABLISHED/RELATED のみ許可。
- IPv4 NAT（IPv6 使用時は NAT66）を明示的に設定する。
- Gluetun のポリシールートが Tailscale ピアへの返答を奪わないよう、`100.64.0.0/10`（IPv6 は `fd7a:115c:a1e0::/48`）を Tailscale の table 52 に優先度 90 で戻す。
- Gluetun がルールを再設定しても復元できるよう、一定間隔で確認する。

この構成では Gluetun の `FIREWALL_OUTBOUND_SUBNETS` に Tailscale アドレス帯を追加しないでください。そうするとポリシールーティングが競合することがあります。

**重要**: `docker restart protonvpn` のように Gluetun コンテナ単体を再作成した場合、ネットワーク名前空間の共有先が古くなる可能性があります。その際は必ず Compose スタック全体を再作成してください。

```sh
docker compose down
docker compose up -d
```

状態は `data_tailscale/` と `data_gluetun/` に残ります。`docker compose down -v` による名前付きボリュームの削除は不要です。

## トラブルシューティング

**Gluetun が unhealthy**: `docker compose logs gluetun` を確認。WireGuard 秘密鍵、国名、プラン、サーバーの絞り込み条件を確認します。`FREE_ONLY=on` と有料限定オプションの組み合わせは利用可能な候補がなくなることがあります。

**Tailscale が認証されない**: 初回の `TS_AUTHKEY` を確認。以後は `data_tailscale/tailscaled.state` が保存されます。初回の認証失敗時も `docker compose logs tailscale` で確認します。

**出口 IP は Proton だが、クライアントから通信できない**: `docker compose logs route-guard` と、`ip -4 rule` / `iptables -S FORWARD` / `iptables -t nat -S POSTROUTING` を確認します。特に優先度 90 の table 52 ルールが必要です。

**IPv6 のみ接続できない**: 初期設定では意図的に閉じています。WireGuard 設定・Gluetun の IPv6 ルートを確認するまでは `ENABLE_IPV6_EGRESS=true` にしないでください。

**速度が低下する**: VPN over VPN には追加オーバーヘッドがあり、`TS_DEBUG_MTU=1280` で保守的な値を指定しています。速度・MSS・MTU は実機で測定して調整してください。

## ファイル構成

| ファイル | 内容 |
| --- | --- |
| `docker-compose.yml` | Proton VPN、Tailscale、経路監視コンテナ |
| `.env.example` | 最小限の認証情報と国指定のテンプレート（高度な設定はComposeの既定値から変更可能） |
| `entrypoint.sh` | Tailscaleホスト名と既存状態に基づく認証処理 |
| `scripts/route-guard.sh` | ポリシールート、NAT、VPN限定の転送規則 |
| `.gitignore` | 秘密情報と稼働時データの除外 |

## 参考資料

- [Gluetun Proton VPN 設定](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md)
- [Gluetun サーバー更新](https://github.com/qdm12/gluetun-wiki/blob/main/setup/servers.md)
- [Gluetun Firewall](https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/firewall.md)
- [Tailscale Docker 設定](https://tailscale.com/docs/features/containers/docker/docker-params)
- [Tailscale netfilter mode](https://tailscale.com/docs/reference/netfilter-modes)
- [Proton WireGuard 設定ファイルの生成](https://protonvpn.com/ja/support/wireguard-configurations)
