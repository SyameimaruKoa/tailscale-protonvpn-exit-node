# Changelog

## 2026-10-27

- DockerネットワークのサブネットとコンテナIPを自動割り当てへ変更。Dockerゲートウェイは起動時に検出して保持し、Gluetunはサービス名で名前解決してIP変更へ追随する。
- fwmark経路分離に専用テーブルの到達不能ガード（fail-closed）と分離状態の監視を追加し、経路確認用に`verify-routing.sh`を追加。
- 初期ルート設定に失敗してもTailscale本体が起動するよう、ルート・NAT・MSS設定の失敗を警告扱いに変更。
- Gluetun側の転送・NATルールを固定送信元IPから専用ネットワークのインターフェース基準へ変更。

## 2026-10-24

- Tailscale Exit NodeとProton VPN（Gluetun）の2コンテナ構成。
- Proton VPNの国・サーバー種別指定とWireGuard/OpenVPNに対応。
- Tailscaleの認証状態、IPv4/IPv6、NAT、MSS調整、経路監視を継続。
