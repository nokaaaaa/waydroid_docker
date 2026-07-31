# ネットワーク設計

## 標準構成

Waydroid upstreamの`waydroid-net.sh`は`waydroid0` bridge（通常`192.168.240.1/24`）、dnsmasq、
forward rule、MASQUERADEを作ります。Androidはveth経由のprivate subnetです。このため:

- Android発のLAN/Internet unicastとその応答: 通常通る
- LAN発でAndroid private IPへ直接接続: route/NAT ruleなしでは通らない
- LAN broadcast: routerを越えず、Waydroid subnetへ届かない
- link-local multicast/mDNS/SSDP: 標準IP forwardingだけでは届かない
- Androidが物理LANの独立MAC/IPを持つ: いいえ

## Wi-Fi uplinkでの方式評価

### macvlan / Linux bridge

managed-mode Wi-Fi stationから別source MACを送るには通常の3-address frameでは情報が足りません。
APとclient/driver双方が4-address/WDSを扱う場合だけ透過bridge候補になります。家庭用APで保証できないため、
`wlan0`上のmacvlan/bridgeを自動設定しません。Ethernet uplinkなら第一候補として別途検証できます。

### ipvlan

L2 modeは外側でparent MACを共有できる利点がありますが、Wi-Fi driver、ARP/DHCP、multicast挙動と、
Waydroid内側LXC linkへの組込みを実機検証する必要があります。L3 modeはroutingには向く一方、L2 broadcast/
link-local multicastを自然には運びません。Compose networkへAndroid本体が直接接続されるわけでもありません。

### routed bridge / proxy ARP

AndroidへLAN rangeの/32をrouteし、hostがproxy ARPする構成はunicastの独立IP候補です。ただしAndroid側gateway、
hostの同一prefix二interface問題、routerのclient isolation、ARP fluxを解決する必要があります。broadcast domainは
統合されないためrelayは依然必要です。既定ではサイト固有IPを誤設定しないよう自動化していません。

`ENABLE_SAME_LAN_IP=yes`を明示した場合だけ、Androidの`eth0`へ物理LANの副IPを追加し、hostに
/32 routeと両interfaceのproxy ARPを設定します。既存のWaydroid DHCP addressはInternet/NAT用に残します。
指定IPはrouterのDHCP poolから除外し、`ip neigh`、別LAN端末からのping、親機へのAndroid発pingで重複と
往復疎通を確認してください。この方式でもbroadcast domain自体は結合されません。

### NAT + protocol relay（既定）

最小影響でhost Wi-Fiを維持できます。`setup-network.sh`はforwardingを整え、明示的に要求された場合だけ:

- Avahi: mDNS query/responseを`wlan0`と`waydroid0`間でreflect
- udp-broadcast-relay-redux: SSDP group/portまたは機器固有UDP portをrelay

します。Avahiは複数reflectorが輪になるとping-pongを起こすため1台だけで実行します。`socat`は固定宛先の
単方向試験には便利ですが、任意broadcastの完全な双方向transparent relayには使いません。source IP/portを書き換える
relayでは、発見後に送信元へunicast callbackするプロトコルが失敗する場合があります。

## 検証行列

| 発信 | 受信 | 必要な証拠 |
|---|---|---|
| Android | waydroid0 | Android app log + `tcpdump -ni waydroid0` |
| relay | wlan0 | 同じpayload/portを`tcpdump -ni wlan0` |
| LAN peer | wlan0 | peer送信log + wlan capture |
| relay | Android | waydroid0 capture + Android app receive log |

```bash
sudo tcpdump -ni wlan0 -vv 'udp port 5353 or udp port 1900 or udp port 37020 or igmp'
sudo tcpdump -ni waydroid0 -vv 'udp port 5353 or udp port 1900 or udp port 37020 or igmp'
ip maddr show
cat /proc/net/igmp
waydroid shell cat /proc/net/igmp
avahi-browse -art
```

UDP broadcastはLAN broadcast address（例`192.168.1.255`）を実際のprefixから計算します。例をそのまま使いません。
APのclient isolation/multicast enhancement、host firewall、Docker/Waydroid firewallも同時に確認します。

## 特定portをhostへ転送する場合

発見後のcallback先がrelay hostになる場合だけ、対象portをAndroid IPへDNAT/SNATする設計を検討します。
ポートとtransportが不明な状態で広範囲のDNATは行いません。packet captureから5-tupleを特定し、nftables ruleを
個別に作り、counterと削除手順を残します。

## USB Wi-Fiの使い道

追加adapterをhost側AP専用にし、Android/別端末用の管理subnetを構成するのは安定したrouting interfaceを増やす
方法です。ただし既存家庭LANと別broadcast domainならrelayが必要です。4-address対応AP/clientを両端管理できる
場合、専用adapterをWDS bridgeとして試験できます。Android HALへ渡す用途より、Linux hostがdriverと接続を管理する
用途を推奨します。

## 参照

- [Waydroid networking issues](https://docs.waydro.id/debugging/networking-issues)
- [Linux Wireless 4-address mode](https://wireless.docs.kernel.org/en/latest/en/users/documentation/iw.html)
- [Avahi reflector settings](https://manpages.ubuntu.com/manpages/noble/man5/avahi-daemon.conf.5.html)
- [udp-broadcast-relay-redux](https://github.com/udp-redux/udp-broadcast-relay-redux)
