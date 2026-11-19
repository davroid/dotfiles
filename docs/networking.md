# Networking on `davarch`

Status: applied 2026-11-18 on `davarch` (see §11 changelog). Apply (or
re-apply after edits) with `sudo ~/dotfiles/system/install.sh`; §7 lists the
checks to run afterwards.
The source of truth for replay lives in `system/` in this repo; this
document explains the *why* as well as the *what*.

Host: ASUS TUF Gaming A15 (`davarch`), Arch Linux, kernel 6.18.x-lts.

---

## 1. Summary

| Layer | What runs | Why |
|---|---|---|
| Link | `wlan0` (MediaTek MT7921, Wi-Fi 6) on SSID `JARZ`, DHCP `192.168.1.46/24` | primary NIC; `enp2s0` (Realtek RTL8111) is down |
| Manager | NetworkManager + dhcpcd, `dns=none` | never rewrites `/etc/resolv.conf`, so Unbound cannot be bypassed |
| VPN | Cloudflare WARP (`cloudflare-warp-bin`), MASQUE/HTTP3, mode `TunnelOnly`, split-tunnel excludes RFC1918 | full-tunnel for public traffic, LAN stays local |
| DNS | Unbound on `127.0.0.1:53`, DNSSEC validating, DoT to Cloudflare, automatic plaintext fallback | one resolver, encrypted by default, survives a blocked 853/tcp |
| Firewall | nftables, `inet filter`, default-deny inbound | closes clearnet listeners; keeps LAN services usable |
| Exit | Cloudflare edge (currently `loc=CO`), IPv6 only via WARP (wlan0 has no global v6) | verified with `cloudflare.com/cdn-cgi/trace` |

```
                        ┌──────────────── davarch ────────────────┐
  apps ──► 127.0.0.1:53 │ unbound ── DoT :853 ──┐                  │
                        │   └ fallback :53 (1.1.1.1) when 853 dies │
  apps ──► route rule   │                          │               │
          32765         │  table 65743 ──► CloudflareWARP tun ─────┼──► MASQUE/UDP:443 ──► 192.168.1.1
                        │  fwmark 0x100cf ──► wlan0 (tunnel carrier)│
                        │  LAN (RFC1918) ──► wlan0, never tunneled  │
                        └──────────────────────────────────────────┘
```

---

## 2. The problem this fixes

Two separate failures were observed.

### 2.1 Real IP leaking / WARP "sometimes starts disconnected"

`warp-svc.service` shipped by the package is only `After=pre-network.target`,
so the daemon starts before Wi-Fi has a lease. From the boot log of
2026-11-18:

| Time | Event |
|---|---|
| 21:34:13 | `warp-svc` starts; NTP sync fails, DNS for `api.cloudflareclient.com` fails (`NoConnections`) |
| 21:34:17 | `wlan0` receives its DHCP lease |
| 21:34:18 | WARP sees the new network → `Disconnecting before reconnect reason=NetworkChanged` → `Disconnected(Manual)`, `firewall::engine: Firewall unloaded` |
| 21:34:18 → 21:50:44 | **~16 minutes with no tunnel**: policy rule `32765`, table `65743` and the tun routes are gone, so traffic falls through to `main` → `wlan0` → ISP → real IP |
| 21:50:44 | Connects, but only because something re-ran `warp-cli connect` |

So the leak was **state-dependent, not a misroute**: when WARP is up, the
policy rule forces everything through the tunnel; when it is down, it
deliberately tears the rule down and traffic leaks.

Fix = start WARP after the network exists, and re-assert the connection.

### 2.2 DNS fallback was counter-productive

The old `unbound.conf` used `forward-first: yes`, i.e. "if the DoT
forwarders fail, recurse from the root servers in plaintext". Measured on
this network:

| Probe | Result |
|---|---|
| `openssl s_client -connect 1.1.1.1:853` | works, TLSv1.3, cert `cloudflare-dns.com`, verification OK |
| `dig @1.1.1.1 example.com` | works |
| `dig @8.8.8.8 example.com` | **times out** — WARP only permits Cloudflare on port 53 |

