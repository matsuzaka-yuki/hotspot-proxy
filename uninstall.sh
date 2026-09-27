#!/system/bin/sh
# uninstall.sh — 卸载 hotspot-proxy（需要 root）。只删自己的文件，不动 Android 共享配置。
set -u

if [ "$(id -u)" != "0" ]; then
    echo "需要 root：su -c 'sh $0'"
    exit 1
fi

DEST=/data/adb/hotspot-proxy
SERVICE=/data/adb/service.d

[ -x "$DEST/hotspot-proxy.sh" ] && "$DEST/hotspot-proxy.sh" stop
[ -f "$DEST/watch.pid" ] && kill "$(cat "$DEST/watch.pid")" 2>/dev/null

rm -f "$SERVICE/99-hotspot-proxy.sh"
rm -rf "$DEST"
rm -f /data/data/com.termux/files/usr/bin/hotspot-proxy

echo "已卸载。共享接口的 route_localnet 保持原样（无害），Android 共享功能未被改动。"
