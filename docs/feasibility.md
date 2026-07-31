# 技術的実現可能性

## 判定

WaydroidはLinux namespace上でAndroidを動かすLXCベースの実装で、現在のupstream READMEは
LineageOS/Android 13ベースと説明しています。ただし配布channelや更新時期でAndroid versionは変わるため、
`waydroid shell getprop ro.build.version.release`を唯一の実機判定とします。

ホスト直接実行はサポート経路です。Dockerネストは技術実験としては可能性がありますが、次の理由で本番判定を
「非推奨・未検証」とします。

- Waydroid自身がmount/pid/user/net/ipc namespaceを使うLXC containerである
- 外側Dockerのseccomp、AppArmor、cgroup namespace、mount propagationが内側LXCと干渉する
- Android binder IPCの3 nodeをホストkernelから内側まで一貫して公開する必要がある
- loop/overlay mount、veth/bridge、dnsmasq、netfilter、GPU deviceへ広い権限が必要
- `privileged`はホストroot相当で、Dockerをsecurity boundaryとして使えない
- upstreamは通常のLinux host/Wayland sessionを導入手順にしており、nested Dockerを安定構成として文書化していない

Docker内のsystemdは`waydroid-container.service`やD-Busの管理に有用ですが、必須条件そのものではありません。
PID 1/systemdを置かず手動でcontainer/sessionを起動することもできます。ただしservice lifecycleを揃えるため、
実験imageではsystemdを採用しています。

## kernel・device要件

| 項目 | 判定 | 説明 |
|---|---|---|
| binder IPC | 必須 | `CONFIG_ANDROID_BINDER_IPC`。Androidのservice manager IPCに必要 |
| binderfs | 強く推奨 | `CONFIG_ANDROID_BINDERFS`。Waydroidがbinder/hwbinder/vndbinder相当を動的確保 |
| ashmem | legacyのみ | `/dev/ashmem`がなければWaydroidは`sys.use_memfd=true`を設定する現行実装 |
| memfd | modern構成 | host syscall/filesystemとAndroid image側policyが必要。通常の5.15/6.8 kernelで利用 |
| cgroup | 必須 | LXC process/resource管理。nested時はhost cgroup mountが必要になりやすい |
| namespaces | 必須 | user/pid/uts/net/mount/ipc |
| overlayfs/loop | 必須相当 | system/vendor imageとoverlayのmountに使用 |
| veth/bridge/netfilter | 標準networkで必須 | `waydroid0`、dnsmasq、forward、MASQUERADE |
| DRM `/dev/dri` | 条件付き | hardware rendering時。SwiftShaderなら省略可能だが低速 |

検査:

```bash
grep -E 'CONFIG_ANDROID_BINDER(_IPC|FS)=' /boot/config-"$(uname -r)"
grep -w binder /proc/filesystems
sudo ./scripts/setup-binder.sh
mount | grep binderfs
ls -la /dev/binderfs /dev/{binder,hwbinder,vndbinder,anbox-*} 2>/dev/null
stat -fc %T /sys/fs/cgroup
```

`/dev/binderfs`はホストでmountしてからnested containerへbind mountします。単なる空directoryのbindでは
ありません。既存binder nodeを複数Android instanceで共有するとbinder contextが衝突し得るため、複数instanceは
本構成の範囲外です。

## Ubuntu version

24.04を推奨します。公式repositoryはjammy/nobleの両方を扱いますが、24.04の標準kernelはより新しく、
Serverの今後の保守期間も長いためです。22.04の5.15/HWEでもbinder configがあれば動作候補です。
OS versionだけで成功を断定せず、running kernel config、GPU、Waydroid image、LXC logで合否を決めます。

## Google Play、ARM、端末完全性

- `waydroid init -s GAPPS`でGAPPS imageを選べます。Play Protect certificationは別途Android ID登録が
  必要な場合があります。
- x86_64 imageはARM-only native libraryを直接実行しません。libndk-translation/libhoudiniはcommunity追加で、
  アプリ、JNI、32/64-bit組合せによって失敗します。
- Waydroidは通常の認定実機、hardware-backed keystore/TEE、locked boot chainではありません。
  SafetyNet/Play Integrity、root、emulator/container、unsupported device判定を行うアプリは拒否し得ます。
- security機構を偽装・回避する実装はしません。その条件が必須なら認定Android実機を選びます。