So the recursion fallback could only ever hang; the user-visible symptom
would be "DNS is broken" during any DoT hiccup. The fallback is now an
explicit, verified plaintext path to `1.1.1.1`, activated only when
`853/tcp` is unreachable.

---

## 3. Design decisions

| Decision | Choice | Reason |
|---|---|---|
| DNS fallback | watchdog that swaps the forward zone, not mixed forwarders | Unbound load-balances across all `forward-addr` entries in a zone, so mixing plain and TLS would send ~half the queries in plaintext *always*. A swap is a real fallback. |
| DoT failure behaviour | `forward-first: no` | the recursion path is unusable on this network (see 2.2) and would leak plaintext queries outside the encrypted path |
| Firewall | native nftables, extending the packaged `/etc/nftables.conf` | already installed, no new daemon, full control over `iifname`/multicast matching |
| LAN exposure | LocalSend `53317` + mDNS `5353`, Syncthing `22000/21027` | those are the services actually used across devices |
| bitcoind `8333` | **closed** | `~/.bitcoin/bitcoin.conf` has `onlynet=onion`, `proxy=127.0.0.1:9050`, `listenonion=1`; the node is Tor-only, the clearnet listener is dead weight |
| WARP down behaviour | fail **open** | no kill switch: if the tunnel drops you keep internet; the timer reconnects within 60s. Chosen over fail-closed to avoid self-lockout. |
| Alternate VPN | Proton VPN via the official CLI, mutually exclusive with WARP | the CLI drives NetworkManager (`proton0`) and keeps DNS untouched; WARP's `lookup 65743` rule outranks Proton's main-table default route, so a switcher disables one before enabling the other (§10) |
| SSH | not opened | no `sshd` is listening; rule is commented in the firewall for later |

---

## 4. Repository layout

```
system/
├── install.sh                                  # idempotent installer (sudo)
├── rollback.sh                                 # undo everything (sudo)
├── switch-vpn.sh                               # warp | proton | none | status
├── etc/
│   ├── nftables.conf                           # host firewall
│   ├── systemd/system/
│   │   ├── warp-connect.service                # oneshot: ensure WARP connected
│   │   ├── warp-connect.timer                  # every 60s
│   │   ├── unbound-dns-fallback.service        # oneshot: check 853/tcp
│   │   ├── unbound-dns-fallback.timer          # every 30s
│   │   └── warp-svc.service.d/
│   │       └── 10-network-order.conf           # order WARP after the network
│   └── unbound/conf.d/
│       ├── 10-forward-dot.conf                 # active: Cloudflare DoT
│       └── 20-forward-plain.conf.disabled      # inactive: Cloudflare plain
└── usr/local/
    ├── bin/warp-ensure-connected               # idempotent connect helper
    └── sbin/unbound-dns-fallback               # DoT/plaintext state machine
```

Inventory installed on the live system:

| Repo path | Installed to |
|---|---|
| `system/etc/systemd/system/warp-svc.service.d/10-network-order.conf` | same path |
| `system/etc/systemd/system/warp-connect.{service,timer}` | same path |
| `system/usr/local/bin/warp-ensure-connected` | same path (0755) |
| `system/etc/unbound/conf.d/*` | `/etc/unbound/conf.d/` |
| `system/usr/local/sbin/unbound-dns-fallback` | same path (0755) |
| `system/etc/systemd/system/unbound-dns-fallback.{service,timer}` | same path |
| `system/etc/nftables.conf` | `/etc/nftables.conf` |
| `system/switch-vpn.sh` | `/usr/local/sbin/switch-vpn` (0755) |

`install.sh` also edits `/etc/unbound/unbound.conf` in place:

1. comments out the old inline `forward-zone:` block (prefixed with
   `# (disabled by dotfiles/system)`),
2. appends `include-toplevel: "/etc/unbound/conf.d/*.conf"`.

Both operations are guarded and idempotent, and every modified file is
backed up as `<file>.bak.YYYYmmdd-HHMMSS`.

---

## 5. Replay on a fresh machine

### 5.1 Packages

```bash
sudo pacman -S --needed networkmanager unbound nftables openssl bind
# WARP is AUR:
yay -S cloudflare-warp-bin     # provides warp-svc + warp-cli
# Optional, only for `switch-vpn proton`:
sudo pacman -S --needed proton-vpn-cli
```

