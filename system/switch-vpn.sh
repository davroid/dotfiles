#!/usr/bin/env bash
# switch-vpn.sh - choose the active VPN on davarch.
#
#   sudo ./switch-vpn.sh warp            # Cloudflare WARP, the default setup
#   sudo ./switch-vpn.sh proton          # Proton VPN
#   sudo ./switch-vpn.sh proton --country US   # extra args go to `protonvpn connect`
#   sudo ./switch-vpn.sh tor             # Tor, transparent and fail-closed
#   sudo ./switch-vpn.sh none            # no VPN (direct via the ISP, fail-open)
#        ./switch-vpn.sh status          # read-only report, no root needed
#
# Proton uses an imported NetworkManager WireGuard profile if one exists
# (recommended: proton-vpn-cli 1.1.0 has a kill-switch/NM routing bug, see
# docs/networking.md 10.3). Import a config once with:
#   nmcli connection import type wireguard file ~/Downloads/proton-XX.conf
# Override the profile name with PROTON_CON=... if detection picks the wrong one.
#
# Installed as /usr/local/sbin/switch-vpn by install.sh.
#
# Design notes
# ------------
# * WARP and Proton VPN never run at the same time: WARP installs a policy rule
#   at prio 32765 (`lookup 65743`) which is evaluated before the main table, so
#   Proton's WireGuard default route would lose and its handshake packets would
#   be pushed into the WARP tunnel.
# * Mode is stored twice, because two different components act at boot:
#   systemd unit enablement (WARP daemon/timer, Proton CLI daemon) and
#   NetworkManager's connection.autoconnect for stored WireGuard profiles.
#   Imported profiles are activated by NM itself, before systemd services, so
#   leaving autoconnect=yes brings Proton up behind WARP and deadlocks both.
# * "Disconnected" is not enough for WARP: warp-connect.timer re-asserts the
#   connection every 60s. The units have to be disabled, not just stopped.
# * Proton's CLI speaks D-Bus and keeps credentials in the *user* keyring, so
#   `protonvpn connect` is re-executed as the invoking user (sudo or pkexec)
#   with that user's session bus, and only after the system units are in the
#   right state.
# * Proton's kill switch is implemented as NetworkManager dummy connections
#   (route metrics), not nftables, so `inet filter` is never touched. Its
#   "permanent" mode is stored as enablement of
#   proton-vpn-kill-switch-boot.service; switching away disables it.
# * DNS (Unbound -> Cloudflare DoT) and the nftables host firewall do not care
#   which tunnel is up and are left alone.
# * Tor is different from the two VPNs: it is a proxy, not an interface. The
#   tor mode redirects external TCP to TransPort 9040 and UDP/53 to DNSPort
#   5353 with a separate `inet tor` nftables table, and drops what Tor cannot
#   carry (other UDP, external IPv6), so the mode fails closed. tor.service
#   itself stays enabled in every mode because bitcoind is onlynet=onion;
#   only tor-transparent.service is toggled by the switcher.
set -uo pipefail

PROTON_BIN="$(command -v protonvpn 2>/dev/null || true)"
[ -n "$PROTON_BIN" ] || PROTON_BIN=/sbin/protonvpn
PROTON_CON="${PROTON_CON:-}"
WARP_TABLE=65743
WARP_IF=CloudflareWARP
PROTON_IF=proton0

