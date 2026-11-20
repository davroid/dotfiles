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
| DNS | Unbound on `127.0.0.1:53`, DNSSEC validating, DoT to Cloudflare, automatic plaintext fallback (stands down in Tor mode) | one resolver, encrypted by default, survives a blocked 853/tcp |
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
├── switch-vpn.sh                               # warp | proton | tor | none | status
├── vpn-tray.sh                                 # Waybar indicator + fuzzel menu
├── etc/
│   ├── nftables.conf                           # host firewall
│   ├── torrc.d/
│   │   └── 10-transparent.conf                 # TransPort/DNSPort for tor mode
│   ├── systemd/system/
│   │   ├── warp-connect.service                # oneshot: ensure WARP connected
│   │   ├── warp-connect.timer                  # every 60s
│   │   ├── tor-transparent.service             # oneshot: load/remove `inet tor`
│   │   ├── unbound-dns-fallback.service        # oneshot: check 853/tcp
│   │   ├── unbound-dns-fallback.timer          # every 30s
│   │   └── warp-svc.service.d/
│   │       └── 10-network-order.conf           # order WARP after the network
│   └── unbound/conf.d/
│       ├── 10-forward-dot.conf                 # active: Cloudflare DoT
│       └── 20-forward-plain.conf.disabled      # inactive: Cloudflare plain
└── usr/local/
    ├── bin/warp-ensure-connected               # idempotent connect helper
    └── sbin/
        ├── unbound-dns-fallback                # DoT/plaintext state machine
        └── tor-transparent                     # fail-closed Tor nftables rules
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
| `system/etc/torrc.d/10-transparent.conf` | `/etc/torrc.d/10-transparent.conf` |
| `system/usr/local/sbin/tor-transparent` | same path (0755) |
| `system/etc/systemd/system/tor-transparent.service` | same path |
| `system/switch-vpn.sh` | `/usr/local/sbin/switch-vpn` (0755) |
| `system/vpn-tray.sh` | `/usr/local/bin/vpn-tray` (0755) |

The bar itself is configured outside `system/`, through the existing dotfiles:
`.config/waybar/config.jsonc` (`custom/vpn` module) and
`.config/waybar/style.css` (colours per state). Both are user files, not
installed by `install.sh`.

`install.sh` also edits `/etc/unbound/unbound.conf` in place:

1. comments out the old inline `forward-zone:` block (prefixed with
   `# (disabled by dotfiles/system)`),
2. appends `include-toplevel: "/etc/unbound/conf.d/*.conf"`.

