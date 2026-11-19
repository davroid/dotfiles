#!/usr/bin/env bash
# switch-vpn.sh - choose the active VPN on davarch.
#
#   sudo ./switch-vpn.sh warp            # Cloudflare WARP, the default setup
#   sudo ./switch-vpn.sh proton          # Proton VPN, fastest server
#   sudo ./switch-vpn.sh proton --country US   # extra args go to `protonvpn connect`
#   sudo ./switch-vpn.sh none            # no VPN (direct via the ISP, fail-open)
#        ./switch-vpn.sh status          # read-only report, no root needed
#
# Installed as /usr/local/sbin/switch-vpn by install.sh.
#
# Design notes
# ------------
# * WARP and Proton VPN never run at the same time: WARP installs a policy rule
#   at prio 32765 (`lookup 65743`) which is evaluated before the main table, so
#   Proton's WireGuard default route would lose and its handshake packets would
#   be pushed into the WARP tunnel.
# * "Disconnected" is not enough for WARP: warp-connect.timer re-asserts the
#   connection every 60s. The units have to be disabled, not just stopped.
# * Proton's CLI speaks D-Bus and keeps credentials in the *user* keyring, so
#   `protonvpn connect` is re-executed as SUDO_USER with that user's session
#   bus, and only after the system units are in the right state.
# * Proton's kill switch is implemented as NetworkManager dummy connections
#   (route metrics), not nftables, so `inet filter` is never touched. Its
#   "permanent" mode is stored as enablement of
#   proton-vpn-kill-switch-boot.service; switching away disables it.
# * DNS (Unbound -> Cloudflare DoT) and the nftables host firewall do not care
#   which tunnel is up and are left alone.
set -uo pipefail

PROTON_BIN="$(command -v protonvpn 2>/dev/null || true)"
[ -n "$PROTON_BIN" ] || PROTON_BIN=/sbin/protonvpn
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

# Run a command as the user who invoked sudo, with a working session bus so the
# Proton CLI can reach the keyring. Falls back to plain execution if not sudo.
as_invoker() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        local uid home
        uid="$(id -u "$SUDO_USER")"
        home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        sudo -u "$SUDO_USER" env \
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

proton_connected() {
    ip link show "$PROTON_IF" >/dev/null 2>&1 &&
        ip -o route show dev "$PROTON_IF" 2>/dev/null | grep -q .
}

warp_rule_present() { ip rule show 2>/dev/null | grep -q "lookup $WARP_TABLE"; }

# systemctl is-active/is-enabled print their answer and exit non-zero for
# inactive/disabled units; capture the text without duplicating it.
unit_field() { local v; v="$(systemctl "$1" "$2" 2>/dev/null)"; printf '%s' "${v:-unknown}"; }
unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }

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
# mode: warp
# ---------------------------------------------------------------------------
use_warp() {
    step "Disabling Proton VPN"
    if ! unit_exists proton.VPN.service; then
        info "proton-vpn-cli is not installed"
    else
        systemctl disable --now proton-vpn-kill-switch-boot.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet proton.VPN.service; then
            as_invoker "$PROTON_BIN" disconnect >/dev/null 2>&1 || true
        fi
        # Disable even when inactive: an enabled daemon would come back on
        # reboot and could re-create its kill-switch connections.
        systemctl disable --now proton.VPN.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet proton.VPN.service; then
            warn "proton daemon is still active"
        else
            ok "proton daemon stopped and disabled"
        fi
    fi
    if ip link show "$PROTON_IF" >/dev/null 2>&1; then
        wait_until 10 "$PROTON_IF removed" \
            sh -c "! ip link show $PROTON_IF >/dev/null 2>&1" || true
    fi

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
    step "Disabling Cloudflare WARP"
    systemctl disable --now warp-connect.timer >/dev/null 2>&1 || true
    systemctl stop warp-connect.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet warp-svc.service; then
        warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    fi
    systemctl disable --now warp-svc.service >/dev/null 2>&1 || true
    ok "warp-connect timer and warp-svc disabled"
    # Critical: the policy rule outranks Proton's main-table default route.
    if ! wait_until 15 "WARP policy rule removed" \
        sh -c "! ip rule show | grep -q 'lookup $WARP_TABLE'"; then
        die "WARP rule table $WARP_TABLE is still present; refusing to stack Proton on top of it. Check: ip rule show && systemctl status warp-svc"
    fi
    if ip link show "$WARP_IF" >/dev/null 2>&1; then
        warn "$WARP_IF interface still exists; WARP may still be tearing down"
    fi

    step "Starting Proton VPN"
    if systemctl enable --now proton.VPN.service >/dev/null 2>&1; then
        ok "proton.VPN.service enabled and started"
    else
        warn "proton.VPN.service did not start; check journalctl -u proton.VPN.service"
    fi
    ensure_lan_multicast_route

    if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = root ]; then
        warn "not invoked via sudo from a desktop session; run 'protonvpn connect' yourself"
    elif [ ! -x "$PROTON_BIN" ]; then
        warn "$PROTON_BIN not found; install proton-vpn-cli"
    else
        info "connecting as $SUDO_USER (credentials come from that user's keyring)"
        if as_invoker "$PROTON_BIN" connect "$@"; then
            ok "protonvpn connect returned"
        else
            warn "protonvpn connect failed; if this is the first run, do 'protonvpn signin' as $SUDO_USER"
        fi
    fi

    step "Verifying"
    if wait_until 25 "$PROTON_IF up" proton_connected; then
        ip -brief addr show "$PROTON_IF" 2>/dev/null | sed 's/^/   /'
        ip route show default | sed 's/^/   /'
    else
        warn "no route via $PROTON_IF; the tunnel is not established"
    fi
    trace
}

