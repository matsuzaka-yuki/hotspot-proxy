# hotspot-proxy — 让热点 / USB 共享的对端设备走 mihomo 代理

设备：OnePlus/ColorOS, Android 16, root(Magisk/KernelSU 环境) + YumeBox(mihomo root TUN)
日期：2026-09-27

---

## 1. 为什么「手机有 TUN」但热点没有代理

Android 上代理走 TUN 只覆盖**本机 App**，共享（转发）出去的流量两条路都绕开了代理：

| 流量 | 走哪条路 | 结果 |
|---|---|---|
| 本机 App (uid≥10000) | 路由规则 `from 0.0.0.0 iif lo lookup 2022` → `dev Yume`，mihomo 再用 `iptables -t nat OUTPUT -o Yume -j REDIRECT --to-ports 39567` 抢走 TCP | ✅ 有代理 |
| root/system (uid 0-9999) | 规则 9000 直接跳过 VPN | 直连 |
| **热点客户端（转发）** | 内核转发路径**没有 uid**，YumeBox 那条 `not from all iif lo lookup 2022` 实测**不匹配转发包**；即使进了 TUN，mihomo 的 gvisor 栈也不认 | ❌ 直连（甚至被黑洞） |

本机实测结论（用 veth + netns 造假客户端验证）：

* 假客户端流量**不会**被 YumeBox 的 TUN 规则接管（`ip route get … iif veth-host` → `Network is unreachable`）；
* 共享接口在 `tetherctrl_FORWARD` 里被 Android 兜底 DROP（热点没开时）；
* 把 TCP `DNAT` 到 mihomo 的 redir 端口后，假客户端出口 IP 变成代理的香港出口 `141.11.146.70` —— **同一台手机自身的代理出口一致**，证明透明代理生效。

## 2. 方案（v2：最小改动）

`hotspot-proxy.sh` **只做一件事**，其余流量一律不碰：

1. **TCP → 代理**：`nat PREROUTING` 把共享接口进来的 TCP `DNAT` 到 `127.0.0.1:<mihomo redir 端口>`
   （目标为本机共享网关的 TCP 除外）。mihomo 用 `SO_ORIGINAL_DST` 还原原始目标，所以按域名/IP
   的分流规则照常生效（redir 端口从 `iptables -t nat -S` 里的 `REDIRECT --to-ports N` 自动识别，
   并校验端口真的在 LISTEN；YumeBox 每次重启端口会变，脚本能跟上）。
   需要 `net.ipv4.conf.<iface>.route_localnet=1`（脚本自动设置）。
2. **回程保险**：一条 `to <热点网段> lookup main` 的 ip rule。
3. UDP / DNS / ICMP / IPv6 全部**不做任何干预**，走 Android 原厂路径。

### 2.1 事故记录：v1 曾把整个共享弄断网（务必保留这条保护）

v1 除了 TCP 还额外加了「自建直连路由表 + `ip rule iif <tif> lookup 4242`」和「IPv6 FORWARD REJECT」。
结果**共享接口识别错**：v1 从 `tetherctrl_FORWARD` 链里抓接口名，抓到了 Android
`-i wlan0 -o wlan2` 里的**上游 wlan0**，于是规则全加到了手机 Wi-Fi 上联口上——
`ip rule iif wlan0 lookup 4242` 把从 wlan0 进来的回包全部改道，客户端彻底断网。

v2 的两处修正：

* **检测改成以 Android 自己的共享规则为准**：`ip rule` 里的 `from all iif <tif> lookup <upstream>`
  （本机为 `21000: from all iif wlan2 lookup wlan0`）→ 直接得到正确的共享口 `wlan2` 和上游 `wlan0`；
  并且强制要求「共享接口 ≠ 当前默认出口」，否则拒绝执行（硬保护）。
* **删掉多余的自建路由表和 IPv6 REJECT**：实测 YumeBox 的 TUN 根本不接管转发流量
  （`ip route get … iif <tif>` 不会落到 dev Yume），所以 UDP 本来就直连，不需要任何路由干预；
  多余的路由规则只会增加搞坏共享的风险。

> 教训：改共享/路由相关的东西，能做“加一条 DNAT”就绝不“改路由表”。

## 3. 安装位置

```
/data/adb/hotspot-proxy/hotspot-proxy.sh    # 主脚本（实际运行的那份）
/data/adb/hotspot-proxy/hotspot-proxy.log   # 日志
/data/adb/hotspot-proxy/state               # 当前生效状态
/data/adb/service.d/99-hotspot-proxy.sh     # 开机自启（Magisk service.d，常驻 watch）
~/hotspot-proxy/                            # 可编辑副本 + 本文档
$PREFIX/bin/hotspot-proxy                   # Termux 便捷入口
```

