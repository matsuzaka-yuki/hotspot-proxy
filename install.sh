#!/system/bin/sh
# install.sh — 安装 hotspot-proxy（需要 root）
#   su -c 'sh /path/to/install.sh'
set -u

SRC=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" != "0" ]; then
    echo "需要 root：su -c 'sh $SRC/install.sh'"
    exit 1
fi
if [ ! -d /data/adb ]; then
    echo "/data/adb 不存在 —— 需要 Magisk / KernelSU / APatch 之类的 root 环境"
    exit 1
fi

DEST=/data/adb/hotspot-proxy
SERVICE=/data/adb/service.d
mkdir -p "$DEST" "$SERVICE"

cp "$SRC/hotspot-proxy.sh" "$DEST/hotspot-proxy.sh"
chmod 755 "$DEST/hotspot-proxy.sh"

cp "$SRC/contrib/99-hotspot-proxy.sh" "$SERVICE/99-hotspot-proxy.sh"
chmod 755 "$SERVICE/99-hotspot-proxy.sh"

# Termux 便捷入口（存在才装）
PREFIX_BIN=/data/data/com.termux/files/usr/bin
[ -d "$PREFIX_BIN" ] && cp "$SRC/contrib/hotspot-proxy" "$PREFIX_BIN/hotspot-proxy" && chmod 755 "$PREFIX_BIN/hotspot-proxy"

# 立刻尝试应用一次，并启动常驻守护（开机也会由 service.d 自动启动）
"$DEST/hotspot-proxy.sh" apply >/dev/null 2>&1 || true
( "$SERVICE/99-hotspot-proxy.sh" >/dev/null 2>&1 & )

echo "已安装到 $DEST"
"$DEST/hotspot-proxy.sh" status
