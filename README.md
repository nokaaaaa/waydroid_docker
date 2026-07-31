# Waydroid on GUI-less Ubuntu Server

このリポジトリは、Waydroid本体をUbuntuホストで動かし、DockerはADB操作・診断・任意の
ループバックプロキシに限定する構成です。`nested-waydroid`は再現実験用であり、本番構成ではありません。

## 最初に結論

1. **Docker内での安定運用:** 起動例は作れますが、Waydroid(LXC)をDockerへネストし、
   `privileged`、host cgroup、binderfs、mount操作を与える必要があります。公式の本番構成ではなく、
   更新・cgroup・AppArmor・mount propagationの影響も受けるため、安定運用可能とは判定しません。
2. **実SSID一覧:** 標準Waydroidイメージでは表示・スキャンできません。Linuxのveth/Ethernet接続を
   Androidへ見せているので、周辺APをスキャンする物理Wi-Fi HALがありません。
3. **Androidから物理Wi-Fiへ直接接続:** 標準構成ではできません。USB NICをLinuxコンテナへ移して
   `iw`で使えることと、AndroidのSettings/WifiManagerから使えることは別です。
4. **インターホンと同じLAN:** 「同じL2の独立端末」とは限りませんが、標準NATでもAndroidからLANへの
   unicastは可能です。Wi-Fiホストで独立LAN IPを保証する構成はなく、proxy ARP/routingは実機検証が必要です。
5. **Broadcast/Multicast/mDNS:** 標準NATではセグメントを越えません。Avahi reflector、SSDP relay、
   機器固有UDP relayを追加すれば中継候補になりますが、ポート、応答先、TTL、送信元IP依存のアプリは失敗します。
6. **推奨:** Ubuntu 24.04上でWaydroidを直接実行し、headless Westonとsystemdで常駐させます。
   ADB操作だけDocker化し、探索通信は必要なプロトコルだけ中継します。SSIDまたは端末完全性が認証条件なら、
   常時給電したAndroid実機が最も確実です。

詳細な根拠は [feasibility.md](docs/feasibility.md) と
[wifi-limitations.md](docs/wifi-limitations.md) にあります。

## 構成

```text
外部PC -- SSH/ADB tunnel --> Ubuntu Server (wlan0, 家庭内LAN)
                              |-- Waydroid (host LXC, waydroid0/veth, NAT)
                              |    `-- Android / adbd / target app
                              |-- Weston headless + systemd
                              |-- optional mDNS/SSDP/UDP relay
                              `-- Docker adb-tools / loopback adb-proxy
                                           |
インターホン <------ unicast / verified discovery relay ------+
```

## 対応環境と前提条件

- Ubuntu Server 22.04 (jammy) または24.04 (noble)、x86_64
- 推奨は24.04。新しいHWE/6.8系カーネルと長い残存サポート期間のためです。22.04も公式リポジトリの
  対象ですが、実際のカーネルconfigとGPU/ソフトウェア描画を必ず検査します。
- Docker EngineとCompose plugin（ADBツール用）
- 4GB以上のRAM、Android image/data用に20GB以上の空き容量を推奨
- `CONFIG_ANDROID_BINDER_IPC`、`CONFIG_ANDROID_BINDERFS`
- namespaces、cgroup v2、veth/bridge、overlayfs、netfilter/NAT
- `/dev/dri`はGPU描画時のみ必要。ソフトウェア描画なら必須ではありません。
- 新しいWaydroidは`/dev/ashmem`がなければ`sys.use_memfd=true`を設定します。したがってmodern Ubuntuで
  `ashmem_linux`は必須ではありません。binderは必須です。

確認:

```bash
uname -a
grep -E 'CONFIG_ANDROID_BINDER(_IPC|FS)=' /boot/config-"$(uname -r)"
grep -E 'binder|overlay' /proc/filesystems
docker version
docker compose version
```

## 1. ホストのセットアップ