step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m %s\n' "$*"; }
info() { printf '   \033[36m--\033[0m %s\n' "$*"; }
warn() { printf '   \033[33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# User who invoked us through sudo or pkexec. Their keyring holds the Proton
# credentials, and their session bus is what the CLI talks to.
invoker_user() {
    local name
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        printf '%s' "$SUDO_USER"
        return 0
    fi
    if [ -n "${PKEXEC_UID:-}" ] && [ "$PKEXEC_UID" != 0 ]; then
        name="$(getent passwd "$PKEXEC_UID" | cut -d: -f1)"
        [ -n "$name" ] || return 1
        printf '%s' "$name"
        return 0
    fi
    return 1
}

# Run a command as the invoking user, with a working session bus so the Proton
# CLI can reach the keyring. Falls back to plain execution when not elevated.
as_invoker() {
    local user uid home
    if user="$(invoker_user)" && [ -n "$user" ]; then
        uid="$(id -u "$user")"
        home="$(getent passwd "$user" | cut -d: -f6)"
        sudo -u "$user" env \
            HOME="$home" \
            XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            "$@"
    else
        "$@"
    fi
}

warp_connected() {
    timeout 5 warp-cli --accept-tos status 2>/dev/null |
        grep -q '^Status update: Connected'
}

# Any active WireGuard link managed by NetworkManager: covers both the Proton
# CLI (interface proton0) and an imported .conf profile (device name differs).
wg_active_conn() {
    nmcli -t -f NAME,TYPE connection show --active 2>/dev/null |
        awk -F: '$2=="wireguard"{print $1; exit}'
}

wg_active_dev() {
    nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null |
        awk -F: '$2=="wireguard"{print $3; exit}'
}

no_wg_active() { [ -z "$(wg_active_dev)" ]; }

# Stored WireGuard profile to use instead of the CLI. Prefers a profile whose
# name contains "proton"; PROTON_CON overrides detection.
proton_nm_profile() {
    if [ -n "$PROTON_CON" ]; then printf '%s' "$PROTON_CON"; return 0; fi
    local name
    name="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null |
        awk -F: 'tolower($1) ~ /proton/ && $2=="wireguard" {print $1; exit}')"
    if [ -z "$name" ]; then
        name="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null |
            awk -F: '$2=="wireguard" {print $1; exit}')"
    fi
    printf '%s' "$name"
}

proton_connected() {
    local dev
    dev="$(wg_active_dev)"
    [ -n "$dev" ] || return 1
    # Ask the kernel: profiles imported from Proton route with a fwmark and
    # their own table, so `main` can still show Wi-Fi as the default route
    # while the tunnel carries the traffic.
    ip route get 1.1.1.1 2>/dev/null | grep -q " dev $dev"
}

deactivate_wg() {
    local con
    con="$(wg_active_conn)"
    [ -n "$con" ] || return 0
    if nmcli connection down "$con" >/dev/null 2>&1; then
        info "deactivated WireGuard profile '$con'"
    else
        warn "could not deactivate WireGuard profile '$con'"
    fi
}

# All stored NetworkManager WireGuard connections (imported profiles, and
# anything else that is not the CLI's transient proton0).
wg_connections() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null |
        awk -F: '$2=="wireguard" {print $1}'
}