`bind` is only needed for `dig` in the verification steps. `proton-vpn-cli`
pulls in `proton-vpn-daemon`, `python-proton-*` and uses NetworkManager as its
backend; no extra configuration is required for it to coexist with this setup
(see §10).

### 5.2 Prerequisites / assumptions

- NetworkManager manages the interface and `/etc/NetworkManager/NetworkManager.conf`
  contains `dns=none` (otherwise NM overwrites `/etc/resolv.conf` and Unbound
  is bypassed).
- The WARP client is registered (`warp-cli registration show` prints an
  account). Registration is not automated here.
- `warp-cli` mode is `TunnelOnly` (DNS stays with Unbound). That is the
  existing consumer default in this setup; no change is made.
- Adjust `define LAN_IFS` in `etc/nftables.conf` if the NIC names differ
  (`ip -br link`).

### 5.3 Install

```bash
cd ~/dotfiles/system
sudo ./install.sh
```

What it does, in order:

1. verifies `systemd`, `warp-cli`, `unbound-checkconf`, `nft` exist;
2. installs the WARP drop-in and reconnect timer, restarts `warp-svc`,
   starts `warp-connect.service`;
3. installs the Unbound drop-ins, patches `unbound.conf`, runs
   `unbound-checkconf`, reloads Unbound, enables the fallback timer;
4. validates the firewall with `nft -c -f` **before** copying it, then
   installs and restarts `nftables.service`;
5. installs `switch-vpn` to `/usr/local/sbin/` (warns if `protonvpn` is
   missing);
6. prints verification output (WARP status, `ip rule`, exit IP, DNS answer,
   input chain, remaining listeners).

### 5.4 Rollback

```bash
cd ~/dotfiles/system
sudo ./rollback.sh
```

It disables the timers and `nftables.service`, removes the installed files
(including `/usr/local/sbin/switch-vpn`), restores the newest
`unbound.conf` / `nftables.conf` backup, flushes the ruleset and restarts
`warp-svc`. It never touches Proton VPN units or connections.

---

## 6. How each piece works

### 6.1 WARP boot ordering — `10-network-order.conf`

```ini
[Unit]
After=NetworkManager-wait-online.service network-online.target unbound.service
Wants=NetworkManager-wait-online.service network-online.target unbound.service
```

The drop-in overrides nothing else from the packaged unit. With this,
`warp-svc` no longer sees "network appeared" mid-initialisation, which is
what produced `Disconnected(Manual)` at 21:34:18.

### 6.2 WARP reconnect — `warp-connect.{service,timer}`

`warp-ensure-connected` is idempotent:

```sh
warp-cli --accept-tos status | grep -q '^Status update: Connected' && exit 0
warp-cli --accept-tos connect
```

The service runs at boot (`WantedBy=multi-user.target`) and the timer
re-runs it every 60s (`OnBootSec=30s`, `OnUnitActiveSec=60s`). This covers:

- early-boot races that still end in `Disconnected(Manual)`;
- resume from suspend and Wi-Fi roaming, where this client version tends to
  drop the tunnel without retrying.

Note: this `warp-cli` (2026.8.2115.0) has **no top-level `always-on`
subcommand** — `connect` is the persistent "maintain whenever possible"
state, which is why the timer exists.

`Mode: TunnelOnly` is intentional: WARP only carries packets; DNS stays
local in Unbound. Do not switch to `warp+doh` unless you also stop Unbound.

### 6.3 Unbound — DoT with a real fallback

`/etc/unbound/unbound.conf` (patched) ends with:

```
include-toplevel: "/etc/unbound/conf.d/*.conf"
```

Active state (`10-forward-dot.conf`):

```
forward-zone:
    name: "."
    forward-first: no
    forward-tls-upstream: yes
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com
```

Fallback (`20-forward-plain.conf.disabled`, only renamed to `.conf` while
in use):

```
forward-zone:
    name: "."
    forward-first: no
    forward-tls-upstream: no
    forward-addr: 1.1.1.1
    forward-addr: 1.0.0.1
```

