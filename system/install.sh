#!/usr/bin/env bash
# Install / refresh the networking setup for davarch.
#
#   sudo ./install.sh
#
# Idempotent: safe to re-run after editing the files in this directory.
# Everything is backed up with a .bak.YYYYmmdd-HHMMSS suffix first.
#
# Sources of truth for this script live in the dotfiles repo:
#   /home/daviddeadly/dotfiles/system
# Documentation:
#   /home/daviddeadly/dotfiles/docs/networking.md
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
NM_CONF=/etc/NetworkManager/NetworkManager.conf
UNBOUND_CONF=/etc/unbound/unbound.conf
UNBOUND_DROPIN_INCLUDE='include-toplevel: "/etc/unbound/conf.d/*.conf"'

step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[33mwarn\033[0m %s\n' "$*"; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "error: run this with sudo (it installs system units and firewall rules)" >&2
    exit 1
fi

backup() {
    [ -e "$1" ] || return 0
    cp -a "$1" "$1.bak.$STAMP"
    echo "   backup: $1.bak.$STAMP"
}

# ---------------------------------------------------------------------------
step "0. Preconditions"
# ---------------------------------------------------------------------------
[ "$(ps -p 1 -o comm=)" = "systemd" ] || { echo "systemd required" >&2; exit 1; }
command -v warp-cli >/dev/null || { echo "warp-cli not found" >&2; exit 1; }
command -v unbound-checkconf >/dev/null || { echo "unbound not found" >&2; exit 1; }
command -v nft >/dev/null || { echo "nftables not found" >&2; exit 1; }
grep -qE '^[[:space:]]*dns=none' "$NM_CONF" \
    || warn "NetworkManager is not dns=none; it may overwrite /etc/resolv.conf"
ok "systemd, warp-cli, unbound, nft present"

# ---------------------------------------------------------------------------
step "1. Cloudflare WARP: boot ordering and reconnection"
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/systemd/system/warp-svc.service.d
install -m 0644 "$SRC/etc/systemd/system/warp-svc.service.d/10-network-order.conf" \
    /etc/systemd/system/warp-svc.service.d/10-network-order.conf
install -m 0755 "$SRC/usr/local/bin/warp-ensure-connected" \
    /usr/local/bin/warp-ensure-connected
install -m 0644 "$SRC/etc/systemd/system/warp-connect.service" \
    /etc/systemd/system/warp-connect.service
install -m 0644 "$SRC/etc/systemd/system/warp-connect.timer" \
    /etc/systemd/system/warp-connect.timer

systemctl daemon-reload
systemctl restart warp-svc.service
systemctl enable --now warp-connect.timer >/dev/null
systemctl start warp-connect.service || true
ok "warp-svc ordered after NetworkManager-wait-online.service"
ok "warp-connect.timer enabled (60s re-assert)"

# ---------------------------------------------------------------------------
step "2. Unbound: drop-in include, DoT primary, plaintext fallback"
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/unbound/conf.d

if grep -qF "$UNBOUND_DROPIN_INCLUDE" "$UNBOUND_CONF"; then
    ok "include-toplevel already present in $UNBOUND_CONF"
else
    backup "$UNBOUND_CONF"
    # Comment out the legacy inline forward-zone (from the old config) so it
    # cannot clash with the drop-ins, then append the include directive.
    awk '
        /^forward-zone:[ \t]*$/ { inzone = 1 }
        inzone && /^[ \t]*$/    { inzone = 0; print; next }
        inzone                  { print "# (disabled by dotfiles/system) " $0; next }
        { print }
    ' "$UNBOUND_CONF" > "$UNBOUND_CONF.new"
    {
        printf '\n# --- dotfiles/system: load drop-in zones ---\n'
        printf '%s\n' "$UNBOUND_DROPIN_INCLUDE"
    } >> "$UNBOUND_CONF.new"
    mv "$UNBOUND_CONF.new" "$UNBOUND_CONF"
    ok "legacy forward-zone commented out, include added"
fi

install -m 0644 "$SRC/etc/unbound/conf.d/10-forward-dot.conf" \
    /etc/unbound/conf.d/10-forward-dot.conf
install -m 0644 "$SRC/etc/unbound/conf.d/20-forward-plain.conf.disabled" \
    /etc/unbound/conf.d/20-forward-plain.conf.disabled
rm -f /etc/unbound/conf.d/20-forward-plain.conf

install -m 0755 "$SRC/usr/local/sbin/unbound-dns-fallback" \
    /usr/local/sbin/unbound-dns-fallback
install -m 0644 "$SRC/etc/systemd/system/unbound-dns-fallback.service" \
    /etc/systemd/system/unbound-dns-fallback.service
install -m 0644 "$SRC/etc/systemd/system/unbound-dns-fallback.timer" \
    /etc/systemd/system/unbound-dns-fallback.timer

if ! unbound-checkconf >/dev/null; then
    echo "error: unbound-checkconf rejected the new configuration" >&2
    unbound-checkconf || true
    if [ -n "${STAMP:-}" ] && [ -e "$UNBOUND_CONF.bak.$STAMP" ]; then
        cp -a "$UNBOUND_CONF.bak.$STAMP" "$UNBOUND_CONF"
        echo "   restored $UNBOUND_CONF from backup" >&2
    fi
    exit 1
fi
ok "unbound-checkconf passed"

systemctl daemon-reload
systemctl reload-or-restart unbound
systemctl enable --now unbound-dns-fallback.timer >/dev/null
ok "unbound reloaded; DoT primary with plaintext fallback timer (30s)"

# ---------------------------------------------------------------------------
step "3. nftables: default-deny inbound, LAN-only services"
# ---------------------------------------------------------------------------
# Validate before touching the live config.
if ! nft -c -f "$SRC/etc/nftables.conf"; then
    echo "error: nftables config failed validation, nothing changed" >&2
    exit 1
fi
ok "nft -c passed"

backup /etc/nftables.conf
install -m 0644 "$SRC/etc/nftables.conf" /etc/nftables.conf
systemctl enable nftables.service >/dev/null
systemctl restart nftables.service
ok "nftables.service enabled and applied"

# ---------------------------------------------------------------------------
# step "4. VPN switcher"
# ---------------------------------------------------------------------------
install -m 0755 "$SRC/switch-vpn.sh" /usr/local/sbin/switch-vpn
ok "installed /usr/local/sbin/switch-vpn (warp | proton | none | status)"
command -v protonvpn >/dev/null \
    || warn "protonvpn not installed; 'sudo switch-vpn proton' will not work yet"

# ---------------------------------------------------------------------------
step "5. Verification"
# ---------------------------------------------------------------------------
sleep 2
echo "-- WARP --"
warp-cli --accept-tos status 2>/dev/null | head -2 || warn "warp-cli status failed"
if ip rule 2>/dev/null | grep -q 'lookup 65743'; then
    ok "policy routing rule for the WARP table is present"
else
    warn "WARP policy rule not present yet (timer will retry within 60s)"
fi

echo "-- egress --"
if command -v curl >/dev/null; then
    curl -s -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | grep -E '^(ip|loc|warp)=' || warn "trace request failed"
fi

echo "-- dns --"
if command -v dig >/dev/null; then
    dig +short +time=3 +tries=1 @127.0.0.1 example.com | head -2 \
        || warn "local resolver did not answer"
fi

echo "-- firewall (input policy) --"
nft list chain inet filter input 2>/dev/null | sed -n '1,6p' || true

echo "-- listeners still open on all interfaces --"
ss -lntu 2>/dev/null | awk 'NR==1 || /0\.0\.0\.0:|\*:/' | head -12

step "Done"
cat <<EOF
Rollback everything:
    sudo $SRC/rollback.sh

Useful checks:
    switch-vpn status
    warp-cli status
    ip rule; ip route show table 65743 | head
    resolvectl status 2>/dev/null || cat /etc/resolv.conf
    dig +short @127.0.0.1 example.com
    journalctl -t unbound-fallback -n 20
    sudo nft list ruleset
EOF
