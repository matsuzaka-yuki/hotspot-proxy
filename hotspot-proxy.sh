#!/system/bin/sh
# ============================================================================
# hotspot-proxy.sh — 让「热点 / USB 网络共享」的对端设备 TCP 流量走 mihomo 代理
# 需要 root。适用于 YumeBox / Clash Meta(root TUN + auto-redirect) 这类提供
# redir 端口的 mihomo 内核。
#
# 设计原则：**只做最小改动**
#   只在 nat PREROUTING 给"共享接口进来的 TCP"加一条 DNAT 到 mihomo redir 端口，
#   mihomo 用 SO_ORIGINAL_DST 还原目标 → 透明代理。其它流量（UDP/DNS/ICMP/IPv6）
#   一律不碰，完全走 Android 原厂路径，因此不可能把共享网络弄坏。
#
# 为什么不接管 UDP / 不加自定义路由表（v2 修正）：
#   1) 实测 YumeBox 的 TUN 规则不接管转发流量（`ip route get … iif <tif>` 不会落到
#      dev Yume），所以 UDP 本来就走原厂路径，无需干预；
#   2) v1 曾加 `ip rule iif <tif> lookup 4242`（自建直连表）+ ip6 REJECT，
#      既多余又危险：一旦接口识别错，会把上游接口的流量改道，导致整个共享断网。
#
# 用法（都要 root）：
#   hotspot-proxy.sh apply [iface]   应用规则（iface 可手动指定，便于测试）
#   hotspot-proxy.sh status          查看状态
#   hotspot-proxy.sh stop            撤销规则
#   hotspot-proxy.sh watch           常驻守护：跟随热点开关 / 代理重启自动增删
#
# 环境变量（可选）：REDIR_PORT=<n>  IFACE=<dev>
# ============================================================================

DIR=/data/adb/hotspot-proxy
STATE=$DIR/state
LOG=$DIR/hotspot-proxy.log
TAG=hspotproxy
PREF_REPLY=8991
# 共享接口命名（Android：ap_br_wlan0/softap0/swlan1/wlan2/rndis0/usb0/bt-pan…）
IFPAT='^(ap_br_wlan[0-9]+|ap_br_softap[0-9]+|softap[0-9]+|swlan[0-9]+|wlan[1-9][0-9]*|ap[0-9]+|rndis[0-9]+|usb[0-9]+|ncm[0-9]+|bt-pan)$'

IPT=/system/bin/iptables
IP6T=/system/bin/ip6tables
IP=/system/bin/ip

[ -d "$DIR" ] || mkdir -p "$DIR" 2>/dev/null

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG" 2>/dev/null; }

# ---------------------------------------------------------------- 探测 helpers
iface_ip4() { $IP -o -4 addr show dev "$1" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1; }

# main 表里该接口的子网，如 10.203.210.0/24
iface_net() { $IP route show table main 2>/dev/null | sed -n "s|^\([0-9][0-9./]*\) dev $1 .*|\1|p" | head -1; }

# 当前默认出口（= 共享的上游）
default_dev() { $IP route get 8.8.8.8 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1; }

# 候选接口是否可用作共享接口：有 IPv4、不是 lo、不是默认出口
valid_tif() {
    d=$1
    [ -z "$d" ] && return 1
    [ "$d" = lo ] && return 1
    [ "$d" = "$(default_dev)" ] && return 1
    [ -n "$(iface_ip4 "$d")" ] || return 1
    return 0
}