`unbound-dns-fallback` (timer, 30s) probes
`openssl s_client -connect 1.1.1.1:853 -servername cloudflare-dns.com`:

- reachable → ensure DoT active, plaintext disabled;
- unreachable → disable DoT, enable plaintext;
- before every reload: `unbound-checkconf` **and** `unbound-control reload`;
  on any failure the rename is undone, so DNS never ends up with no zone.

`unbound-checkconf` tolerates a duplicate `forward-zone` by ignoring the
second one (no error), so the strict "exactly one active file" rule matters:
both active would silently keep DoT.

Gotcha for anyone reimplementing the probe: `openssl s_client -brief` writes
its report to **stderr**. The redirect must be `2>&1` *before* the pipe:

```sh
openssl s_client -connect 1.1.1.1:853 -servername cloudflare-dns.com \
    -brief </dev/null 2>&1 | grep -q 'CONNECTION ESTABLISHED'
```

With `2>/dev/null` the probe returns false forever and the resolver gets
latched onto plaintext. This bit us during the first apply (see §11).

`/etc/NetworkManager/NetworkManager.conf` already has `dns=none`, therefore
NM never rewrites `/etc/resolv.conf` (`nameserver 127.0.0.1`). The DHCP
nameservers (`200.21.200.10`, `200.21.200.80`) are deliberately unused.

### 6.4 nftables

```bash
sudo nft -f /etc/nftables.conf     # reload
systemctl status nftables          # persistent
sudo nft list ruleset
```

Inbound: default drop; established/related, loopback, DHCPv4/v6,
ICMP + ICMPv6 (NDP) accepted. On `LAN_IFS` only:

- `udp 5353, 21027, 53317` — mDNS / Syncthing / LocalSend discovery
  (covers unicast, broadcast and multicast);
- `tcp 53317, 22000` and `udp 22000` — transfers, **only** from RFC1918
  sources (`10/8`, `172.16/12`, `192.168/16`) so a router port-forward
  cannot expose them.

Everything else is dropped; unexpected unicast gets a rate-limited ICMP
reject. Forwarding is dropped (no router duty). Output is unrestricted
(fail-open, see 3).

`bitcoind` keeps running exactly as before: outbound Tor on `127.0.0.1:9050`
is loopback, and Tor's own outbound is normal output traffic. Only the
clearnet listener on `8333` is closed.

### 6.5 Coexistence with WARP's own firewall

WARP ships its own nftables table, `inet cloudflare-warp` (verified with
`sudo nft list ruleset`). It installs rules such as
`iif "CloudflareWARP" accept`, `oif "CloudflareWARP" goto tun` and a TCP MSS
clamp, and it loads/unloads them as the tunnel connects and disconnects.
It does **not** touch `inet filter`, so the two tables are independent:

- `inet cloudflare-warp` — WARP's tunnel plumbing;
- `inet filter` — this host's default-deny inbound policy.

Because WARP unloads its rules when disconnected and ours stay in place,
the firewall keeps protecting the host in both states (and traffic still
fails open by design).

---

## 7. Verification

```bash
# WARP state and policy routing
warp-cli status                      # Status update: Connected
ip rule | grep 65743                 # 32765: not from all fwmark 0x100cf lookup 65743
ip route show table 65743 | head

# exit address (should be Cloudflare, warp=on)
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)='

# DNS: local resolver, DoT known-good, plaintext fallback known-good
dig +short @127.0.0.1 example.com
openssl s_client -connect 1.1.1.1:853 -servername cloudflare-dns.com -brief </dev/null
dig +short @1.1.1.1 example.com

# fallback state machine
ls /etc/unbound/conf.d/              # exactly one of *.conf active
journalctl -t unbound-fallback -n 20 # switches to/from plaintext are logged

# timers
systemctl list-timers warp-connect.timer unbound-dns-fallback.timer

# firewall
sudo nft list chain inet filter input
sudo nft list tables                         # inet filter + inet cloudflare-warp
sudo nft list ruleset | grep -iE 'warp|cloudflare'   # WARP's own table only

# note: `systemctl status nftables` reports "inactive (dead)" after a
# successful run - the packaged unit is a plain oneshot without
# RemainAfterExit. The rules are loaded; verify with `nft list ruleset`.

# services that must still work
ss -lntu | grep -E ':(53317|22000|21027|8333)\b'
bitcoin-cli getnetworkinfo | grep -E 'connections|localaddresses'  # Tor-only, still peers
```

