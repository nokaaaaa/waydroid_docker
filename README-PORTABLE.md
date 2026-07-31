# 別PCへアプリデータ込みで複製する

この手順は、現在のWaydroid環境をAndroidのアプリ本体・アプリデータ・設定込みで暗号化し、
別のUbuntu PCへ復元するためのものです。復元先ではセットアップ1コマンド、アプリ起動1コマンドで実行できます。

## 重要事項

- 対応OSはUbuntu 22.04または24.04、x86_64です。
- 現在のスナップショットはAndroidのUIDを保持するため、元PCと復元先のWaydroid実行ユーザーを
  `UID 1000`にしてください。通常、Ubuntuで最初に作ったユーザーが該当します。
- 約4GBのWaydroid stateを扱います。復元先には少なくとも20GBの空きを用意してください。
- スナップショットにはアプリの登録情報、Googleアカウントのtoken、ADB鍵、端末識別情報が含まれ得ます。
  このGitHubリポジトリはPublicなので、スナップショットは必ずGnuPG/AES-256で暗号化してReleaseへ置きます。
- 同じアプリ登録情報・Android端末IDを2台から同時利用すると、サービス側で解除・再認証・競合が起きる可能性があります。
  原則として元PCのWaydroidを停止してから復元先を起動してください。
- 復元先はWaydroid未導入、または既存データを削除済みの新規環境を想定します。既存データがあれば停止します。

## 0. 元PCでスナップショットを公開する（初回またはデータ更新時）

repository directoryで次を実行します。Waydroidを停止し、整合性のある暗号化snapshotを作成します。
GnuPGに聞かれたpassphraseは別の安全な場所へ保管してください。GitHubには保存されません。

```bash
./scripts/create-portable-snapshot.sh
```

作成後、暗号化済みsnapshotだけをGitHub Releaseへuploadします。GitHub CLIでログイン済みである必要があります。

```bash
./scripts/publish-portable-snapshot.sh
```

アプリデータを更新した場合は、この2コマンドをもう一度実行するとRelease assetを置き換えます。

## 1. 別PCでcloneしてセットアップする

別PCでrepositoryをcloneします。

```bash
git clone git@github.com:nokaaaaa/waydroid_docker.git
cd waydroid_docker
```

次の1コマンドで依存package導入、snapshot download・復号、Waydroid復元、同一LAN設定、
headless service、Aiphone探索relayまで設定します。途中でsudo passwordとsnapshotのGnuPG passphraseを入力します。

```bash
./scripts/setup-portable-clone.sh
```

default routeからLAN interfaceとrouterを自動検出します。親機やWaydroid用LAN IPが元PCと異なる場合だけ、
同じ1コマンドへ環境変数を付けます。

```bash
INTERCOM_IP=192.168.0.17 ANDROID_LAN_IP=192.168.0.251 ./scripts/setup-portable-clone.sh
```

`ANDROID_LAN_IP`にはルーターのDHCP配布範囲外にある未使用IP、または固定予約したIPを指定してください。
元PCの`192.168.0.250`をそのまま使う場合は、元PC側のWaydroidを同時起動しないでください。

## 2. アプリを起動する

セットアップ後は、repository directoryで次の1コマンドだけを実行します。

```bash
./scripts/launch-aiphone.sh
```

このコマンドはWaydroid container、同一LAN IP設定、headless session、UDP/51711・51712探索relayを起動してから、
`jp.co.aiphone.refine`をlaunchします。PC再起動後も同じコマンドで起動できます。

状態確認:

```bash
waydroid status
systemctl status waydroid-container.service waydroid-docker.service \
  waydroid-same-lan.service waydroid-aiphone-relay.service
journalctl -u waydroid-aiphone-relay.service -f
```

## Snapshotをローカルファイルから復元する場合

GitHub Releaseを使わず、暗号化snapshotと`.sha256`を別PCへ安全にコピーした場合は次の1コマンドです。

```bash
SNAPSHOT_FILE=/path/to/waydroid-state.tar.zst.gpg ./scripts/setup-portable-clone.sh
```