# ---------------------------------------------------------------------------
# mode: none
# ---------------------------------------------------------------------------
use_none() {
    step "Disabling Cloudflare WARP"
    systemctl disable --now warp-connect.timer >/dev/null 2>&1 || true
    systemctl stop warp-connect.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet warp-svc.service; then
        warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    fi
    systemctl disable --now warp-svc.service >/dev/null 2>&1 || true
    wait_until 15 "WARP policy rule removed" \
        sh -c "! ip rule show | grep -q 'lookup $WARP_TABLE'" || true

    step "Disabling Proton VPN"
    if ! unit_exists proton.VPN.service; then
        info "proton-vpn-cli is not installed"
    else
        systemctl disable --now proton-vpn-kill-switch-boot.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet proton.VPN.service; then
            as_invoker "$PROTON_BIN" disconnect >/dev/null 2>&1 || true
        fi
        systemctl disable --now proton.VPN.service >/dev/null 2>&1 || true
        ok "proton daemon stopped and disabled"
    fi
    if ip link show "$PROTON_IF" >/dev/null 2>&1; then
        wait_until 10 "$PROTON_IF removed" \
            sh -c "! ip link show $PROTON_IF >/dev/null 2>&1" || true
    fi

    step "Verifying (fail-open, direct via the ISP)"
    ip route show default | sed 's/^/   /'
    trace
}

# ---------------------------------------------------------------------------
# shared output
# ---------------------------------------------------------------------------
trace() {
    if command -v curl >/dev/null; then
        local out
        out="$(curl -s -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
            grep -E '^(ip|loc|warp)=' | tr '\n' ' ')"
        [ -n "$out" ] && info "egress: $out"
        local org
        org="$(curl -s -m 10 https://ipinfo.io/json 2>/dev/null |
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

    echo "interfaces and routes"
    ip -brief addr show 2>/dev/null | grep -E "^($WARP_IF|$PROTON_IF|wlan[0-9]|enp[0-9])" | sed 's/^/   /'
    ip rule show 2>/dev/null | grep "lookup $WARP_TABLE" | sed 's/^/   /' || echo "   no WARP policy rule"
    ip route show default | sed 's/^/   /'

    if systemctl is-active --quiet warp-svc.service; then
        echo "cloudflare warp"
        timeout 5 warp-cli --accept-tos status 2>/dev/null | head -2 | sed 's/^/   /'
    fi

    echo "proton vpn"
    if [ -x "$PROTON_BIN" ]; then
        timeout 10 "$PROTON_BIN" status 2>/dev/null | grep -v -i eventlet |
            grep -v 'monkey_patched' | tail -2 | sed 's/^/   /'
    else
        echo "   protonvpn not installed"
    fi

    echo "networkmanager"
    nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | sed 's/^/   /'

    trace
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
mode="${1:-status}"
[ $# -gt 0 ] && shift

case "$mode" in
    warp|proton|none|status) ;;
    -h|--help|help)
        sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) die "unknown mode '$mode' (use: warp | proton | none | status)" ;;
esac

if [ "$mode" != status ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "run with sudo: sudo $0 $mode"
fi

case "$mode" in
    warp)   use_warp ;;
    proton) use_proton "$@" ;;
    none)   use_none ;;
    status) show_status ;;
esac