### Simulating a DoT outage

```bash
sudo nft add rule inet filter output tcp dport 853 reject
sudo systemctl start unbound-dns-fallback.service
ls /etc/unbound/conf.d/              # 20-forward-plain.conf now active
dig +short @127.0.0.1 example.com    # still resolves, via :53
sudo nft delete rule inet filter output handle <handle>   # or: sudo nft flush ruleset && sudo nft -f /etc/nftables.conf
sudo systemctl start unbound-dns-fallback.service
ls /etc/unbound/conf.d/              # back to 10-forward-dot.conf
```

---

## 8. Troubleshooting

| Symptom | Check |
|---|---|
| "What is my IP" shows the ISP address | `warp-cli status`; if `Disconnected`, `sudo systemctl start warp-connect.service` and inspect `journalctl -u warp-svc -b`. Confirm `ip rule` contains `lookup 65743`. |
| Internet works but is slow to come up after boot | `systemctl status NetworkManager-wait-online`; the WARP drop-in waits for it. |
| DNS timeouts / SERVFAIL | `ls /etc/unbound/conf.d/` — exactly one `.conf` must be active. `unbound-checkconf` then `journalctl -u unbound -n 50`. |
| DNS suddenly plaintext | `journalctl -t unbound-fallback` — the fallback engaged because `853/tcp` was unreachable; it reverts automatically. If it stays plaintext while `openssl s_client -connect 1.1.1.1:853 -brief </dev/null` succeeds, the probe is broken (see §6.3 — stderr must be merged, not discarded). |
| `systemctl status nftables` says `inactive (dead)` | Expected: the packaged unit is a oneshot without `RemainAfterExit`. Rules are loaded at boot/restart; check `sudo nft list ruleset`. |
| LocalSend cannot find devices | Discovery is `udp/53317` + mDNS `5353` on `wlan0`; check `LAN_IFS` matches `ip -br link`, and that both devices are on the same L2 (client isolation off). |
| Syncthing only relays, no LAN | `22000` tcp/udp and `21027` udp must be allowed from the peer; verify with `sudo nft list chain inet filter input`. |
| `bitcoind` stopped syncing | It is `onlynet=onion`; check Tor (`9050`) and `journalctl --user -u bitcoind`. The firewall does not touch loopback. |
| `WARN … Skipped uploading aggregate stats because registration was none!` | Benign cosmetic warning from the stats actor; the registration itself is valid (`warp-cli registration show`). |
| NM says `connected (site only)` / `limited` | NM's own connectivity probe is affected by the tunnel; actual connectivity is fine. Not used for anything critical here. |

---

## 9. Planned vs implemented

Small deviations from the original plan, all deliberate:

1. **Always-on:** planned to set a `warp-cli always-on` flag; this CLI version
   does not expose one. Implemented as `warp-connect.timer` (60s) plus the
   boot-time oneshot, which is equivalent in practice and survives roaming.
2. **Unbound duplicate zone:** assumed two active `forward-zone` stanzas would
   be a fatal config error. In reality Unbound logs
   `duplicate forward zone . ignored.` and still starts. The installer and
   watchdog therefore enforce "exactly one active file" instead of relying on
   checkconf to catch it.
3. **Firewall interface scope:** rules use `define LAN_IFS = { "wlan0", "enp2s0" }`
   instead of hard-coding `wlan0`, so plugging in Ethernet doesn't silently
   break LocalSend/Syncthing.
4. **SSH:** intentionally left commented out (no `sshd` running).
5. **bitcoind:** kept `8333` closed permanently rather than "LAN-only", because
   the node is Tor-only; the rationale is recorded so it isn't "fixed" later
   by mistake.
6. **Probe bug found during the first apply:** `openssl s_client -brief` writes
   to stderr, so the original `2>/dev/null` made the health check always fail
   and Unbound latched onto plaintext. Fixed in
   `usr/local/sbin/unbound-dns-fallback` (`2>&1` before the pipe) and
   re-installed; the resolver returns to DoT on the next 30s tick.