# 检测共享接口（按可信度排序）
find_tif() {
    if [ -n "${1:-}" ]; then
        if valid_tif "$1"; then echo "$1"; return 0; fi
        return 1
    fi
    # 1) Android 自己的 tethering 规则： "21000: from all iif wlan2 lookup wlan0"
    for d in $($IP rule 2>/dev/null | sed -n 's/^[0-9]*:[[:space:]]*from all iif \([^ ]*\) lookup [^ ]*.*/\1/p' | sort -u); do
        valid_tif "$d" && { echo "$d"; return 0; }
    done
    # 2) tetherctrl_FORWARD 链里出现的接口（两侧都收，再排除上游/lo）
    for d in $($IPT -t filter -S tetherctrl_FORWARD 2>/dev/null | grep -oE '\-(i|o) [^ ]+' | awk '{print $2}' | sort -u); do
        valid_tif "$d" && { echo "$d"; return 0; }
    done
    # 3) 名字特征兜底（仍然要求不是默认出口）
    for d in $($IP -o link show up 2>/dev/null | sed -n 's/^[0-9]*: \([^:@]*\).*/\1/p'); do
        echo "$d" | grep -Eq "$IFPAT" || continue
        valid_tif "$d" && { echo "$d"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------ mihomo redir 端口
# 端口要真的在 LISTEN，否则（代理已退出但 iptables 规则残留）会把客户端导到死端口
redir_alive() {
    p=$1
    hex=$(printf '%04X' "$p" 2>/dev/null) || return 1
    [ -z "$hex" ] && return 1
    grep -qiE ":$hex [0-9A-Fa-f]{8,32}:0000 0A " /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

detect_redir() {
    p=${1:-${REDIR_PORT:-}}
    if [ -z "$p" ]; then
        p=$($IPT -t nat -S 2>/dev/null | sed -n 's/.*-j REDIRECT --to-ports \([0-9]\{1,5\}\).*/\1/p' | head -1)
    fi
    [ -z "$p" ] && return 0
    redir_alive "$p" && echo "$p"
    return 0
}

state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1; }

# ---------------------------------------------------------------- 规则增删
del_ipt_rules() {
    n=0
    while [ "$n" -lt 20 ]; do
        spec=$($IPT -t nat -S PREROUTING 2>/dev/null | grep -- "--comment $TAG" | head -1)
        [ -z "$spec" ] && break
        $IPT -t nat -D PREROUTING ${spec#-A PREROUTING } 2>/dev/null || break
        n=$((n+1))
    done
    n=0
    while [ "$n" -lt 20 ]; do
        spec=$($IP6T -t filter -S FORWARD 2>/dev/null | grep -- "--comment $TAG" | head -1)
        [ -z "$spec" ] && break
        $IP6T -t filter -D FORWARD ${spec#-A FORWARD } 2>/dev/null || break
        n=$((n+1))
    done
}

del_routing() {
    n=0; while [ "$n" -lt 10 ]; do $IP rule del pref $PREF_REPLY 2>/dev/null || break; n=$((n+1)); done
}

# ---------------------------------------------------------------- 主操作
apply() {
    TIF=$(find_tif "${1:-${IFACE:-}}")
    if [ -z "$TIF" ]; then log "apply: 未找到共享接口（热点/USB 没开？）"; return 1; fi

    DEF=$(default_dev)
    # 硬保护：共享接口绝不可能是当前默认出口（v1 就是在这里翻车的）
    if [ "$TIF" = "$DEF" ]; then
        log "apply: 拒绝执行 —— 检测到的接口 $TIF 就是默认出口，判定为误检"
        return 4
    fi

    AP_IP=$(iface_ip4 "$TIF")
    AP_NET=$(iface_net "$TIF")
    REDIR=$(detect_redir)
    if [ -z "$REDIR" ]; then
        log "apply: 找不到可用的 mihomo redir 端口（代理未运行/未开 TUN/端口没人监听）"
        return 2
    fi

    # 清掉自己的旧规则再装
    del_ipt_rules
    del_routing

    # 回程保险：mihomo 从本地 redir socket 回给客户端的包，按 main 表路由
    [ -n "$AP_NET" ] && $IP rule add to "$AP_NET" lookup main pref $PREF_REPLY 2>/dev/null

    # 唯一的核心改动：共享接口进来的 TCP → mihomo redir 端口（透明代理）
    #   · 排除目标是本机共享网关的 TCP（客户端访问手机自身的服务）
    #   · 需要 route_localnet 才能 DNAT 到 127.0.0.1
    [ -w /proc/sys/net/ipv4/conf/"$TIF"/route_localnet ] && echo 1 >/proc/sys/net/ipv4/conf/"$TIF"/route_localnet
    [ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 >/proc/sys/net/ipv4/ip_forward
    $IPT -t nat -I PREROUTING 1 -i "$TIF" -p tcp ! -d "$AP_IP" \
        -m comment --comment $TAG -j DNAT --to-destination 127.0.0.1:"$REDIR"

    {
        echo "TIF=$TIF"; echo "AP_IP=$AP_IP"; echo "AP_NET=$AP_NET"
        echo "REDIR=$REDIR"; echo "UPSTREAM=$DEF"
        echo "TS=$(date '+%Y-%m-%d %H:%M:%S')"
    } >"$STATE"

    log "apply: tif=$TIF ap=$AP_IP net=$AP_NET redir=127.0.0.1:$REDIR upstream=$DEF"
    return 0
}

stop() {
    del_ipt_rules
    del_routing
    rm -f "$STATE"
    log "stop: 规则已清除"
}

status() {
    echo "== 状态文件 =="
    if [ -f "$STATE" ]; then cat "$STATE"; else echo "(无：规则未应用)"; fi
    echo
    echo "== 检测到的共享接口 =="
    t=$(find_tif); echo "${t:-（未检测到热点/USB 共享接口）}   （默认出口：$(default_dev)）"
    echo
    echo "== mihomo redir 端口 =="
    r=$(detect_redir); echo "${r:-（未找到或未监听 → 视为代理未开，共享流量直连）}"
    echo
    echo "== 本脚本的规则 =="
    $IPT -t nat -S PREROUTING 2>/dev/null | grep -- "--comment $TAG" || echo "(nat/PREROUTING: 无)"
    $IP rule 2>/dev/null | grep -E "^$PREF_REPLY:" || true
}

# watch：常驻守护。热点开→装；热点关→清；代理重启(redir 端口变)→重装
watch() {
    if [ -f "$DIR/watch.pid" ] && kill -0 "$(cat "$DIR/watch.pid" 2>/dev/null)" 2>/dev/null; then
        log "watch: 已有实例在运行 (pid $(cat "$DIR/watch.pid"))，退出"
        return 0
    fi
    echo $$ >"$DIR/watch.pid"
    log "watch: 启动 (pid $$)"
    while :; do
        cur=$(find_tif)
        redir=$(detect_redir)
        if [ -n "$cur" ] && [ -n "$redir" ]; then
            need=0
            [ "$cur" != "$(state_get TIF)" ] && need=1
            [ "$redir" != "$(state_get REDIR)" ] && need=1
            $IPT -t nat -S PREROUTING 2>/dev/null | grep -q -- "--comment $TAG" || need=1
            [ "$need" = 1 ] && apply "$cur" >/dev/null 2>&1
        elif [ ! -f "$STATE" ]; then
            : # 热点没开 或 代理没跑：什么都不做
        else
            log "watch: 代理或共享接口不可用，撤销规则 (tif=${cur:-无} redir=${redir:-无})"
            stop
        fi
        sleep 5
    done
}

case "${1:-status}" in
    apply)  shift; apply "${1:-}" ;;
    stop)   stop ;;
    status) status ;;
    watch)  watch ;;
    *)      echo "用法: $0 apply|stop|status|watch [iface]" >&2; exit 1 ;;
esac
