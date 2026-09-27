#!/system/bin/sh
# 开机自启：常驻守护，热点开/关 或 代理重启(redir 端口变化) 时自动维护规则
# 由 hotspot-proxy.sh 安装；日志见 /data/adb/hotspot-proxy/hotspot-proxy.log
(
  sleep 15
  exec /data/adb/hotspot-proxy/hotspot-proxy.sh watch
) >/dev/null 2>&1 &
exit 0