It does the same kind of guarded append to `/etc/tor/torrc`:
`%include /etc/torrc.d/*.conf` (Tor's own drop-in mechanism).

Both operations are guarded and idempotent, and every modified file is
backed up as `<file>.bak.YYYYmmdd-HHMMSS`.

---

## 5. Replay on a fresh machine

### 5.1 Packages

```bash
sudo pacman -S --needed networkmanager unbound nftables openssl bind
# WARP is AUR:
yay -S cloudflare-warp-bin     # provides warp-svc + warp-cli
# Needed by bitcoind (onlynet=onion) and by `switch-vpn tor`:
sudo pacman -S --needed tor
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
5. installs the Tor drop-in, appends `%include /etc/torrc.d/*.conf` to
   `/etc/tor/torrc` if needed, validates both `torrc` and the `inet tor`
   ruleset, installs `tor-transparent` and its unit, then restarts `tor`
   (warns and skips if the `tor` package is missing);
6. installs `switch-vpn` to `/usr/local/sbin/` and `vpn-tray` to
   `/usr/local/bin/` (warns if `protonvpn` is missing);
7. prints verification output (WARP status, `ip rule`, exit IP, DNS answer,
   input chain, remaining listeners).

### 5.4 Rollback

```bash
cd ~/dotfiles/system
sudo ./rollback.sh
```

It disables the timers and `nftables.service`, removes the installed files
(including `/usr/local/sbin/switch-vpn`, `/usr/local/bin/vpn-tray`,
`tor-transparent` and the Tor drop-in), restores the newest `unbound.conf` /
`nftables.conf` / `torrc` backup (or removes only the include line it added),
flushes the ruleset and restarts `tor` and `warp-svc`. It never touches
Proton VPN units or connections.

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
| DNS timeouts only in Tor mode | `journalctl -t unbound-fallback` must show no switching while `tor-transparent` is active. Unbound must not have IPv6 `forward-addr` entries (external IPv6 is dropped in this mode, so those queries blackhole). `grep forward-addr /etc/unbound/conf.d/10-forward-dot.conf`. |
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
7. **Tor is a transparent proxy, not a tunnel interface.** The mode redirects
   traffic with a separate `inet tor` nftables table instead of pretending
   Tor is a `tun` device. `tor.service` stays enabled in every mode because
   `bitcoind` is `onlynet=onion`; only `tor-transparent.service` is toggled.
   Traffic Tor cannot carry (non-DNS UDP, external IPv6) is **dropped**, not
   leaked, so the mode fails closed (§10.8).

---

## 10. Switching VPNs and proxies (WARP ↔ Proton ↔ Tor)

`system/switch-vpn.sh`, installed as `/usr/local/sbin/switch-vpn`, moves the
host between Cloudflare WARP, Proton VPN, Tor and no VPN. DNS and the
nftables host firewall (`inet filter`) are independent of the choice and are
never rewritten by it. Tor adds and removes its own separate table,
`inet tor`.

```bash
switch-vpn status                  # read-only, no root needed
sudo switch-vpn warp               # Cloudflare WARP (this document's default)
sudo switch-vpn proton             # Proton VPN, fastest server
sudo switch-vpn proton --country US    # args pass through to `protonvpn connect`
sudo switch-vpn tor                # Tor, transparent and fail-closed
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

Tor cannot run alongside either VPN: its output redirect would capture their
handshakes too, and its fail-closed filter drops WireGuard's UDP. The switcher
therefore removes `inet tor` before bringing WARP or Proton up, and tears the
VPNs down before installing it.

### 10.2 What each mode does

| Mode | Actions |
|---|---|
| `warp` | disable `proton-vpn-kill-switch-boot.service`; `protonvpn disconnect`; stop+disable `proton.VPN.service`; **set `connection.autoconnect no` on every stored WireGuard profile**; `nmcli connection down` any active one; wait for it to disappear; disable `tor-transparent.service` (deletes `inet tor`); enable+start `warp-svc`, `warp-connect.timer`, run `warp-connect.service`; wait for `Connected` and the `65743` rule |
| `proton` | disable `warp-connect.timer`; stop `warp-connect.service`; `warp-cli disconnect`; stop+disable `warp-svc`; **wait until the `65743` rule is gone** (otherwise Proton loses to it); disable `tor-transparent.service`; **set autoconnect `no` on all stored WireGuard profiles and `yes` on the chosen one**; bring up the imported NetworkManager WireGuard profile (or fall back to the CLI); add `224.0.0.0/4 dev <lan>` if missing; verify with `ip route get 1.1.1.1` |
| `tor` | the WARP and Proton teardowns above, including autoconnect `no`; enable+start `tor.service` (it stays enabled in every mode for `bitcoind`); enable `tor-transparent.service`, which loads the fail-closed `inet tor` table (external TCP → `127.0.0.1:9040`, UDP/53 → `:5353`, other UDP and external IPv6 dropped); verify that a plain `curl` (no proxy) reports `IsTor:true` and that Unbound still resolves |
| `none` | the WARP, Proton and Tor teardowns, in order, including autoconnect `no`; verifies that no VPN route, policy rule or `inet tor` table remains |
| `status` | units, interfaces, `ip rule`, default route, stored/active WireGuard profile, **stored autoconnect flags**, `warp-cli status`, `protonvpn status`, active NM connections, egress IP + org |

Because the units are enabled/disabled, the choice **persists across
reboots**: `switch-vpn proton` survives a restart, `switch-vpn tor` leaves
`tor-transparent.service` enabled, and `switch-vpn warp` turns both off.
`none` disables everything.

That is only half of the persistence. NetworkManager activates imported
WireGuard profiles itself, before systemd services run, so each mode also
writes `connection.autoconnect` on every stored WireGuard profile. Without
this, a reboot selected WARP in systemd but NetworkManager auto-activated
`proton-US` first (its flag was `yes`); WARP then could not establish:

- WARP's handshake (fwmark `0x100cf`) hits Proton's `not fwmark 0xcab7 →
  table 51895` rule first, because that rule has a lower priority number, so
  the handshake is pushed into the Proton tunnel and never reaches Cloudflare.
- `warp-connect.timer` retried every 60 s without success.
- WARP's own firewall (`inet cloudflare-warp`) stayed in "catch-all Deny"
  because the tunnel was not connected, so the host had **no internet** and
  DNS failed until the profile was manually taken down.

The fix is stored in the profiles, visible with
`switch-vpn status` → `WG autoconnect : proton-US=no`.

If WARP's `65743` rule is still present 15 s after disabling the units, the
switcher **aborts** instead of starting Proton on top of it (a half-switched
host with working internet is better than a tunnel that cannot carry
traffic). Re-run after fixing `warp-svc`.

### 10.3 Proton transport: use a NetworkManager WireGuard profile, not the CLI

`proton-vpn-cli 1.1.0.0` is broken on this machine's NetworkManager (1.58).
Every connect attempt fails with:

```
Error: Connection failed. Try connecting to a different server or check your network settings.
```

and the verbose log shows `VPN server NOT reachable` after exactly 5 s, while
the server itself is up. The cause is in the CLI's kill-switch routing, not in
this setup:

1. To avoid leaks while connecting, the CLI always creates a dummy interface
   (`pvpnksintrf0`) with `default via 100.85.0.1 metric 98`, which beats
   Wi-Fi's default route (`metric 600`).
2. It then tries to punch a hole by adding `84.20.27.34/32 via 192.168.1.1`
   to the **active JARZ profile** and re-applying it.
3. NetworkManager 1.58 accepts the profile change (`audit: op="connection-update"
   … args="ipv4.routes" result="success"`) but never installs the route in the
   kernel — `nmcli device show wlan0` lists only the LAN routes, and
   `ip route` has no `/32`.
4. The CLI's "is the server reachable" TCP probe therefore goes into the
   dummy interface and times out, so it aborts before WireGuard is even
   configured.

Observed route timeline during a failed attempt:

```
23:17:57  default via 100.85.0.1 dev pvpnksintrf0 proto static metric 98
          (no 84.20.27.34/32 route ever appears)
23:18:02  pvpnksintrf0 removed after the probe timed out
```

**What works:** a WireGuard profile imported into NetworkManager. No dummy
interface, no reachability probe, no per-connect NM profile mutation.

```bash
# one-time, as your normal user
# account.protonvpn.com -> Downloads -> WireGuard configuration
#   platform: GNU/Linux, pick a country/server, download the .conf
nmcli connection import type wireguard file ~/Downloads/proton-US.conf
nmcli -t -f NAME,TYPE connection show | grep wireguard   # note the name

sudo switch-vpn proton
```

`switch-vpn` detects the profile (preferring names containing `proton`, else
the first WireGuard profile) and activates it with `nmcli connection up`.
Override the choice with `PROTON_CON=<name>` if you keep several profiles.

Notes:

- The imported config contains `DNS = 10.2.0.1`. With `dns=none`, NM does not
  touch `/etc/resolv.conf`; Unbound keeps resolving. You can also clear it:
  `nmcli connection modify <name> ipv4.dns "" ipv6.dns ""`.
- `AllowedIPs = 0.0.0.0/0` makes the tunnel the default route; the connected
  LAN subnet stays reachable because it is more specific. The switcher adds
  `224.0.0.0/4 dev wlan0` for multicast discovery.
- Proton's config installs policy routing (`fwmark` + its own table), so
  `ip route show default` still names Wi-Fi while the tunnel carries traffic.
  Verify with `ip route get 1.1.1.1` instead; `switch-vpn` and `vpn-tray` both
  do, and this is why a pure main-table check reports a false negative.
- WireGuard configs are per-server: pick a nearby country for latency. Proton
  rotates server IPs occasionally; regenerate the config from the dashboard
  if a server disappears.
- No kill switch in this path (fail-open, like WARP). If you want fail-closed,
  import several profiles and enable Proton's permanent kill switch
  explicitly: `sudo systemctl enable proton-vpn-kill-switch-boot.service`.

The CLI remains as a fallback (`proton` mode uses it only when no WireGuard
profile exists) and will start working again if a future release fixes the
route installation. Keep it out of the critical path for now.

### 10.4 First-time Proton setup

```bash
# 1. download a WireGuard config from account.protonvpn.com (Downloads)
# 2. import it once, as your normal user:
nmcli connection import type wireguard file ~/Downloads/proton-US.conf

# 3. check detection and switch:
switch-vpn status                  # "proton NM profile : proton-US"
sudo switch-vpn proton
sudo switch-vpn warp               # back to WARP
```

Using the CLI instead (currently affected by the bug above):

```bash
protonvpn signin                   # stores the token in your user keyring
sudo switch-vpn proton             # falls back to the CLI if no .conf imported
```

`switch-vpn proton` re-executes `protonvpn connect` as the invoking user
(`SUDO_USER` or `PKEXEC_UID`) with
`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` pointing at that user's session,
because the CLI talks D-Bus and reads the credentials from the **user**
keyring. Run from a desktop session (a plain root shell cannot see that
keyring); otherwise it prints the manual command instead of failing silently.
The imported-profile path needs none of that: no sign-in, no daemon, no
keyring.

### 10.5 Interaction with the rest of the setup

- **DNS** — unchanged. Unbound keeps forwarding DoT to `1.1.1.1:853`
  *through whichever tunnel is up* (in `tor` mode that TCP connection is
  redirected to TransPort like any other, so it leaves via a Tor exit).
  `dns=none` in NetworkManager stops the Proton NM profile from replacing
  `/etc/resolv.conf` (the imported config's `DNS = 10.2.0.1` is therefore
  inert). If a future CLI version starts managing DNS itself, check that
  `/etc/resolv.conf` still says `nameserver 127.0.0.1`.
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
  only) so LocalSend/Syncthing discovery keeps working. In `tor` mode the
  nftables rules leave RFC1918, link-local and multicast direct, so the same
  discovery and transfers never enter an exit node.
- **`bitcoind`/Tor** — `tor.service` stays enabled in **every** mode, because
  the node is `onlynet=onion` and proxies through `127.0.0.1:9050`. In `tor`
  mode loopback is exempt from the redirect, and sockets owned by uid `tor`
  are exempt from both the redirect and the drops, so onion peers keep
  working. In WARP/Proton mode `9050` is loopback output like any other and
  follows the tunnel.

### 10.6 Troubleshooting the switch

| Symptom | Check |
|---|---|
| `protonvpn connect` prints `VPN server NOT reachable` / `Connection failed` | Known CLI 1.1.0 + NM 1.58 kill-switch bug (§10.3). Use an imported WireGuard profile; a pre-added `/32` for the server or a newer CLI release are the only CLI-side workarounds. |
| `protonvpn connect` says authentication required | Run `protonvpn signin` as your user, then retry. |
| `switch-vpn proton` prints "timed out: tunnel up" | `switch-vpn status`; if `active WG device : none`, run `nmcli connection up <profile>` by hand to see NM's error. Check `journalctl -u NetworkManager -n 50`. |
| `switch-vpn proton` used the CLI instead of my profile | `switch-vpn status` → `proton NM profile`. Name the connection with `proton` in it, or set `PROTON_CON=<name>`. |
| New IP still looks like WARP after switching | `ip rule show \| grep 65743` — if present, `warp-svc` is still running; `sudo systemctl disable --now warp-svc` and re-run the switch. |
| Reboots into the *other* VPN | `switch-vpn status` → `WG autoconnect`. In WARP mode every profile must say `no`; in Proton mode the chosen one must say `yes` and the WARP units must be disabled. Re-run `switch-vpn warp` (or `proton`) — it writes both the units and the autoconnect flags. |
| Boots offline with WARP stuck at `Connecting` | Check `nmcli -t -f NAME,TYPE,DEVICE connection show --active` and `journalctl -b -u warp-svc \| grep -Ei 'Connecting\|NoConnections\|deny'`. Both tunnels are up: take the WireGuard profile down with `sudo switch-vpn warp`; the profile's `autoconnect` is the lasting fix. |
| Boot helper never connects WARP | `systemctl list-timers warp-connect.timer` shows `LAST`; `warp-connect.service` is triggered by the timer even though it is `disabled` (oneshot, no `[Install]` start at boot). If `LAST` is far in the past, `sudo systemctl restart warp-connect.timer`. |
| No internet after `switch-vpn none` | A leftover Proton dummy kill-switch connection: `nmcli -t -f NAME,TYPE connection show \| grep -i dummy`, then `protonvpn disconnect` (or re-run `switch-vpn none`). |
| LAN discovery broken only under Proton | `ip route show 224.0.0.0/4` should name the LAN interface; re-add with `sudo ip route add 224.0.0.0/4 dev wlan0`. |
| `switch-vpn tor` leaves the real IP visible | `sudo nft list table inet tor` must exist and `systemctl is-active tor-transparent` must be `active`; re-run `sudo switch-vpn tor`. Confirm with `curl -s --noproxy '*' https://check.torproject.org/api/ip`. |
| Websites fail / time out in `tor` mode | Tor may still be bootstrapping (`journalctl -u tor \| tail`), or the site blocks exits. This is fail-closed by design; switch to WARP/Proton or `none`. |
| QUIC, games or other UDP apps stop working in `tor` mode | Expected: non-DNS UDP is dropped so it cannot leak. Browsers fall back to TCP; UDP-only apps cannot run in this mode. |
| `.onion` addresses do not open in a browser in `tor` mode | Transparent routing does not make Unbound resolve `.onion`. Point the browser at SOCKS `127.0.0.1:9050` (`socks5h`) or use Tor Browser. |
| `switch-vpn tor` pauses after `Starting Tor` | Tor is rebuilding circuits on the new path (WARP/Proton carried the old ones). The switcher restarts `tor` and bounds the wait to ~15 s for a circuit plus 25 s for the end-to-end probe; the redirect is already armed, so nothing leaks meanwhile. Check `journalctl -u tor -n 20`. |
| `switch-vpn tor` says the helper is not installed | Run `sudo /home/daviddeadly/dotfiles/system/install.sh`; it installs `tor-transparent` and its unit. |
| `tor-transparent: user 'tor' does not exist` | The `tor` package is missing (`sudo pacman -S tor`). |
| `switch-vpn status` shows `proton daemon: inactive (disabled)` | Expected after `switch-vpn warp`/`none`, and also when using an imported profile (the CLI daemon is not needed). |

### 10.7 Bar indicator and one-click switching — `vpn-tray`

`vpn-tray` (installed to `/usr/local/bin`) renders the current VPN in Waybar
and opens a fuzzel menu when clicked. It reads state as your normal user and
delegates the actual switch to `switch-vpn` as root.

| State | Bar | Colour | Waybar class | Tooltip |
|---|---|---|---|---|
| Cloudflare WARP | ` WARP` | Cloudflare orange | `warp` | interface + "routed through the tunnel" |
| Proton VPN | ` PROTON` | purple | `proton` | profile/interface + routing state |
| Tor | ` TOR` | green | `tor` | "TCP + DNS via Tor, other UDP/IPv6 blocked" |
| No VPN | ` DIRECT` | amber | `direct` | notes if WARP is enabled-but-down or a Proton profile is merely imported |
| Tunnel/proxy up, not routed | same label, red | red | `<state> warn` | "NOT routed through the tunnel" and the reason |

Glyphs are Font Awesome from CaskaydiaCove Nerd Font (`fa-cloud`,
`fa-shield`, `fa-user-secret` for Tor, `fa-globe`).

How it decides:

1. `tor-transparent.service` is **enabled** → Tor. Green only when both
   `tor-transparent.service` and `tor.service` are active; otherwise the pill
   turns red.
2. `CloudflareWARP` exists **and** `ip rule` has `lookup 65743` → WARP.
3. otherwise an active NetworkManager `wireguard` connection → Proton
   (`proton0` from the CLI or an imported profile).
4. otherwise direct.
5. Routing is confirmed with `ip route get 1.1.1.1`, not
   `ip route show default`: imported Proton configs use a `fwmark` and their
   own table, so the main table keeps Wi-Fi as the default route while the
   tunnel carries traffic. A mismatch turns the label red. Tor has no
   interface to query; its two units are the signal.

Waybar integration (already in this repo's
`.config/waybar/config.jsonc` / `style.css`):

```jsonc
"custom/vpn": {
  "exec": "vpn-tray status",
  "return-type": "json",
  "interval": 5,
  "signal": 8,                 // instant refresh: pkill -RTMIN+8 waybar
  "on-click": "vpn-tray menu",
  "tooltip": true
}
```

Click behaviour:

- fuzzel menu with the active mode marked: WARP / Proton VPN / Tor
  (transparent) / No VPN / Show status in a terminal.
- Elevation order: already-cached sudo (`sudo -n`), else `pkexec` (the
  hyprpolkitagent dialog), else a `foot` terminal running `sudo switch-vpn`.
- After the switch it re-detects, sends a `notify-send` summary, and pokes
  Waybar with `RTMIN+8` so the label changes immediately.

Manual checks and reload:

```bash
vpn-tray text        # one-line state, useful when the bar looks wrong
vpn-tray status      # raw JSON Waybar consumes
vpn-tray menu        # same menu outside the bar
pkill -SIGUSR2 -x waybar   # reload config + CSS after editing them
```

Optional: skip the password dialog with a sudoers drop-in (this allows only
`switch-vpn` invocations, but all of them, including mode changes):

```bash
sudo visudo -f /etc/sudoers.d/vpn-switch
# daviddeadly ALL=(root) NOPASSWD: /usr/local/sbin/switch-vpn
sudo visudo -c        # validate
```

Without it, `pkexec` asks once per switch. `vpn-tray` itself needs no
privileges; only the menu's switch does. The menu needs a graphical session
(fuzzel + polkit agent). If `hyprpolkitagent` is not running, `pkexec` fails —
start the agent, or remove the sudoers line and use `sudo switch-vpn` in a
terminal.

| Symptom | Check |
|---|---|
| No VPN pill in the bar | `vpn-tray status` must print JSON; `pkill -SIGUSR2 -x waybar`; confirm `custom/vpn` is in `modules-right` and `vpn-tray` is in `PATH`. |
| Pill stays on the old mode | Gives a wrong state? Run `vpn-tray text`. If that is correct, Waybar's module was not reloaded (SIGUSR2). |
| Pill is red | `ip route get 1.1.1.1` must name the tunnel device; if not, the tunnel is up but not routing (see §10.6). |
| Click does nothing | Run `vpn-tray menu` in a terminal. Missing `fuzzel`, or no polkit agent and no `foot` fallback. |
| Password dialog every time | Expected with pkexec; install the sudoers drop-in above if you accept it. |

### 10.8 Tor mode — transparent, fail-closed

`sudo switch-vpn tor` moves the **whole host** behind Tor without asking each
application to configure a proxy. It is deliberately different from WARP and
Proton: Tor is a SOCKS proxy, not a tunnel interface, so the mode is
implemented with an nftables redirect and two Tor listeners.

Why not SOCKS-only: an opt-in proxy only anonymises the apps that remember to
use it, while everything else keeps leaking the real address. Since the
switcher presents Tor as a *mode*, the bar must be able to say "this host is
routed through Tor" and mean it.

#### Listeners

`system/etc/torrc.d/10-transparent.conf`, loaded through
`%include /etc/torrc.d/*.conf` (Tor's own mechanism; `install.sh` appends it
to `/etc/tor/torrc` if it is missing):

```conf
TransPort 127.0.0.1:9040
DNSPort 127.0.0.1:5353
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
```

They are installed **unconditionally** and are harmless in the other modes.
That matters for `bitcoind`: `tor.service` stays enabled everywhere, so
switching to WARP or Proton never interrupts onion peers. Only
`tor-transparent.service` is toggled — an ordinary oneshot unit that loads or
deletes the `inet tor` table.

#### What the rules do

`inet tor` has two `output` chains (the host is not a router, so forwarded
traffic from containers/VMs is intentionally untouched):

| Chain | Rule | Effect |
|---|---|---|
| NAT (`dstnat`, -100) | uid `tor` | Tor's own outbound sockets bypass the redirect (otherwise they would loop into TransPort) |
| NAT | `10.192.0.0/10` TCP | redirected to TransPort — this is how Tor represents `.onion` names, and it sits inside RFC1918, so it must be checked **before** the LAN exemption |
| NAT | loopback, RFC1918, link-local, multicast, broadcast | `return`: LAN stays direct |
| NAT | UDP/53 | redirected to DNSPort `5353` |
| NAT | all other TCP | redirected to TransPort `9040` |
| filter (0) | `lo`, IPv6 link-local/ULA/multicast, IPv4 LAN, UDP/123 | allowed |
| filter | external ICMP except `dest-unreachable`, `time-exceeded`, `parameter-problem` | dropped |
| filter | all other UDP | **dropped** — QUIC/games cannot leak |
| filter | external IPv6 | **dropped** |

Consequences:

- **Web/SSH/IMAP/…** use Tor automatically. `curl https://…` (no proxy
  variables) reports an exit address and `IsTor:true`.
- **DNS:** apps that use the system resolver talk to Unbound on
  `127.0.0.1:53`; loopback is exempt, and Unbound's DoT connection to
  `1.1.1.1:853` is redirected to TransPort like any other TCP. An app that
  hard-codes `8.8.8.8:53` is caught by the UDP/53 redirect and answered by
  Tor's DNSPort, so it cannot leak either.
  Only the **IPv4** DoT forwarders are configured: external IPv6 is dropped
  here, so an IPv6 upstream would blackhole every query that picked it for
  the resolver's full timeout (8 s+ measured). The 30 s DoT/plaintext
  watchdog also stands down while `tor-transparent` is active — plaintext
  would be answered by DNSPort, which strips DNSSEC records, and a 4 s TLS
  probe flaps against Tor's circuit build time. The switcher reloads Unbound
  when entering or leaving the mode so upstream sockets are rebuilt on the
  new path.
- **QUIC** (UDP/443) is dropped; browsers fall back to TCP. UDP-only games
  and tools simply do not work in this mode — by design.
- **IPv6** outside the LAN is dropped rather than leaked. Happy-eyeballs
  apps fall back to IPv4.
- **LAN** (LocalSend, Syncthing, SSH from the LAN, DHCP, mDNS) is direct and
  unchanged.
- **NTP** (UDP/123) is allowed so the clock — and therefore Tor — stays sane.

There is no fail-open path: if `tor.service` dies, the redirect remains and
connections are refused. That is why the pill turns red instead of silently
showing the ISP address.

#### Verify

```bash
switch-vpn status                       # tor.service + tor transparent units
sudo nft list table inet tor            # the live rules
curl -s --noproxy '*' https://check.torproject.org/api/ip   # IsTor:true
dig +short @127.0.0.1 example.com       # Unbound still resolving
ss -lntu | grep -E '127\.0\.0\.1:(9040|9050|5353)'
```

`switch-vpn tor` performs the same checks itself, including a plain `curl`
with `--noproxy '*'` so it measures the redirect rather than a proxy variable.

Tor's circuits are carried by whatever tunnel is active. When the previous
mode was WARP or Proton, the switcher **restarts `tor.service`** after tearing
the tunnel down; left alone, Tor keeps dead circuits for ~60 s (`Network was
down for 63 seconds`) and the switch looks stuck. Bitcoind's onion peers
reconnect on their own (verified after the restart). Switching from `none`,
or re-running `tor`, leaves a healthy daemon alone. The first run after
installing the drop-in also restarts once to open 9040/5353.

Circuit readiness is reported, not required: the nftables rules are armed
first, so if Tor is still bootstrapping the host fails closed while the
command waits a bounded window and then explains the state. The end-to-end
checks (plain `curl`, Unbound resolution) retry within that window, because
Unbound's DoT connection is rebuilt through the new circuit and the first
query after a switch can time out.

#### Caveats

- Transparent `.onion` browsing needs SOCKS (`127.0.0.1:9050`, `socks5h`) or
  Tor Browser: Unbound cannot resolve `.onion`. The `10.192.0.0/10` redirect
  exists for apps that do use SOCKS with hostname resolution.
- Onion services often present a certificate for their **clearnet** name
  (Libera: `palladium.libera.chat`), and no public CA issues for `.onion`.
  Clients that verify the hostname must disable that check for the onion
  address; the onion name itself authenticates the service. SOCKS5 must send
  the hostname to Tor (`socks5h`), not resolve it locally.
- Tor exit policies and destination port blocking apply as usual; some sites
  refuse exits.
- Throughput and latency are Tor's, not the ISP's.
- `tor-transparent up/down/check/status` can be run by hand for debugging;
  `check` validates the ruleset with `nft -c` without applying it.
- Removing the mode is just `sudo switch-vpn warp` (or `proton`/`none`),
  which disables `tor-transparent.service` and deletes the table.

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
- 2026-11-18 — Proton CLI diagnosed and worked around. `protonvpn connect`
  failed with `VPN server NOT reachable` after 5 s; the kill-switch dummy
  device (`pvpnksintrf0`, `default metric 98`) hijacked the route, while the
  `/32` exception NM was told to add to the `JARZ` profile was accepted by NM
  1.58 but never installed in the kernel (confirmed via `ip route` and
  `nmcli device show`). Added a NetworkManager-profile path to
  `switch-vpn proton` (import a WireGuard config, `nmcli connection up`);
  the CLI is now only a fallback. Docs §10.3 records the evidence.
- 2026-11-18 — added a Waybar indicator + fuzzel menu, `system/vpn-tray.sh`
  (installed as `/usr/local/bin/vpn-tray`): orange `WARP`, purple `PROTON`,
  amber `DIRECT`, red when a tunnel is up but traffic is not routed through
  it. One click switches mode through pkexec (hyprpolkitagent) or cached
  sudo, then refreshes the bar with `RTMIN+8`. Fixed `switch-vpn`'s tunnel
  check at the same time: imported Proton profiles are policy-routed, so
  verification now uses `ip route get 1.1.1.1` instead of the main table
  (which still points at Wi-Fi), and the CLI fallback also understands
  `PKEXEC_UID`. Verified all four states and the
  `warp -> proton -> none -> warp` menu flow against stubs, plus the live
  indicator on a real Proton tunnel.
- 2026-11-19 — fixed the mode not surviving a reboot. `proton-US` had
  `connection.autoconnect=yes`, so NetworkManager activated it ~5 s before
  WARP on every boot (`policy: auto-activating connection 'proton-US'`).
  WARP's fwmark handshake was then routed into Proton's table and could not
  connect; `warp-connect.timer` retried every 60 s but WARP's own firewall
  stayed in catch-all Deny, which is why the boot had no internet or DNS.
  Confirmed on boots `16:05` and `16:27` (`proton-US` activated at 16:05:07 /
  16:27:40, WARP only connected after the profile was manually taken down).
  `switch-vpn` now writes `connection.autoconnect=no` to every stored
  WireGuard profile in `warp`/`none` mode and `yes` to the chosen profile in
  `proton` mode; `status` reports the stored flags. Verified by restarting
  NetworkManager in both modes: WARP-only egress + DNS in WARP mode,
  Proton-only in Proton mode, then restored WARP.
- 2026-11-19 — added `tor` as a fourth mode. `switch-vpn tor` tears down WARP
  and Proton, keeps `tor.service` running (it is needed by `bitcoind` in every
  mode), and enables `tor-transparent.service`, which loads a separate
  `inet tor` nftables table:
  - external TCP → TransPort `127.0.0.1:9040`, external UDP/53 → DNSPort
    `127.0.0.1:5353`;
  - loopback, RFC1918, link-local, multicast and broadcast stay direct, and
    uid `tor` is exempt so its own outbound does not loop back into TransPort;
  - `10.192.0.0/10` (`VirtualAddrNetworkIPv4`) is redirected before the LAN
    exemption so SOCKS-resolved `.onion` names still work;
  - non-DNS UDP (QUIC, games), external IPv6 and ICMP echo are **dropped**, so
    the mode fails closed instead of leaking via the ISP. NTP (UDP/123) is the
    only external non-Tor UDP path.
  `torrc` gains `/etc/torrc.d/10-transparent.conf` via `%include`, which is
  installed unconditionally so mode changes never restart Tor. The first
  installer run silently skipped the include because `grep -F` matched the
  commented `#%include` example line; the guard is now anchored to an
  uncommented directive.
  The Waybar pill shows ` TOR` in green (`tor` class), and the fuzzel menu
  gained the entry. Verified live: `warp -> proton -> tor -> warp` transitions
  remove/add `inet tor` correctly; in Tor mode a plain `curl` (no proxy) exits
  through a Tor node (`IsTor:true`), Unbound resolves, LAN pings and
  LocalSend/Syncthing listeners stay direct, external IPv6 and UDP/443 are
  blocked, and `bitcoind` keeps 4 onion peers through `127.0.0.1:9050`.
  Restarting NetworkManager in Tor mode brought neither Proton nor WARP back
  (`autoconnect=no`, `tor-transparent` still enabled), then WARP was restored.
- 2026-11-19 — fixed `switch-vpn tor` appearing to hang for ~2 minutes after
  `Starting Tor`. Two compounding bugs: `wait_until` counted **attempts**
  rather than seconds, and each `tor_ready` probe could spend 10 s in curl, so
  `wait_until 45` could block for minutes; and Tor's circuits are carried by
  the active tunnel, so tearing WARP down left them dead until Tor noticed
  (`Network was down for 64 seconds`, `Our IP address has changed`).
  `wait_until` now uses a wall-clock deadline and `tor_ready` uses 2 s connect
  / 5 s total timeouts. `use_tor` restarts `tor.service` when the routing is
  actually carried by WARP (`lookup 65743` rule) or Proton (active WireGuard
  device) — not merely when `warp-svc` is running — so Tor bootstraps on the
  new path immediately without costing bitcoind its onion peers on a
  disconnected WARP. The nftables rules are armed *before* the readiness
  wait, which is capped at 15 s and only reports the state (fail-closed all
  the while); the end-to-end `curl` and DNS checks retry for 25 s / 15 s.
  Also fixed `trace()` returning non-zero when `ipinfo.io` omitted `org`:
  a successful switch then exited 1 and `vpn-tray` reported "switch
  cancelled" even though the mode had changed.
  Verified: `warp -> tor` in 19 s and `proton -> tor` in 22 s including the
  Tor restart, `tor -> tor` in 14 s, all exit 0 with `IsTor:true`, Unbound
  answers, and bitcoind back to 4 onion peers after each restart. A first
  attempt that armed the redirect but hit Unbound's cold DoT circuit showed
  the retries doing their job; the DNS readout now comes from the probe that
  succeeded instead of a second query that could race.
- 2026-11-19 — fixed intermittent DNS stalls in `tor` mode. Two causes:
  `10-forward-dot.conf` listed two IPv6 forwarders, but external IPv6 is
  dropped in this mode, so every query that picked one blackholed for the
  full resolver timeout (8 s+ measured) before retrying IPv4; and the 30 s
  DoT watchdog flapped to plaintext because its 4 s TLS probe is shorter
  than a fresh Tor circuit, reloading Unbound each time. Plaintext is not a
  valid fallback here either: DNSPort strips DNSSEC records (no
  DNSKEY/RRSIG), so validation would break. The IPv6 forwarders are gone
  (IPv4 reaches Cloudflare in every mode), the watchdog now keeps DoT and
  does not probe while `tor-transparent` is active, and the switcher reloads
  Unbound when entering or leaving the mode so upstream sockets are rebuilt
  on the new path. Verified: 15 uncached queries 330–630 ms with no
  timeouts, `getent hosts` works, `journalctl -t unbound-fallback` silent.

