# hotspot-proxy

Route **tethered (Wi-Fi hotspot / USB / Bluetooth) client traffic through a root mihomo
proxy** on Android.

> 中文说明见 [README.md](README.md)（更详细，含排障与事故记录）

Tested on: OnePlus / ColorOS, **Android 16**, Magisk/KernelSU, mihomo client running in
**root TUN + auto-redirect** mode (e.g. [YumeBox](https://github.com/yumeyucca/YumeBox),
Clash Meta based clients).

## The problem

A VPN/TUN proxy on Android only captures traffic from **apps on the phone itself**:

| Traffic | Path | Proxied? |
|---|---|---|
| Local apps (uid ≥ 10000) | routing rule `from 0.0.0.0 iif lo lookup <vpn-table>` → `dev <tun>`, then mihomo grabs TCP with `iptables -t nat OUTPUT -o <tun> -j REDIRECT --to-ports <redir>` | ✅ |
| **Tethering clients (forwarded)** | kernel forwarding path has **no uid**, and the app's TUN rules don't match ingress-on-`<tether-iface>` packets at all | ❌ |

So the hotspot gets plain, unproxied internet (or, in some setups, nothing).

## How it works (v2: minimal change)

The script adds **one** iptables rule:

```
iptables -t nat -I PREROUTING 1 -i <tether-iface> -p tcp ! -d <gateway-ip> \
    -m comment --comment hspotproxy -j DNAT --to-destination 127.0.0.1:<mihomo-redir-port>
```

plus `net.ipv4.conf.<tether-iface>.route_localnet=1` (needed to DNAT to loopback) and one
reply-path `ip rule`. mihomo recovers the original destination via `SO_ORIGINAL_DST`, so all
of your domain/IP routing rules keep working.

Everything else — **UDP, DNS, ICMP, IPv6** — is left completely untouched and follows stock
Android tethering. This makes it impossible for the script to break your hotspot.

The redir port is auto-detected from `iptables -t nat -S` (`REDIRECT --to-ports N`) and
**verified to be actually listening** (`/proc/net/tcp`), because mihomo picks a new random
port on every restart, and because a stale rule pointing at a dead port would break all
client TCP.

## Requirements

* Android with **root** (Magisk / KernelSU / APatch — anything with `/data/adb`)
* `iptables` (present on stock Android) and `ip` (toybox)
* A mihomo-based proxy in root TUN mode that exposes a redir port
  (mihomo's `auto-redirect` does this automatically)

## Install

```sh
su -c 'sh install.sh'
```

Installs to `/data/adb/hotspot-proxy/`, adds a boot supervisor at
`/data/adb/service.d/99-hotspot-proxy.sh`, and a `hotspot-proxy` command for Termux.

## Usage

```sh
hotspot-proxy status     # detected tether iface / upstream / redir port / rules
hotspot-proxy apply      # apply manually once
hotspot-proxy stop       # remove all rules
hotspot-proxy watch      # daemon (already started at boot)
hotspot-proxy apply veth0   # test against an arbitrary interface
```

The `watch` daemon polls every 5 s and handles: hotspot on/off, USB/BT tethering, **proxy
restart** (redir port changes), rules wiped by the system. When the proxy is not available
(no listening redir port) it removes the rules so clients fall back to normal direct
tethering.

## Verify

1. Turn the hotspot on, connect a client.
2. On the client, check the egress IP (e.g. <https://ip.sb>) — it should be your **proxy's**
   exit IP; turn the proxy off and refresh — it should become your carrier/home IP.
3. On the phone: `hotspot-proxy status`, and check mihomo's connections API for connections
   with `sourceIP` = the client's address.

## Limitations

* **UDP is not proxied** (QUIC, games, VoIP go direct). Options for full UDP:
  * configure the client with `SOCKS5 <gateway>:<socks-port>` (mihomo's SOCKS5 supports
    `UDP ASSOCIATE`);
  * or build a TPROXY bridge (Termux `sing-box` tproxy inbound → `socks5 127.0.0.1:<socks-port>`).
* DNS for clients is resolved by the phone's tethering DNS server (works, but is not
  tunneled).
* IPv6 is not proxied.

## Notes / incident record

v1 of this script also installed a custom routing table + `ip rule` and an IPv6 FORWARD
REJECT. It then **mis-detected the tether interface** (it read `-i wlan0` out of Android's
`tetherctrl_FORWARD` rule `-i wlan0 -o wlan2`, i.e. the *upstream* side) and installed those
rules on the Wi-Fi STA uplink, which broke all client traffic.

Fixes: detect the interface from Android's own tethering rule (`from all iif <tif> lookup
<upstream>`), hard-refuse when the candidate equals the current default-route device, and
drop the routing/IPv6 meddling entirely (verified unnecessary: the TUN does not capture
forwarded traffic anyway).

**Lesson:** for anything tethering/route related, prefer "add one DNAT rule" over
"rewrite the routing tables".

## License

MIT
