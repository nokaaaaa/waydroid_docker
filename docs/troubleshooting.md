# トラブルシューティング

## 証拠を先に採取

```bash
uname -a
waydroid --version
waydroid status
sudo waydroid log > waydroid.log
sudo journalctl -b -u waydroid-container.service -u waydroid-docker.service > journal.log
ip -d link show waydroid0
ip route
sudo nft list ruleset > nft.log
```

## binder Service Managerが現れない

```bash
grep -E 'CONFIG_ANDROID_BINDER(_IPC|FS)=' /boot/config-"$(uname -r)"
sudo modprobe binder_linux
grep binder /proc/filesystems
sudo ./scripts/setup-binder.sh
ls -la /dev/binderfs
```

kernel configが無効ならDocker image内のpackage追加では直りません。対応Ubuntu generic/HWE kernelへ変更してrebootします。
外側Docker内だけで`modprobe`してもmoduleはhost kernelへloadされるため、hostのmodule/configが必要です。

## sessionは起動するが画面/ADBが出ない

```bash
systemctl status waydroid-docker.service
sudo journalctl -u waydroid-docker.service -n 200
sudo -u "$(grep '^WAYDROID_USER=' /etc/default/waydroid-headless | cut -d= -f2)" \
  ls -la /run/user/*/waydroid-0
cat ~/waydroid-headless.log
```

Weston backend名、`XDG_RUNTIME_DIR` ownership、D-Bus sessionを確認します。GPU errorならSwiftShader設定を試します。
Software renderingは起動可能性を上げますが性能とcodec/scrcpy成功を保証しません。

## ADB unauthorized/offline

```bash
waydroid adb disconnect || true
adb kill-server
waydroid adb connect
adb devices -l
```

host ADB、Docker named volume、外部PCはそれぞれ別鍵です。Android側で各fingerprintを承認します。鍵fileをrepositoryへ
コピーしません。proxyのtarget IPがdnsmasq leaseと一致するかも確認します。

## AndroidからInternet/LANへ出られない

```bash
ip addr show waydroid0
cat /var/lib/misc/dnsmasq.waydroid0.leases
sysctl net.ipv4.ip_forward
sudo iptables --list-rules | grep FORWARD || true
sudo nft list ruleset
waydroid shell ip route
```

UFW/firewalldのforward policyとWaydroid公式networking guideを確認します。全体を無条件`ACCEPT`にする前に、
`waydroid0`とLAN interfaceに限定したruleを設計します。

## mDNS/SSDP/broadcastが見えない

```bash
systemctl status avahi-daemon
grep -E 'allow-interfaces|enable-reflector|reflect-ipv' /etc/avahi/avahi-daemon.conf
avahi-browse -art
ip maddr show wlan0
ip maddr show waydroid0
sudo ./scripts/test-network.sh capture 30
```

次を区別します: Androidが送っていない、waydroid0には出たがrelayが拾わない、wlan0には出たがAPが落とす、
LAN responseが戻らない、Android appが受信しない。AvahiはmDNS専用でSSDP/任意broadcastを中継しません。
reflector loopがある場合は全reflectorを止め、1台だけ再有効化します。

## appがinstall/launchしない

```bash
aapt dump badging app.apk | grep -E 'package:|native-code:' || true
waydroid shell getprop ro.product.cpu.abilist
waydroid app install app.apk
waydroid logcat '*:W'
```

ABI、minSdk、split APK、署名、Play services、DRM/Integrityを確認します。`.apks`/`.xapk`は単一APKではないため
`install-apk.sh`の対象外です。ARM translation追加後もすべてのnative libraryが動くとは限りません。

## nested Docker固有

```bash
docker compose --profile experimental ps
docker compose logs nested-waydroid
docker compose exec nested-waydroid mount
docker compose exec nested-waydroid stat -fc %T /sys/fs/cgroup
docker compose exec nested-waydroid lxc-checkconfig
```

`Operation not permitted`、read-only cgroup、binder mount、nested AppArmor、network namespace errorは外側の隔離と内側LXCの
衝突です。privilegedをさらに拡張して本番化せず、host-native構成へ戻します。

## recovery

停止してdataを保つ:

```bash
sudo ./scripts/cleanup.sh
sudo systemctl start waydroid-container.service waydroid-docker.service
```

完全削除はREADMEの確認付き`--purge-data`だけを使います。実行前に`/var/lib/waydroid`を別filesystemへbackupし、
Google/アプリ側の再認証可否を確認してください。