## 段階検証（順序を崩さない）

| 段階 | 成功条件 | 失敗条件 | 主な確認コマンド |
|---|---|---|---|
| 1. 調査 | binderfs/kernel/network制約を記録 | Wi-FiとLANを混同 | 本文、kernel config |
| 2. host単体 | container/sessionが再起動後もRUNNING | binder manager timeout、session crash | `waydroid status`, `journalctl` |
| 3. Docker実験 | nested LXCが再現可能にboot | privilegedでもmount/cgroup/LXC失敗 | experimental profile、`lxc-info` |
| 4. APK | packageがlistされlaunchする | ABI/署名/SDK error | `install-apk.sh`, `logcat` |
| 5. ADB | secure deviceが`device`状態 | `unauthorized`/offline | `adb devices -l` |
| 6. unicast | Androidからrouter/intercomへ応答/TCP成立 | hostだけ成功、Android失敗 | `test-network.sh all` |
| 7. discovery | 両方向packetが両interfaceで観測 | relay processだけ起動、packetなし | `tcpdump`, LAN peer |
| 8. SSID/API | 実測値を記録（通常Ethernet/unknown） | 推測値を成功扱い | `dumpsys wifi/connectivity` |
| 9. USB Wi-Fi | Linux scanとAndroid HALを別々に判定 | `iw`成功をAndroid成功扱い | `iw`, `nmcli`, `lshal`, Settings |
| 10. 常時運用 | cold boot、24h、network再接続後も回復 | 手動操作が必要、relay loop | systemd restart/journal/packet capture |

各段階の成果logを保存し、失敗した段階より後を「動作済み」としません。このrepositoryを作成した環境には
Waydroid対応kernel、Wi-Fi NIC、インターホンが提供されていないため、ここで行ったのはsource確認と静的検証です。

## 代替構成比較

凡例: ◎=自然に対応、○=構成次第、△=制約大、×=非対応。機種固有差は実機確認が必要です。

| 方式 | 実SSID選択 | 同一LAN検出 / Bcast / Mcast / mDNS | Play / ARM | 自動化 | 安定性 | Docker相性 | 難易度 |
|---|---:|---|---|---:|---:|---:|---:|
| host Waydroid + relay | × | ○ / △ / ○ / ○ | ○ / △ | ◎ | ○ | 操作系◎ | 中 |
| nested Docker Waydroid | × | △ / △ / △ / △ | ○ / △ | ○ | △〜× | × | 高 |
| USB Android実機 + ADB | ◎ | ◎ / ◎ / ◎ / ◎ | ◎ / ◎ | ◎ | ◎ | ADBのみ◎ | 低 |
| Wi-Fi ADB実機 | ◎ | ◎ / ◎ / ◎ / ◎ | ◎ / ◎ | ◎ | ○ | ADBのみ◎ | 低 |
| Android Studio Emulator | 擬似 | ○ / △ / △ / △ | image次第 / ○ | ◎ | ○ | △ | 中 |
| Android-x86/Bliss on KVM | HW次第 | ○ / ○ / ○ / ○ | image次第 / △ | ○ | ○ | △ | 高 |
| Anbox Cloud | × | network設計次第 | image次第 | ◎ | ◎(商用) | cloud-native | 高/有償 |
| KVM + USB Wi-Fi passthrough | HW/HAL次第 | ○ / ○ / ○ / ○ | image次第 | ○ | ○ | △ | 高 |
| Raspberry Pi Android | HW次第◎ | ◎ / ◎ / ◎ / ◎ | image次第 / ◎ | ○ | ○ | 操作系○ | 中〜高 |
| 常時給電Android実機 | ◎ | ◎ / ◎ / ◎ / ◎ | ◎ / ◎ | ◎ | ◎ | ADBのみ◎ | 低 |

対象アプリが実SSID、Play Integrity、ARM-only、物理LAN discoveryをすべて要求するなら、Android実機が優先です。

## 参照

- [Waydroid install instructions](https://docs.waydro.id/usage/install-on-desktops)
- [Waydroid upstream](https://github.com/waydroid/waydroid)
- [Waydroid application/ABI note](https://docs.waydro.id/usage/install-and-run-android-applications)
- [Google Play certification](https://docs.waydro.id/faq/google-play-certification)
- [Waydroid community extensions](https://docs.waydro.id/faq/community-projects-we-like)
