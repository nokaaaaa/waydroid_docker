# 別PCへアプリデータ込みで複製する

この手順は、現在のWaydroid環境をAndroidのアプリ本体・アプリデータ・設定込みで暗号化し、
別のUbuntu PCへ復元するためのものです。復元先では、画面なしで常駐させるheadless運用と、
Ubuntuデスクトップへ画面を表示するGUI運用のどちらかを選べます。

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
続けて暗号化済みsnapshotだけをGitHub Releaseへuploadします。途中でGnuPGに聞かれたpassphraseは
別の安全な場所へ保管してください。GitHubには保存されません。GitHub CLIでログイン済みである必要があります。

```bash
./scripts/prepare-portable-release.sh
```

作成とuploadを個別に行いたい場合は次の2コマンドです。

```bash
./scripts/create-portable-snapshot.sh
./scripts/publish-portable-snapshot.sh
```

アプリデータを更新した場合は、同じ準備コマンドをもう一度実行するとRelease assetを置き換えます。

## 1. 別PCでcloneしてセットアップする

別PCでrepositoryをcloneします。

```bash
git clone git@github.com:nokaaaaa/waydroid_docker.git
cd waydroid_docker
```

次の1コマンドで依存package導入、snapshot download・復号、Waydroid復元、同一LAN設定、
headless service、Aiphone探索relayまで設定します。途中でsudo passwordとsnapshotのGnuPG passphraseを入力します。
セットアップ直後はheadless運用です。

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

## 2. 運用方法を選ぶ

headlessとGUIを同時には起動しません。用途に応じて、次のどちらかを選びます。

### A. headlessで常駐させる

モニターやデスクトップログインなしで常駐させる方法です。`setup-portable-clone.sh`の完了直後は
この状態になっています。必要なserviceを明示的に起動・再起動する場合は次を実行します。

```bash
sudo systemctl start waydroid-container.service waydroid-docker.service
sudo systemctl restart waydroid-same-lan.service waydroid-aiphone-relay.service
```

headless sessionは専用のD-Busと画面を持たないWeston compositor上で動きます。そのため、通常の
`waydroid app launch`を別のterminalから実行すると、`dbus-launch`または`WAYLAND_DISPLAY`のerrorに
なることがあります。Android container内から直接アプリを起動してください。`shell`の直後の`--`は、
後続のoptionをAndroid側へ渡すために必要です。

現在の`launch-aiphone.sh`も最後に通常の`waydroid app launch`を呼ぶため、headless環境では同じD-Bus
errorになる場合があります。その場合でも、それより前にcontainer、headless session、network、relayは
起動済みです。続けて次のAndroid側コマンドを実行します。

```bash
sudo waydroid shell -- am start -n \
  jp.co.aiphone.refine/jp.co.aiphone.vixusadvance.SplashActivity
```

packageのlauncher activityを自動選択させる場合は次でも起動できます。

```bash
sudo waydroid shell -- monkey \
  -p jp.co.aiphone.refine \
  -c android.intent.category.LAUNCHER \
  1
```

headlessではアプリを起動してもUbuntu上にGUI windowは表示されません。processの起動確認:

```bash
sudo waydroid shell -- pidof jp.co.aiphone.refine
```

数字のPIDが表示されればアプリは動作中です。画面を表示・操作する必要がある場合は、後述のGUI運用へ
切り替えるか、ADBとscrcpyを使用します。headlessへ戻した後も、次回boot時に自動起動させる場合は次を
実行します。

```bash
sudo systemctl enable waydroid-docker.service
```

### B. UbuntuデスクトップへGUIを表示する

UbuntuへGUIログインし、そのデスクトップ上にWaydroidのwindowを表示する方法です。最初にheadless
serviceを停止し、次回boot時の自動起動も無効にします。

```bash
sudo systemctl disable --now waydroid-docker.service
```

SSHやtext consoleではなく、Ubuntuデスクトップ上で開いたterminalからWayland環境を確認します。

```bash
echo "$XDG_SESSION_TYPE $WAYLAND_DISPLAY"
```

通常は`wayland wayland-0`などと表示されます。`WAYLAND_DISPLAY`が空の場合、そのterminalからGUIは
表示できません。Waydroid containerとnetwork/relayを準備してから、一般ユーザーとしてアプリを起動します。
`waydroid app launch`には`sudo`を付けないでください。

```bash
sudo systemctl start waydroid-container.service
sudo systemctl restart waydroid-same-lan.service waydroid-aiphone-relay.service
waydroid app launch jp.co.aiphone.refine
```

Android全体の画面を表示する場合:

```bash
waydroid show-full-ui
```

GUIからheadless運用へ戻す場合は、GUI sessionを停止してheadless serviceを再度有効にします。

```bash
waydroid session stop
sudo systemctl enable --now waydroid-docker.service
sudo systemctl restart waydroid-same-lan.service waydroid-aiphone-relay.service
sudo waydroid shell -- am start -n \
  jp.co.aiphone.refine/jp.co.aiphone.vixusadvance.SplashActivity
```

## 3. 状態を確認する

状態確認:

```bash
waydroid status
systemctl status waydroid-container.service waydroid-docker.service \
  waydroid-same-lan.service waydroid-aiphone-relay.service
journalctl -u waydroid-aiphone-relay.service -f
```

GUI運用では`waydroid-docker.service`が`inactive (dead)`でも正常です。このserviceはheadless session専用です。

よくあるerror:

- `org.freedesktop.DBus.Error.Spawn.ExecFailed`: headless sessionへ通常の`waydroid app launch`で
  接続しようとしています。headless用の`sudo waydroid shell -- am start ...`を使います。
- `WAYLAND_DISPLAY is not set`: GUIを表示できないterminalです。Ubuntuデスクトップ上のterminalを使うか、
  headless運用を選びます。
- `Wayland socket ... doesn't exist`: headless compositorとデスクトップのWayland sessionを混在させています。
  headless serviceを停止してからGUIを起動します。

## Snapshotをローカルファイルから復元する場合

GitHub Releaseを使わず、暗号化snapshotと`.sha256`を別PCへ安全にコピーした場合は次の1コマンドです。

```bash
SNAPSHOT_FILE=/path/to/waydroid-state.tar.zst.gpg ./scripts/setup-portable-clone.sh
```
