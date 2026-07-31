# Wi-Fi、SSID、USB adapterの制約

## 「Wi-Fi」の二つの意味

1. Android Settingsが周囲のAPをscanし、SSID/BSSID/RSSIを表示し、Android自身のwpa_supplicant/HALでassociateする
2. Android appがhostのnetwork経由でLAN機器とIP通信する

Waydroid標準構成が提供するのは2です。1は提供しません。Waydroid device treeはWi-Fi feature XMLを含み得ますが、
物理NIC固有のvendor Wi-Fi HAL、firmware、control socketを備えた実機device imageではありません。機能flagの存在は
scan/association能力の証明になりません。

## Android APIから見える値

実値はimageごとに次で保存します。

```bash
waydroid shell pm list features | grep -E 'wifi|ethernet'
waydroid shell dumpsys connectivity
waydroid shell cmd wifi status
waydroid shell dumpsys wifi
waydroid shell ip -br addr
waydroid shell getprop | grep -iE 'wifi|dhcp|ethernet'
```

予想されるtransportはEthernet/vethです。`WifiManager.getConnectionInfo()`は未接続、disabled、
`<unknown ssid>`、無効BSSIDなどになり得ます。Androidのprivacy制限上、実機でもSSID取得にはlocation permission/
location service等が必要なversionがありますが、権限を与えてもWaydroidにscan HALがなければ物理SSIDは出ません。
`DhcpInfo`もWi-Fi APIでは空でも、`ip addr`上のEthernet IPは存在し得ます。

`WifiManager.MulticastLock`はtest APKが`CHANGE_WIFI_MULTICAST_STATE`を宣言して取得・受信まで試す必要があります。
lock objectを取得できてもkernel interface、routing、relayを越えてpacketが到達する証明にはなりません。

## USB Wi-FiをDockerへ渡す検証

`--device`は主にcharacter/block device nodeをbindする機能です。Wi-Fiのdata planeは`/dev/ttyUSB*`のようなnodeではなく、
host kernel driverが作るnetwork interfaceとcfg80211/netlinkです。USB bus nodeを`--device=/dev/bus/usb/...`で見せても、
host driverにbindされたwlan interfaceはcontainerのnetwork namespaceへ自動移動しません。

実験手順は次のように分離します。

1. hostで`lsusb`, `ethtool -i wlanX`, `iw phy`, `iw dev`を記録
2. host NetworkManagerからadapterを明示的にunmanage/disconnect
3. container PIDのnetwork namespaceへPHY/interfaceを移動（driver対応とhost `CAP_NET_ADMIN`が必要）
4. container内に`iw`, `wpa_supplicant`またはNetworkManager、firmwareを用意
5. container内でのみ`iw dev`, `nmcli dev wifi list`を検証

概念確認コマンド（本番hostのuplinkでは実行しない）:

```bash
nmcli device status
iw phy
# sudo nmcli device set <usb-wlan> managed no
# sudo iw phy <phy> set netns <container-init-pid>
# docker exec <container> iw dev
# docker exec <container> nmcli dev wifi list
```

driverとfirmware loadingはhost kernelが管理し、association/controlはinterfaceを所有するnamespaceの
wpa_supplicant/NetworkManagerが管理します。同じinterfaceをhost NetworkManagerとcontainer側daemonが同時操作すると
競合します。

## なぜAndroid Settingsへさらに渡せないか

外側Docker namespaceで`iw` scanに成功しても、Waydroidはその内側に別LXC/net namespaceとAndroid frameworkを持ちます。
Androidから物理radioを操作するには少なくとも:

- PHY/interfaceを内側Android namespaceへ割当
- compatible firmware/kernel driver
- Android Wi-Fi AIDL/HIDL HALとvendor implementation
- `wificond`/supplicant/HAL service、SELinux policy、VINTF manifest
- interface naming、permissions、rfkill、regulatory domain統合

が必要です。標準Waydroid imageには任意USB chipset用のこの統合がありません。Linux側wpa_supplicantに接続させた後に
vethでAndroidへroutingしても、それは「host/LinuxがWi-Fi接続しAndroidはEthernetを使う」構成であり、Settingsから
SSIDを選ぶ構成ではありません。

Android imageをdevice固有に再buildしてHALを実装することは研究開発として理論上可能ですが、このrepoの汎用構築・
安定運用範囲外です。物理SSIDが必須なら、USB passthroughしたKVM Android-x86/BlissもHAL/driver対応を事前確認するか、
対応が明確なAndroid実機を使用します。

## 認証アプリへの影響

アプリが単にLAN内機器をUDP/mDNSで探索するならrelayで成立する可能性があります。アプリが次のいずれかを必須にする
場合はWaydroidを不適合と判断します。

- `NetworkCapabilities.TRANSPORT_WIFI`が必須
- 実SSID/BSSIDと機器側SSIDを比較
- Wi-Fi scan result、RSSI、DHCP gatewayを検証
- hardware attestation、Play Integrity、認定buildを要求
- emulator/container/root/native bridgeを拒否

これらを偽装してsecurity checkを回避しません。

## 参照

- [Waydroid device tree](https://github.com/waydroid/android_device_waydroid_waydroid)
- [Linux Wireless virtual interfaces](https://wireless.docs.kernel.org/en/latest/en/users/documentation/iw/vif.html)
- [Android Wi-Fi permissions guidance](https://developer.android.com/develop/connectivity/wifi/wifi-permissions)