---

## 10. Switching VPNs (WARP ↔ Proton)

`system/switch-vpn.sh`, installed as `/usr/local/sbin/switch-vpn`, moves the
host between Cloudflare WARP, Proton VPN and no VPN. DNS, the nftables
firewall and the LAN rules are independent of the choice and are never
rewritten by it.

```bash
switch-vpn status                  # read-only, no root needed
sudo switch-vpn warp               # Cloudflare WARP (this document's default)
sudo switch-vpn proton             # Proton VPN, fastest server
sudo switch-vpn proton --country US    # args pass through to `protonvpn connect`
sudo switch-vpn none               # direct via the ISP
```

### 10.1 Why they cannot both be up

WARP installs

```
32765:  not from all fwmark 0x100cf lookup 65743
```

Policy rules are consulted before the `main` table. Proton's WireGuard
connection only installs a default route **in `main`**, so with both active the
Proton handshake packets would be looked up in table `65743` and pushed into
the WARP tunnel — nested tunnels, or no handshake at all.

`warp-cli disconnect` alone is not enough either: `warp-connect.timer`
re-asserts the connection within 60 s and takes the routing back. The switcher
therefore **disables** the units, not just stops them.

### 10.2 What each mode does

| Mode | Actions |
|---|---|
| `warp` | disable `proton-vpn-kill-switch-boot.service`; `protonvpn disconnect`; stop+disable `proton.VPN.service`; wait for `proton0` to disappear; enable+start `warp-svc`, `warp-connect.timer`, run `warp-connect.service`; wait for `Connected` and the `65743` rule |
| `proton` | disable `warp-connect.timer`; stop `warp-connect.service`; `warp-cli disconnect`; stop+disable `warp-svc`; **wait until the `65743` rule is gone** (otherwise Proton loses to it); enable+start `proton.VPN.service`; add `224.0.0.0/4 dev <lan>` if missing; `protonvpn connect` as `SUDO_USER` |
| `none` | both of the above teardown halves, in order; verifies that no VPN route or policy rule remains |
| `status` | units, interfaces, `ip rule`, default route, `warp-cli status`, `protonvpn status`, active NM connections, egress IP + org |

Because the units are enabled/disabled, the choice **persists across
reboots**: `switch-vpn proton` survives a restart, and `switch-vpn warp`
turns Proton's autostart back off. `none` disables both.

If WARP's `65743` rule is still present 15 s after disabling the units, the
switcher **aborts** instead of starting Proton on top of it (a half-switched
host with working internet is better than a tunnel that cannot carry
traffic). Re-run after fixing `warp-svc`.

### 10.3 Proton CLI vs importing a WireGuard profile with `nmcli`

You already have `proton-vpn-cli`, so use it. It drives NetworkManager itself:
connections are named `ProtonVPN <server>` with interface `proton0`, and
server/city selection, protocol choice and kill switch are handled for you.
Nothing else in this setup needs to change.

Importing a downloaded `.conf` with `nmcli connection import type wireguard`
is the minimal alternative and works fine (just `nmcli con up/down`), but you
lose server selection, kill switch and credential rotation, and you have to
re-download profiles by hand. Only prefer it if you want zero Proton packages
on the machine.

### 10.4 First-time Proton setup

```bash
protonvpn signin          # as your normal user, once; stores the token in the keyring
switch-vpn status         # confirm `protonvpn status` answers
sudo switch-vpn proton
```

`switch-vpn proton` re-executes `protonvpn connect` as `SUDO_USER` with
`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` pointing at that user's session,
because the CLI talks D-Bus and reads the credentials from the **user**
keyring. Run from a desktop session (a plain root shell cannot see that
keyring); otherwise it prints the manual command instead of failing silently.

### 10.5 Interaction with the rest of the setup

- **DNS** — unchanged. Unbound keeps forwarding DoT to `1.1.1.1:853`
  *through whichever tunnel is up*. `dns=none` in NetworkManager stops the
  Proton NM profile from replacing `/etc/resolv.conf`. If a future CLI version
  starts managing DNS itself, check that `/etc/resolv.conf` still says
  `nameserver 127.0.0.1`.
