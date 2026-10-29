# Tailscale Proton VPN Exit Node

Docker Composeで **Tailscale Exit Nodeの出口をProton VPNにする**構成。国を指定して接続でき、特定のVPNサーバーには固定されません。

## 特徴

- 2コンテナ構成（Gluetun + Tailscale）
- Proton VPNの国・都市・サーバー種別を選択でき、候補サーバーからランダムに接続
- WireGuardを標準使用。必要ならOpenVPNにも変更可能
- IPv4/IPv6、Tailscale認証状態の保存、NAT・MSS調整、15秒ごとの経路分離・ゲートウェイ監視
- Proton VPNの再接続はGluetunが管理

TailscaleとGluetunは個別のネットワーク名前空間で動作します。ネットワークのアドレスはDockerが自動で割り当てます。Tailscaleが受け取ったExit Nodeのインターネット通信はサービス名`gluetun`で解決したProton VPNゲートウェイへ送り、Tailscale自身の接続維持に使うマーク付き通信は起動時に保持した通常のDockerゲートウェイへ送ります。GluetunのIPが再作成で変わっても経路は自動で追随します。GluetunはVPN側の転送・NATを担当します。

## 起動方法

1. Docker EngineとDocker Compose V2が動くLinuxでリポジトリを取得する。

```sh
git clone https://github.com/SyameimaruKoa/tailscale-protonvpn-exit-node.git
cd tailscale-protonvpn-exit-node
cp .env.example .env
```

2. [Tailscale Auth Key](https://login.tailscale.com/admin/settings/keys)を発行し、[Proton VPNのWireGuard設定](https://account.proton.me/u/0/vpn/WireGuard)から`PrivateKey`を取得する。

3. `.env`の3項目だけを編集する。

```dotenv
TS_AUTHKEY=tskey-auth-xxxxxxxx
WIREGUARD_PRIVATE_KEY=xxxxxxxx
SERVER_COUNTRIES=Japan
```

Proton VPNの秘密鍵はアカウントで生成したWireGuard設定の`PrivateKey`を使用します。**サーバー名やIPアドレスの固定は不要**です。標準的なWireGuardアドレスはGluetunのProton VPN向け既定値を利用するため、通常は`WIREGUARD_ADDRESSES`を指定しません。

4. 起動する。

```sh
docker compose up -d
```

初回だけ[Tailscale管理画面](https://login.tailscale.com/admin/machines)でExit Nodeとして承認します。認証状態は`data_tailscale/`へ保存するため、以降は期限切れのAuth Keyでも起動可能です。

## Proton VPN固有の追加設定

必要なものだけ`.env`へ追加できます。いずれもGluetunの提供する設定機能をそのまま利用します。

| 環境変数 | 例 | 機能 |
| --- | --- | --- |
| `SERVER_COUNTRIES` | `Japan,United States` | 接続先の国（複数指定可） |
| `SERVER_REGIONS` | 地域名 | 地域で絞り込み |
| `SERVER_CITIES` | `Tokyo` | 都市で絞り込み |
| `FREE_ONLY` | `off` | 有料サーバーも選択（標準は`on`） |
| `STREAM_ONLY` | `on` | ストリーミング対応サーバー |
| `SECURE_CORE_ONLY` | `on` | Secure Coreサーバー |
| `TOR_ONLY` | `on` | Tor対応サーバー |
| `PORT_FORWARD_ONLY` | `on` | ポート転送対応サーバー |
| `VPN_PORT_FORWARDING` | `on` | Proton VPNのポート転送を使用 |
| `VPN_TYPE` | `openvpn` | OpenVPNへ変更 |
| `UPDATER_PERIOD` | `480h` | サーバー一覧の定期更新（標準値） |

有料サーバーを使う場合は`FREE_ONLY=off`を追加します。無料プランでは選べる国やサーバー、同時接続数などに制限があります。また、国・サーバーを自由に選べる範囲は契約プランに依存します。

OpenVPNへ変更する場合はProton VPNが発行する**OpenVPN専用**ユーザー名・パスワードを設定してください。

```dotenv
VPN_TYPE=openvpn
OPENVPN_USER=xxxxxxxx
OPENVPN_PASSWORD=xxxxxxxx
```

Proton VPNのポート転送は対応プランとNAT-PMP対応のWireGuard設定などが必要です。

## IPv6

IPv6を含むWireGuardインターフェース設定はGluetunのProton VPN向け既定値を利用します。DockerネットワークのIPv6も有効です。

IPv4/IPv6のExit Node転送はProton VPNインターフェース宛だけを許可します。**Proton VPNの接続サーバーがIPv6非対応の場合、IPv6インターネットへの通信は失敗します**。勝手にIPv6をホスト回線から出すフォールバックは設けません。

## 動作確認・障害時

```sh
docker compose ps
docker compose logs --tail=100 gluetun tailscale
docker compose exec tailscale tailscale status
# 経路分離の確認 (デフォルト経路はVPNへ、Tailscale自身の通信はホスト側へ)
docker compose exec tailscale sh /verify-routing.sh
```

Tailscaleクライアントから新しいExit Nodeを選択し、[ip.me](https://ip.me/) と [test-ipv6.com](https://test-ipv6.com/) でProton VPN経由のIPv4・IPv6通信を確認してください。VPN切断時にホストのIPアドレスへ切り替わらないかも確認してください。**2026-10-29に実機でProton VPN Free（WireGuard）への接続と、クライアントの公開IPv4・IPv6がともにVPN側のアドレスになること、Tailscale管理画面でこのノードのエンドポイントが通常回線のアドレスのみであること、Docker自動割り当てのアドレスで`verify-routing.sh`の全項目がPASSすることを確認済み**です。残る課題として、VPN切断時の漏洩試験、OpenVPN UDPでの確認、性能比較は未実施です。

VPNの認証・サーバー選択・再接続はGluetunが管理します。Tailscale側は経路分離とゲートウェイを15秒ごとに確認し、障害復旧時やGluetunのIP変更時に経路を再適用します。

## ファイル

| ファイル | 内容 |
| --- | --- |
| `docker-compose.yml` | Proton VPN、Tailscaleの2コンテナと専用ネットワーク |
| `entrypoint.sh` | Tailscale起動・認証状態復元・NAT・ルーティング・監視 |
| `verify-routing.sh` | 経路分離の確認 |
| `gluetun-post-rules.txt` | Proton VPNゲートウェイの転送・NAT設定 |
| `.env.example` | 最小限の起動設定 |
| `CHANGELOG.md` | 更新履歴 |

## 参考資料

- [Gluetun Proton VPN設定](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md)
- [Gluetun IPv6設定](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/ipv6.md)
- [Proton WireGuard設定](https://protonvpn.com/ja/support/wireguard-configurations/)