# Persist the boot choice where NetworkManager will see it. Enabling or
# disabling systemd units is not enough: an imported WireGuard profile is
# activated by NM at boot on its own, before WARP gets a chance to connect,
# and then both tunnels fight over the routing (WARP's handshake is swallowed
# by the profile's table and its firewall leaves the host offline).
set_wg_autoconnect() { # set_wg_autoconnect yes|no [profile...]
    local value=$1 name
    shift
    local names=()
    if [ $# -gt 0 ]; then
        names=("$@")
    else
        while IFS= read -r name; do
            [ -n "$name" ] && names+=("$name")
        done < <(wg_connections)
    fi
    if [ ${#names[@]} -eq 0 ]; then
        info "no stored WireGuard profiles to update"
        return 0
    fi
    for name in "${names[@]}"; do
        [ -n "$name" ] || continue
        if nmcli connection modify "$name" \
            connection.autoconnect "$value" >/dev/null 2>&1; then
            info "boot autoconnect=$value for '$name'"
        else
            warn "could not set autoconnect=$value for '$name'"
        fi
    done
}

wg_autoconnect_list() {
    local name value out=
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        value="$(nmcli -g connection.autoconnect connection show "$name" \
            2>/dev/null)"
        out+="${out:+, }$name=${value:-unknown}"
    done < <(wg_connections)
    printf '%s' "${out:-none}"
}

warp_rule_present() { ip rule show 2>/dev/null | grep -q "lookup $WARP_TABLE"; }

# systemctl is-active/is-enabled print their answer and exit non-zero for
# inactive/disabled units; capture the text without duplicating it.
unit_field() { local v; v="$(systemctl "$1" "$2" 2>/dev/null)"; printf '%s' "${v:-unknown}"; }
unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }

or_none() { local v; v="$("$@")"; printf '%s' "${v:-none}"; }

wait_until() { # wait_until <seconds> <description> <command...>
    local timeout=$1 desc=$2; shift 2
    local i=0
    while [ "$i" -lt "$timeout" ]; do
        if "$@" >/dev/null 2>&1; then
            ok "$desc"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    warn "timed out after ${timeout}s: $desc"
    return 1
}

lan_iface() {
    # First global IPv4 address in RFC1918 space, e.g. wlan0.
    ip -o -4 addr show scope global 2>/dev/null |
        awk '$4 ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/ {print $2; exit}'
}

ensure_lan_multicast_route() {
    # Proton's WireGuard config uses AllowedIPs 0.0.0.0/0. The connected LAN
    # subnet stays reachable (more specific route), but multicast has no such
    # route and would follow the VPN, breaking LocalSend/Syncthing discovery.
    local dev
    dev="$(lan_iface)"
    [ -n "$dev" ] || { warn "no RFC1918 interface found; skipping multicast route"; return 0; }
    if ip route show 224.0.0.0/4 2>/dev/null | grep -q "dev $dev"; then
        info "multicast route 224.0.0.0/4 dev $dev already present"
        return 0
    fi
    if ip route add 224.0.0.0/4 dev "$dev" 2>/dev/null; then
        ok "added 224.0.0.0/4 dev $dev (LAN discovery while tunneled)"
    else
        warn "could not add 224.0.0.0/4 dev $dev"
    fi
}

# ---------------------------------------------------------------------------
# shared teardown helpers (used by every mode)
# ---------------------------------------------------------------------------

# Tear down WARP. `strict` aborts when the policy rule lingers: Proton or Tor
# would be stacked on top of routing that steals their handshakes.
disable_warp_stack() { # [strict]
    systemctl disable --now warp-connect.timer >/dev/null 2>&1 || true
    systemctl stop warp-connect.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet warp-svc.service; then
        warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    fi
    systemctl disable --now warp-svc.service >/dev/null 2>&1 || true
    ok "warp-connect timer and warp-svc disabled"
    # The policy rule outranks any main-table default route.
    if [ "${1:-}" = strict ]; then
        if ! wait_until 15 "WARP policy rule removed" \
            sh -c "! ip rule show | grep -q 'lookup $WARP_TABLE'"; then
            die "WARP rule table $WARP_TABLE is still present; refusing to stack Proton or Tor on top of it. Check: ip rule show && systemctl status warp-svc"
        fi
        if ip link show "$WARP_IF" >/dev/null 2>&1; then
            warn "$WARP_IF interface still exists; WARP may still be tearing down"
        fi
    else
        wait_until 15 "WARP policy rule removed" \
            sh -c "! ip rule show | grep -q 'lookup $WARP_TABLE'" || true
    fi
}

# Tear down Proton's daemon, kill switch and imported WireGuard profile, and
# persist autoconnect=no so NetworkManager cannot resurrect it at boot.
disable_proton_stack() {
    if ! unit_exists proton.VPN.service; then
        info "proton-vpn-cli is not installed"
    else
        systemctl disable --now proton-vpn-kill-switch-boot.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet proton.VPN.service; then
            as_invoker "$PROTON_BIN" disconnect >/dev/null 2>&1 || true
        fi
        # Disable even when inactive: an enabled daemon would come back on
        # reboot and could re-create its kill-switch connections behind us.
        systemctl disable --now proton.VPN.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet proton.VPN.service; then
            warn "proton daemon is still active"
        else
            ok "proton daemon stopped and disabled"
        fi
    fi
    set_wg_autoconnect no
    deactivate_wg
    wait_until 10 "WireGuard tunnel down" no_wg_active || true
}

# Turn off transparent Tor routing without touching tor.service: bitcoind's
# onlynet=onion needs 127.0.0.1:9050 in every mode.
disable_tor_routing() {
    local had=0
    if unit_exists tor-transparent.service; then
        if systemctl is-active --quiet tor-transparent.service 2>/dev/null; then
            had=1
        fi
        systemctl disable --now tor-transparent.service >/dev/null 2>&1 || true
    fi
    # ExecStop removes the table; do it again for a half-failed unit and for
    # the case where the unit files were removed by hand.
    if command -v nft >/dev/null 2>&1 && nft list table inet tor >/dev/null 2>&1; then
        nft delete table inet tor >/dev/null 2>&1 || true
        had=1
    fi
    if [ "$had" -eq 1 ]; then
        ok "transparent Tor routing off (tor.service left running for bitcoind)"
    else
        info "transparent Tor routing was already off"
    fi
}

# ---------------------------------------------------------------------------
# mode: warp
# ---------------------------------------------------------------------------
use_warp() {
    step "Disabling Tor routing"
    disable_tor_routing

    step "Disabling Proton VPN"
    disable_proton_stack

    step "Enabling Cloudflare WARP"
    systemctl enable --now warp-svc.service >/dev/null 2>&1 || die "could not start warp-svc"
    systemctl enable --now warp-connect.timer >/dev/null 2>&1 || true
    systemctl start warp-connect.service >/dev/null 2>&1 || true
    wait_until 25 "WARP connected" warp_connected || true

    step "Verifying"
    if warp_connected; then ok "warp-cli: Connected"; else warn "warp-cli is not connected yet (timer retries every 60s)"; fi
    if warp_rule_present; then ok "policy rule for table $WARP_TABLE present"; else warn "policy rule for table $WARP_TABLE missing"; fi
    trace
}

# ---------------------------------------------------------------------------
# mode: proton [connect args...]
# ---------------------------------------------------------------------------
use_proton() {
    local profile
    profile="$(proton_nm_profile)"

    # Refuse before tearing WARP down if there is no way to bring Proton up.
    if [ -z "$profile" ] && [ ! -x "$PROTON_BIN" ]; then
        die "no Proton WireGuard profile and no protonvpn binary. Import one:
       nmcli connection import type wireguard file ~/Downloads/proton-XX.conf"
    fi

    step "Disabling Tor routing"
    disable_tor_routing

    step "Disabling Cloudflare WARP"
    disable_warp_stack strict

    step "Starting Proton VPN"
    if [ -n "$profile" ]; then
        # NetworkManager path: no Proton daemon, no kill-switch dummy routes,
        # no CLI reachability probe. This is the reliable path on NM 1.5x.
        if unit_exists proton.VPN.service; then
            systemctl disable --now proton.VPN.service >/dev/null 2>&1 || true
        fi
        info "using NetworkManager profile '$profile'"
        # Make this the only profile allowed to come up at boot, so a reboot
        # lands in Proton mode instead of fighting WARP for the default route.
        set_wg_autoconnect no
        set_wg_autoconnect yes "$profile"
        if nmcli connection up "$profile" >/dev/null 2>&1; then
            ok "nmcli brought up '$profile'"
        else
            warn "nmcli connection up '$profile' failed; run it without --quiet for details"
        fi
        ensure_lan_multicast_route
    else
        info "no imported WireGuard profile: falling back to the Proton CLI"
        warn "proton-vpn-cli 1.1.0 can fail on NM 1.5x (kill-switch route bug);"
        warn "if it fails, import a WireGuard config from account.protonvpn.com (docs 10.3)"
        # CLI connections are transient; no stored profile should race them.
        set_wg_autoconnect no
        if systemctl enable --now proton.VPN.service >/dev/null 2>&1; then
            ok "proton.VPN.service enabled and started"
        else
            warn "proton.VPN.service did not start; check journalctl -u proton.VPN.service"
        fi
        ensure_lan_multicast_route

        local invoker
        invoker="$(invoker_user)"
        if [ -z "$invoker" ]; then
            warn "not invoked via sudo/pkexec from a desktop session; run 'protonvpn connect' yourself"
        elif [ ! -x "$PROTON_BIN" ]; then
            warn "$PROTON_BIN not found; install proton-vpn-cli"
        else
            info "connecting as $invoker (credentials come from that user's keyring)"
            if as_invoker "$PROTON_BIN" connect "$@"; then
                ok "protonvpn connect returned"
            else
                warn "protonvpn connect failed; if this is the first run, do 'protonvpn signin' as $invoker"
            fi
        fi
    fi

    step "Verifying"
    if wait_until 25 "tunnel up" proton_connected; then
        local dev
        dev="$(wg_active_dev)"
        ip -brief addr show "$dev" 2>/dev/null | sed 's/^/   /'
        ip route get 1.1.1.1 2>/dev/null | head -1 | sed 's/^/   /'
        [ "$dev" = "$PROTON_IF" ] || info "interface: $dev (imported profile)"
    else
        warn "traffic is not routed through an active WireGuard interface; the tunnel is not established"
    fi
    trace
}

# ---------------------------------------------------------------------------
# mode: none
# ---------------------------------------------------------------------------
use_none() {
    step "Disabling Tor routing"
    disable_tor_routing

    step "Disabling Cloudflare WARP"
    disable_warp_stack

    step "Disabling Proton VPN"
    disable_proton_stack

    step "Verifying (fail-open, direct via the ISP)"
    ip route show default | sed 's/^/   /'
    trace
}

# ---------------------------------------------------------------------------
# mode: tor
# ---------------------------------------------------------------------------
tor_ports_up() {
    ss -lntu 2>/dev/null | grep -q '127\.0\.0\.1:9040' &&
        ss -lntu 2>/dev/null | grep -q '127\.0\.0\.1:5353'
}

# A circuit exists when the SOCKS port can reach the check service. This is
# also the honest test for "is Tor usable at all", not just "is the unit up".
tor_ready() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -s --socks5-hostname 127.0.0.1:9050 -m 10 \
        https://check.torproject.org/api/ip 2>/dev/null | grep -q '"IsTor":true'
}

tor_transparent_active() {
    systemctl is-active --quiet tor-transparent.service 2>/dev/null &&
        nft list table inet tor >/dev/null 2>&1
}

use_tor() {
    if ! unit_exists tor.service; then
        die "tor.service not found: install the tor package first (sudo pacman -S tor)"
    fi
    if ! [ -x /usr/local/sbin/tor-transparent ] ||
        ! unit_exists tor-transparent.service; then
        die "the transparent Tor helper is not installed; run the dotfiles installer:
       sudo /home/daviddeadly/dotfiles/system/install.sh"
    fi

    step "Disabling Cloudflare WARP"
    disable_warp_stack

    step "Disabling Proton VPN"
    disable_proton_stack

    step "Starting Tor"
    # tor.service stays enabled in every mode: bitcoind is onlynet=onion and
    # proxies through 127.0.0.1:9050. Only the routing layer is mode-specific.
    if systemctl enable --now tor.service >/dev/null 2>&1; then
        ok "tor.service enabled and running"
    else
        warn "tor.service did not start; check journalctl -u tor"
    fi
    # The TransPort/DNSPort drop-in needs a restart the first time. Do not
    # restart a healthy daemon: bitcoind's onion connections would drop.
    if ! tor_ports_up; then
        info "TransPort/DNSPort not listening; restarting tor to load the drop-in"
        systemctl restart tor.service >/dev/null 2>&1 || true
        wait_until 15 "Tor listeners up" tor_ports_up || true
    fi
    wait_until 45 "Tor circuit available" tor_ready || true

    step "Enabling transparent Tor routing (fail-closed)"
    if systemctl enable --now tor-transparent.service >/dev/null 2>&1; then
        ok "tor-transparent.service enabled and active"
    else
        die "could not enable tor-transparent.service"
    fi

    step "Verifying (TCP + DNS via Tor, LAN direct, other UDP/IPv6 blocked)"
    if tor_transparent_active; then
        ok "nft table 'inet tor' present"
    else
        warn "nft table 'inet tor' missing; traffic may not be redirected"
    fi
    if tor_ready; then
        ok "SOCKS 9050: exit node reachable"
    else
        warn "Tor is still bootstrapping; traffic fails closed until a circuit exists"
    fi
    if command -v curl >/dev/null 2>&1; then
        local out
        out="$(curl -s --noproxy '*' -m 20 https://check.torproject.org/api/ip 2>/dev/null)"
        if printf '%s' "$out" | grep -q '"IsTor":true'; then
            ok "plain curl (no proxy settings) exits through Tor"
        else
            warn "plain curl did not report IsTor; check: sudo nft list table inet tor"
        fi
    fi
    echo "   Tor listeners:"
    ss -lntu 2>/dev/null | grep -E '127\.0\.0\.1:(9040|9050|5353)\b' | sed 's/^/   /' ||
        echo "   none"
    if command -v dig >/dev/null 2>&1; then
        local dns
        dns="$(dig +short +time=5 +tries=1 @127.0.0.1 example.com 2>/dev/null | head -2)"
        if [ -n "$dns" ]; then
            ok "DNS via Unbound -> Tor: $(printf '%s' "$dns" | tr '\n' ' ')"
        else
            warn "DNS via Unbound failed; check journalctl -u unbound -n 30"
        fi
    fi
    trace
}

# ---------------------------------------------------------------------------
# shared output
# ---------------------------------------------------------------------------
trace() {
    if command -v curl >/dev/null; then
        local out
        out="$(curl -s --noproxy '*' -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
            grep -E '^(ip|loc|warp)=' | tr '\n' ' ')"
        [ -n "$out" ] && info "egress: $out"
        local org
        org="$(curl -s --noproxy '*' -m 10 https://ipinfo.io/json 2>/dev/null |
            tr -d '\n' | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [ -n "$org" ] && info "seen as: $org"
    fi
}