- **Firewall** — unchanged. Output is `accept`, so WireGuard/OpenVPN handshakes
  work; input stays default-deny, which also applies to `proton0`. Buying
  Proton's port-forwarding add-on would need one explicit accept on that
  interface.
- **Kill switch** — Proton implements it with NetworkManager dummy
  connections (route metrics), **not** nftables, so `inet filter` is never
  modified. Its "permanent" variant is stored as the enablement of
  `proton-vpn-kill-switch-boot.service`; switching away disables that unit, so
  a stale fail-closed state cannot block the next mode. Re-enable it
  deliberately with `sudo systemctl enable proton-vpn-kill-switch-boot.service`
  if you want Proton to fail closed.
- **LAN discovery** — Proton's config uses `AllowedIPs = 0.0.0.0/0`. The
  connected `192.168.1.0/24` route is more specific than `/0`, so transfers
  keep working, but multicast has no such route and would follow the tunnel.
  `switch-vpn proton` therefore adds `224.0.0.0/4 dev <lan-iface>` (runtime
  only) so LocalSend/Syncthing discovery keeps working.
- **`bitcoind`/Tor** — unaffected: loopback and Tor's own outbound traffic go
  through the active tunnel like any other output.

### 10.6 Troubleshooting the switch

| Symptom | Check |
|---|---|
| `protonvpn connect` says authentication required | Run `protonvpn signin` as your user, then retry. |
| `switch-vpn proton` prints "timed out: `proton0` up" | `journalctl -u proton.VPN.service -n 50`; `nmcli -t -f NAME,TYPE,STATE connection show`; some Proton CLI versions need `proton-vpn-daemon` (pulled in automatically) and a working keyring. |
| New IP still looks like WARP after switching | `ip rule show \| grep 65743` — if present, `warp-svc` is still running; `sudo systemctl disable --now warp-svc` and re-run the switch. |
| No internet after `switch-vpn none` | A leftover Proton dummy kill-switch connection: `nmcli -t -f NAME,TYPE connection show \| grep -i dummy`, then `protonvpn disconnect` (or re-run `switch-vpn none`). |
| LAN discovery broken only under Proton | `ip route show 224.0.0.0/4` should name the LAN interface; re-add with `sudo ip route add 224.0.0.0/4 dev wlan0`. |
| `switch-vpn status` shows `proton daemon: inactive (disabled)` | Expected after `switch-vpn warp`/`none`; `switch-vpn proton` re-enables it. |

---

## 11. Changelog

- 2026-11-18 — initial implementation:
  WARP boot ordering + reconnect timer; Unbound drop-in architecture with
  DoT primary and plaintext Cloudflare fallback; nftables default-deny
  inbound with LAN-only LocalSend/Syncthing; documentation and rollback.
- 2026-11-18 — first apply verified: WARP `Connected`, `warp=on`, exit
  `loc=CO`, policy rule present, DNS resolving. The DoT health probe was
  found to always fail because `openssl s_client -brief` reports on stderr;
  fixed (`2>&1`), fallback confirmed to flip back to DoT.
- 2026-11-18 — final verification: `DoT reachable again` logged at 22:35:57,
  `/etc/unbound/conf.d/` back to `10-forward-dot.conf` +
  `20-forward-plain.conf.disabled`, installed watchdog matches the repo
  (md5), both timers active. `nftables` input chain is `policy drop`; WARP
  owns a separate `inet cloudflare-warp` table that leaves `inet filter`
  untouched. LocalSend/Syncthing/bitcoind unaffected.
- 2026-11-18 — added `system/switch-vpn.sh` (installed as
  `/usr/local/sbin/switch-vpn`) to move between WARP, Proton VPN and no VPN.
  Verified `status`, `--help`, argument validation, the non-root guard, and
  the full `warp -> proton -> none -> warp` transition against stubbed
  `systemctl`/`ip`/`warp-cli`/`protonvpn`, including the abort path for a
  stuck WARP rule. The real tunnel was not switched in this session. The
  switcher exists because WARP's `lookup 65743` policy rule outranks Proton's
  main-table default route and because `warp-connect.timer` would otherwise
  re-take the routing within 60 s.