## 4. 用法

```bash
hotspot-proxy status          # 看状态（接口 / redir 端口 / 规则）
hotspot-proxy apply           # 手工应用一次
hotspot-proxy stop            # 撤销全部规则
hotspot-proxy watch           # 常驻守护（开机已自动启动）
# 临时把规则挂到某个接口上调试（例如自建 bridge/veth）：
hotspot-proxy apply veth-host
```

守护进程（`watch`）每 5 秒检查一次，自动处理：热点开/关、USB 共享插拔、**代理重启导致 redir
端口变化**、规则被系统清掉等情况。代理停掉时它会自动撤规则，让流量回落直连。

### 4.1 「YumeBox 开了才代理，关了不代理」—— 已实现并实测

判定条件有两条，必须**同时**成立才装规则：

1. 存在共享接口（热点/USB 已开）；
2. mihomo 的 redir 端口存在，**且该端口真的在 LISTEN**（读 `/proc/net/tcp` 校验）。
   第 2 条很关键：YumeBox 被杀掉时若 iptables 规则残留，只按规则探测会把客户端 DNAT
   到一个死端口 → 客户端所有 TCP 直接废掉。加了存活判定后，这种情况会正确回落直连。

实测（用 dummy 网卡模拟热点口 + 制造死端口模拟 YumeBox 退出）：

| 场景 | 结果 |
|---|---|
| YumeBox 开 + 热点开 | ~5s 内自动装规则（DNAT + ip rule + ip6 REJECT） |
| YumeBox 退出（redir 端口消失/没人监听） | ~10s 内自动撤光规则，客户端回到正常直连 |
| YumeBox 再开 | ~5s 内自动重新装上 |
| 热点关掉 | 自动撤销规则 |
| 代理重启导致端口变化（如 39567 → 4xxxx） | 自动改用新端口重装 |

注意：撤销规则时脚本**不会**去动 `net.ipv4.ip_forward`（那是 Android 共享自己的开关，
乱改会把正在工作的热点弄坏）。

## 5. 实际验证步骤

1. 打开热点，让另一台设备连上。
2. 在客户端看出口 IP（如 <https://ip.sb> / `curl ip.sb`）：
   * 应该是**代理的出口**（本机代理出口当前为 `141.11.146.70`，HK）；
   * 关掉代理再刷新，应变成运营商/家里的真实出口。
3. 本机自检：
   ```bash
   hotspot-proxy status          # TIF / REDIR 应该有值
   su -c 'iptables -t nat -S PREROUTING'   # 看到 hspotproxy 的 DNAT 规则
   ```
4. 反向验证 UDP 是直连（设计如此）：客户端 `nslookup baidu.com 223.5.5.5` 可用，
   但 `1.1.1.1:53` 这类直连被墙的会失败（因为它没走代理）。

## 6. 已知限制 / 可选增强

* **UDP 不走代理**（QUIC、游戏、VoIP 直连）。要全量 UDP：
  * 方案 A：Termux 装 `sing-box`，做 `tproxy` 入站 → `socks5 127.0.0.1:7891`（mihomo 的 socks 口），
    再给共享接口加 `TPROXY` 规则（`iptables -j TPROXY` 本机可用，已实测支持）；
  * 方案 B（最省事，客户端少时可优先）：在 YumeBox 里打开「允许局域网」，
    客户端直接配 `HTTP 192.168.x.1:7890` / `SOCKS5 192.168.x.1:7891`，
    SOCKS5 带 `UDP ASSOCIATE`，UDP 也能代理。
* **客户端 DNS 目前走手机自己的解析**（Android 给客户端下发的 DNS 是热点网关，由 dnsmasq 直接解析），
  可用但可能被污染。要让 DNS 也走代理，可给 mihomo 配 `dns.listen` 后把客户端的 53 端口 DNAT 过去。
* 若以后换代理 App：只要它仍用「iptables REDIRECT 到本地 redir 端口」这套（本机 FlClash 同机制），
  脚本无需改动；若换成纯 SOCKS 端口，需要改用 sing-box/redsocks 做端口转换。
* 顺带一提：`/data/adb/service.d/boxproxy-box.sh` 是已卸载的 `com.boxproxy.box` 留下的，
  每次开机都会空等（最多 12 小时）。不需要的话可以删掉：`su -c 'rm /data/adb/service.d/boxproxy-box.sh'`。

## 7. 卸载

```bash
hotspot-proxy stop
su -c 'pkill -f "hotspot-proxy.sh watch"; rm -f /data/adb/service.d/99-hotspot-proxy.sh; rm -rf /data/adb/hotspot-proxy'
rm -f $PREFIX/bin/hotspot-proxy
```