```bash
cp config/network.env.example config/network.env
# HOST_LAN_IF、ROUTER_IP、INTERCOM_IPを編集
sudo WAYDROID_USER="$USER" ./scripts/install-host-dependencies.sh
```

スクリプトは公式Waydroid aptリポジトリ、binderfs、headless compositor、ADB/診断ツールを準備します。
ダウンロードしたリポジトリスクリプトをrootで実行するため、運用組織では実行前に内容と署名方針を監査してください。

## 2. Waydroid初期化

Googleサービス不要なら:

```bash
sudo waydroid init -s VANILLA
sudo systemctl enable --now waydroid-container.service
waydroid status
```

Google Playが必要なら、**新規初期化時に**代わりに次を使います。

```bash
sudo waydroid init -s GAPPS
```

VANILLAとGAPPSを同じデータへ重ねて初期化しません。GAPPS imageでもPlay Protect未認証になる場合があり、
公式手順に従ってAndroid IDをGoogleのuncertified-deviceページへ登録します。Google認証情報やADB秘密鍵は
リポジトリに保存しないでください。Play Integrityの合格は保証されません。

GPUが利用できず起動しない場合だけ、[config/waydroid.cfg](config/waydroid.cfg) の`[properties]`を
`/var/lib/waydroid/waydroid.cfg`の同じセクションへマージし、適用します。

```bash
sudoedit /var/lib/waydroid/waydroid.cfg
sudo waydroid upgrade -o
```

設定ファイル全体をサンプルで上書きしてはいけません。

## 3. GUIなしで常駐

インストールスクリプトがunitと`/etc/default/waydroid-headless`を配置します。

```bash
sudo systemctl enable --now waydroid-docker.service
systemctl status waydroid-docker.service waydroid-container.service
sudo journalctl -u waydroid-docker.service -f
waydroid status
waydroid shell getprop ro.build.version.release
```

このunitは非rootユーザーとしてD-Bus sessionとWeston headless backendを起動します。物理画面は不要です。
`WAYDROID_USER`を変更した場合は次を実行します。

```bash
sudoedit /etc/default/waydroid-headless
sudo loginctl enable-linger <user>
sudo systemctl restart waydroid-docker.service
```

## 4. APKインストール

```bash
./scripts/install-apk.sh ./app.apk
waydroid app list
waydroid app launch com.example.app
```

x86_64 host用Waydroidではx86/x86_64 APKが基本です。ARM-only APKはそのままでは動きません。
communityの`waydroid_script`でlibndk-translationまたはlibhoudiniを追加できる場合がありますが、
公式imageの標準機能ではなく、全ABI/JNI/DRMを保証しません。導入前にimageをバックアップし、入手物を監査してください。

## 5. ADBとscrcpy

まずWaydroid IPを確認し、ホスト上のADB鍵をAndroid画面で一度認証します。

```bash
cat /var/lib/misc/dnsmasq.waydroid0.leases
waydroid adb connect
adb devices -l
```

Docker toolboxを使う場合（別のADB鍵なので初回承認が必要）:

```bash
docker compose --profile tools up -d adb-tools
docker compose exec adb-tools adb connect 192.168.240.2:5555
docker compose exec adb-tools adb devices -l
```

外部へADBを平文公開しません。`config/network.env`のIPをCompose環境へ渡してloopback proxyを起動し、
SSH tunnelを使います。

```bash
set -a; source config/network.env; set +a
docker compose up -d adb-proxy
# 外部PCで
ssh -N -L 5555:127.0.0.1:5555 ubuntu@server
adb connect 127.0.0.1:5555
scrcpy -s 127.0.0.1:5555
```

scrcpyは専用server portを恒久公開せず、ADB transportを利用します。headless compositorでのscrcpy可否は
GPU/codec/imageごとに確認してください。認証プロンプトを確認できない場合は一時的なローカルWayland画面、
既に認証済みのADB鍵、または実機を利用し、`ro.adb.secure=0`にはしません。

外部操作例:

```bash
adb shell monkey -p com.example.app 1
adb shell input tap 500 800
adb shell input swipe 500 1000 500 300 500
adb shell input text 'test'
adb exec-out screencap -p > screenshot.png
adb shell screenrecord --time-limit 30 /sdcard/demo.mp4
adb pull /sdcard/demo.mp4
adb shell uiautomator dump /sdcard/window.xml
adb pull /sdcard/window.xml
```

## 6. LANと探索通信

まずNAT/unicastだけで検証します。

```bash
./scripts/test-network.sh all | tee network-test.log
```

対象アプリの探索が失敗した場合に限り、relayを一つずつ有効化します。

```bash
sudoedit config/network.env
# 例: ENABLE_MDNS_REFLECTOR=yes
sudo ./scripts/setup-network.sh ./config/network.env
sudo ./scripts/test-network.sh capture 30
```

- mDNS: Avahi reflector (`224.0.0.251:5353`)
- SSDP: `udp-broadcast-relay-redux` (`239.255.255.250:1900`)、別途レビューしてインストール
- UDP broadcast: 機器の実ポートを`BROADCAST_PORTS`へ指定

別LAN端末を受信側にして往復テストします。

```bash
./scripts/test-network.sh listen 37020
./scripts/test-network.sh send-broadcast 192.168.1.255 37020 hello
./scripts/test-network.sh send-multicast 239.255.255.250 1900 test
```

プロセス起動だけを合格にせず、wlan側とwaydroid0側の`tcpdump`、Android発信、LAN端末発信の4点を確認します。
詳細は [networking.md](docs/networking.md) を参照してください。

## Docker内Waydroid実験（非推奨）

```bash
sudo ./scripts/setup-binder.sh
docker compose --profile experimental build nested-waydroid
docker compose --profile experimental up -d nested-waydroid
docker compose exec nested-waydroid waydroid status
```

このserviceの`privileged: true`は、内側のLXCがnamespace、mount、network、device/cgroupを操作するためです。
これはホストroot相当の危険な境界で、binderfsと`/dev/dri`を渡すだけのcapability集合では安定して起動できません。
Docker内systemdは内側のWaydroid container service管理には便利ですが、ネスト固有の問題を解消しません。
実機で合格するまで`restart: unless-stopped`を本番保証と解釈しないでください。

## Wi-Fi/SSIDの制約

Androidの`WifiManager`が返すネットワーク種別、SSID、BSSID、DHCP情報は実測します。

```bash
waydroid shell cmd wifi status
waydroid shell dumpsys wifi
waydroid shell dumpsys connectivity
waydroid shell ip addr
```

vethをWi-Fiに偽装しても実SSIDスキャンにはなりません。位置情報権限を与えてもHALにscan resultがなければ
SSIDは得られません。USB Wi-Fiの詳細は [wifi-limitations.md](docs/wifi-limitations.md) を参照してください。

## セキュリティ

- `nested-waydroid`のprivileged modeは隔離境界として扱いません。信頼しないAPKを実行しないでください。
- ADB 5555を`0.0.0.0`へ公開せず、既定のloopback bindとSSH tunnelを維持してください。
- ADB秘密鍵、Google cookie/password、APKライセンス情報をcommitしません。
- multicast reflectorはLAN間の情報を漏らします。対象interface/サービス/UDP portを最小化します。
- Waydroidは実機TEE/verified boot認証を提供しません。SafetyNet/Play Integrity/root/emulator判定の回避は扱いません。
- 対象APKの提供元、署名、利用規約、自動操作の許可を確認してください。

## 完全削除

停止のみ:

```bash
sudo ./scripts/cleanup.sh
```

WaydroidデータとこのCompose projectのvolumeも削除（確認文字列が必要、復元不可）:

```bash
sudo ./scripts/cleanup.sh --purge-data
```

Avahi設定とバックアップはネットワーク影響を確認して手動復元します。
トラブル時は [troubleshooting.md](docs/troubleshooting.md) を参照してください。