# ---------------------------------------------------------------------------
# mode: status
# ---------------------------------------------------------------------------
show_status() {
    echo "active VPN plumbing"
    printf '   warp-svc          : %s (%s)\n' \
        "$(unit_field is-active warp-svc.service)" \
        "$(unit_field is-enabled warp-svc.service)"
    printf '   warp-connect.timer: %s (%s)\n' \
        "$(unit_field is-active warp-connect.timer)" \
        "$(unit_field is-enabled warp-connect.timer)"
    printf '   proton daemon     : %s (%s)\n' \
        "$(unit_field is-active proton.VPN.service)" \
        "$(unit_field is-enabled proton.VPN.service)"
    printf '   proton perm. KS   : %s\n' \
        "$(unit_field is-enabled proton-vpn-kill-switch-boot.service)"
    printf '   proton NM profile : %s\n' "$(or_none proton_nm_profile)"
    printf '   WG autoconnect    : %s\n' "$(wg_autoconnect_list)"
    printf '   active WG device  : %s\n' "$(or_none wg_active_dev)"
    printf '   tor.service       : %s (%s)\n' \
        "$(unit_field is-active tor.service)" \
        "$(unit_field is-enabled tor.service)"
    printf '   tor transparent   : %s (%s)\n' \
        "$(unit_field is-active tor-transparent.service)" \
        "$(unit_field is-enabled tor-transparent.service)"

    echo "interfaces and routes"
    ip -brief addr show 2>/dev/null | grep -E "^($WARP_IF|$PROTON_IF|wlan[0-9]|enp[0-9]|proton)" | sed 's/^/   /'
    ip rule show 2>/dev/null | grep "lookup $WARP_TABLE" | sed 's/^/   /' || echo "   no WARP policy rule"
    ip route show default | sed 's/^/   /'
    ip route get 1.1.1.1 2>/dev/null | head -1 | sed 's/^/   egress: /'

    if systemctl is-active --quiet warp-svc.service; then
        echo "cloudflare warp"
        timeout 5 warp-cli --accept-tos status 2>/dev/null | head -2 | sed 's/^/   /'
    fi

    echo "proton vpn"
    if systemctl is-active --quiet proton.VPN.service; then
        timeout 10 "$PROTON_BIN" status 2>/dev/null | grep -v -i eventlet |
            grep -v 'monkey_patched' | tail -2 | sed 's/^/   /'
    else
        local dev
        dev="$(wg_active_dev)"
        if [ -n "$dev" ]; then
            echo "   active via NetworkManager: $dev"
        else
            echo "   not connected (daemon disabled)"
        fi
    fi

    echo "networkmanager"
    nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | sed 's/^/   /'

    echo "tor"
    ss -lntu 2>/dev/null | grep -E '127\.0\.0\.1:(9040|9050|5353)\b' | sed 's/^/   /' ||
        echo "   no listeners on 9040/9050/5353"
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        if nft list table inet tor >/dev/null 2>&1; then
            echo "   transparent redirect: active (nft table inet tor)"
        else
            echo "   transparent redirect: off"
        fi
    fi

    trace
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
mode="${1:-status}"
[ $# -gt 0 ] && shift

case "$mode" in
    warp|proton|tor|none|status) ;;
    -h|--help|help)
        sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) die "unknown mode '$mode' (use: warp | proton | tor | none | status)" ;;
esac

if [ "$mode" != status ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "run with sudo: sudo $0 $mode"
fi

case "$mode" in
    warp)   use_warp ;;
    proton) use_proton "$@" ;;
    tor)    use_tor ;;
    none)   use_none ;;
    status) show_status ;;
esac
