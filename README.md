# Tailscale Proton VPN Exit Node

**Tailscale Exit Node の通信を Proton VPN 経由でインターネットへ送信する、Docker Compose 構成。**

## 主な特徴

- **国指定・サーバー非固定**: `SERVER_COUNTRIES=Japan` などの条件に一致する Proton VPN サーバーからランダムに選択。ホスト名は固定しません。初期設定では無料サーバーから選択し、`FREE_ONLY=off` で有料サーバーも利用可能。
- **選択範囲の絞り込み**: 複数国、都市、地域、ストリーミング、P2P、Secure Core、Tor、無料サーバーなどを指定可能（契約プラン依存）。
- **WireGuard を標準使用**: Proton VPN の設定から `PrivateKey` を取得するだけ。OpenVPN にも対応。
- **Tailscale の登録状態を保存**: 初回登録後は `data_tailscale/` に保存され、Auth Key の失効後でも再起動可能。
- **VPN Kill Switch と転送制限**: Gluetun のファイアウォールを有効のまま使い、Tailscale からのインターネット転送は VPN トンネルインターフェース宛だけに制限。
- **自動再接続**: Gluetun の内蔵ヘルスチェック・VPN 再接続と、経路ルールを再適用する `route-guard` コンテナ。
- **IPv6 自動設定**: IPv4/IPv6のWireGuardアドレスを設定済み。VPN内のIPv6アドレスと経路が確認できたときのみIPv6転送を許可し、それ以外は遮断します。

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
- IPv6 出口を使う場合は、ホストカーネルと Docker Engine のユーザー定義ブリッジネットワークが IPv6 に対応している必要があります。Docker Engine 27以降は通常、IPv6用ULAアドレスを自動割り当てできます。

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

標準では `WIREGUARD_ADDRESSES=10.2.0.2/32,2a07:b944::2:2/128` を使用し、IPv4/IPv6の両方を構成します。Proton VPNから発行された設定ファイルの `Address` が異なる場合だけ、`.env` に `WIREGUARD_ADDRESSES` を追加して実際の値に合わせてください。IPv6出口はVPN内の経路が確認できたときに自動的に許可されます。

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

## IPv6（標準で自動判定）

Proton VPNの対応サーバーでは **IPv4とIPv6の両方をVPN経由**で使用できます。Protonによれば、すべてのサーバーがIPv6対応とは限りません。

初期設定の`ENABLE_IPV6_EGRESS=auto`では、`route-guard`が以下の条件を確認します。

1. VPNインターフェース（標準: `tun0`）にグローバルIPv6アドレスがある。
2. IPv6インターネット宛の選択ルートが、Dockerの`eth0`ではなくVPNインターフェースを指している。

この2条件を満たす場合のみ、TailscaleからVPNへのIPv6転送とNAT66を許可します。条件を満たさなければIPv6転送を遮断し、IPv4の通信を維持します。**これはルーティングの確認であり、選択サーバーがIPv6で実際にインターネットへ到達できることまでは保証しません。** 接続先によってはIPv6がタイムアウトする可能性もあります。

Gluetunの`WIREGUARD_ADDRESSES`には標準の`10.2.0.2/32,2a07:b944::2:2/128`を渡します。Proton VPNから発行された設定が異なる場合は、`.env`に実際のアドレスを追加してください。古いWireGuard設定ファイルはIPv6を含まないことがあるため、新しく生成することを推奨します。

IPv6を明示的に止める場合のみ、`.env`へ以下の1行を追加します。

```dotenv
ENABLE_IPV6_EGRESS=false
```

通常はIPv6用の環境変数を手動で追加する必要はありません。Docker Composeの`default`ネットワークはIPv6を有効に設定してあります。Docker Engine 27以降ではIPv6のULAプレフィックスを自動割り当てできますが、ホストでIPv6を完全に無効化している場合はDockerネットワーク作成に失敗することがあります。

確認用コマンド：

```sh
docker compose exec gluetun ip -6 addr show dev tun0
docker compose exec route-guard ip -6 route get 2606:4700:4700::1111
docker compose exec route-guard ip6tables -S FORWARD
```

その後、Exit Nodeを選択した別端末で[test-ipv6.com](https://test-ipv6.com/)を実行し、IPv6の出口がProton VPNであることを確かめてください。VPN切断時にホストのIPv6アドレスが漏れないことも実機で検証してください。

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

**IPv6 のみ接続できない**: `docker compose exec gluetun ip -6 addr show dev tun0` と `docker compose exec route-guard ip -6 route get 2606:4700:4700::1111` を確認してください。IPv6非対応サーバーではIPv6接続が失敗することがあります。`ENABLE_IPV6_EGRESS=false` を指定するとIPv6転送を明示的に停止できます。

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
