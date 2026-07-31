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
   unicastは可能です。本リポジトリのproxy ARP/routing構成ではLAN側IPを追加でき、今回の環境で動作確認済みです。
   ただし、Wi-Fiホスト上で別MACを持つ独立したL2端末になる構成ではありません。
5. **Broadcast/Multicast/mDNS:** 標準NATではセグメントを越えません。Avahi reflector、SSDP relay、
   機器固有UDP relayを追加して中継します。本リポジトリではAiphoneアプリの探索通信
   （要求UDP/51711、応答UDP/51712）を専用relayで中継し、親機を検出できることを確認済みです。
6. **推奨:** Ubuntu 24.04上でWaydroidを直接実行し、headless Westonとsystemdで常駐させます。
   ADB操作だけDocker化し、探索通信は必要なプロトコルだけ中継します。SSIDまたは端末完全性が認証条件なら、
   常時給電したAndroid実機が最も確実です。

詳細な根拠は [feasibility.md](docs/feasibility.md) と
[wifi-limitations.md](docs/wifi-limitations.md) にあります。

## 動作確認済みの構成

2026-08-01に、Wi-Fi接続したUbuntuホスト上のWaydroidからAiphoneアプリ
（package: `jp.co.aiphone.refine`）を起動し、物理LAN上の親機を探索できることを確認しました。
確認時の構成は次のとおりです。

| 項目 | 確認時の値 |
|---|---|
| ホストのWi-Fi interface | `wlp0s20f3` |
| ホストの物理LAN | `192.168.0.0/24` |
| ルーター | `192.168.0.1` |
| 親機 | `192.168.0.17` |
| Waydroidの通常IP | `192.168.240.112` |
| Waydroidへ追加したLAN側IP | `192.168.0.250` |

成功に必要だったのは、Waydroidへの物理LAN側IP追加、対象packageへのFake Wi-Fi、`wlan0`互換dummy
interface、Aiphone専用の双方向UDP relayです。別環境ではinterface名、subnet、空きIP、親機IPを読み替えてください。

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

アプリがAndroid自身のIPと親機が同一subnetであることを要求する場合、Wi-Fi uplinkではmacvlanの代わりに
routed/proxy-ARP方式を使えます。`config/network.env`で未使用の`ANDROID_LAN_IP`を指定し、ルーターの
DHCP配布範囲から除外（または固定予約）してから適用します。

```bash
sudo ./scripts/setup-network.sh ./config/network.env
systemctl status waydroid-same-lan.service
sudo nsenter -t "$(sudo lxc-info -P /var/lib/waydroid/lxc -n waydroid -pH)" -n ip -br addr
```

Androidには従来の`192.168.240.x`（Internet/NAT）と物理LAN側IPの両方が付きます。Wi-Fi AP側からは
親PCと同じMACに複数IPが見える構成です。同一subnetのunicastは可能になりますが、L2 broadcastを
透過するものではないため、探索方式に応じて以下のrelayも併用します。アプリが
`NetworkCapabilities.TRANSPORT_WIFI`を必須にする場合は、そのpackageだけを`FAKE_WIFI_PACKAGES`へ指定します。
これは接続種別の報告を変えるだけで、SSID scanや物理Wi-Fi HALを追加する設定ではありません。

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

### Aiphoneアプリで確認できた手順

まず、ホスト側のinterface名、subnet、親機IP、Waydroidの現在のIPを確認します。

```bash
ip -br address
ip route
cat /var/lib/misc/dnsmasq.waydroid0.leases
```

`config/network.env`を次のように設定します。以下は確認時の値なので、特に`HOST_LAN_IF`、各IP、
`ANDROID_LAN_IP`を自分のLANに合わせて変更してください。`ANDROID_LAN_IP`にはDHCP配布範囲外の未使用IP、
またはルーターで固定予約したIPを使います。

```dotenv
HOST_LAN_IF=wlp0s20f3
WAYDROID_IF=waydroid0
ROUTER_IP=192.168.0.1
INTERCOM_IP=192.168.0.17
WAYDROID_IP=192.168.240.112

ENABLE_SAME_LAN_IP=yes
ANDROID_LAN_IP=192.168.0.250
LAN_PREFIX_LENGTH=24

FAKE_WIFI_PACKAGES=jp.co.aiphone.refine
ENABLE_ANDROID_WLAN0_COMPAT=yes
ANDROID_WIFI_COMPAT_IF=wlan0
```

ネットワーク設定を適用し、Waydroidからルーターと親機へ到達できることを確認します。

```bash
sudo ./scripts/setup-network.sh ./config/network.env
systemctl status waydroid-same-lan.service --no-pager
./scripts/test-network.sh all | tee network-test.log
```

確認時の構成では、Android側の`eth0`に通常IPとLAN側IPの両方が付き、物理LAN宛ての通信では
`192.168.0.250`がsource addressとして選ばれます。

```bash
pid=$(sudo lxc-info -P /var/lib/waydroid/lxc -n waydroid -pH)
sudo nsenter -t "$pid" -n ip -br address
sudo nsenter -t "$pid" -n ip route get 192.168.0.17
```

次に、別terminalでAiphone専用relayを起動したままにします。このrelayはroot権限でraw socketを使い、
WaydroidからのUDP/51711 broadcastを物理LANへ転送し、親機からLAN側IPのUDP/51712へ返る応答を
Waydroid側へ戻します。

```bash
set -a
source config/network.env
set +a
sudo ./scripts/aiphone-discovery-relay.py \
  --inside "$WAYDROID_IF" \
  --outside "$HOST_LAN_IF" \
  --source-ip "$ANDROID_LAN_IP" \
  --broadcast-ip 192.168.0.255 \
  --port 51711 \
  --response-port 51712
```

`--broadcast-ip`は自分のsubnetのbroadcast addressへ変更してください。その状態でアプリを起動し、
親機探索を実行します。relay側に次の2種類のlogが出れば、要求と応答の両方向を中継できています。

```text
relayed ... bytes from UDP source port ...
relayed response: <親機IP>:<port> -> <Waydroid LAN側IP>:51712 (... bytes)
```

うまく検出できない場合は、両interfaceで同時にpacketを確認します。

```bash
sudo tcpdump -ni waydroid0 'udp port 51711 or udp port 51712'
sudo tcpdump -ni wlp0s20f3 'udp port 51711 or udp port 51712'
adb logcat | grep -E 'FakeWifi|aiphone|refine'
```

`waydroid-same-lan.service`は再起動後も有効ですが、現在のAiphone専用relayはforeground processです。
ホストまたはrelayを再起動した場合は、アプリで探索する前にrelayをもう一度起動してください。

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
