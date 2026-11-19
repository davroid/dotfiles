#!/usr/bin/env bash
# Undo everything installed by install.sh.
#
#   sudo ./rollback.sh
#
# Restores the most recent backups made by install.sh where possible.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNBOUND_CONF=/etc/unbound/unbound.conf

step() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "error: run this with sudo" >&2
    exit 1
fi

step "Stopping and removing timers"
systemctl disable --now warp-connect.timer 2>/dev/null || true
systemctl disable --now unbound-dns-fallback.timer 2>/dev/null || true

step "Removing the VPN switcher"
rm -f /usr/local/sbin/switch-vpn
rm -f /usr/local/bin/vpn-tray

step "Removing WARP drop-in and helper units"
rm -f /etc/systemd/system/warp-svc.service.d/10-network-order.conf
rmdir /etc/systemd/system/warp-svc.service.d 2>/dev/null || true
rm -f /etc/systemd/system/warp-connect.service /etc/systemd/system/warp-connect.timer
rm -f /usr/local/bin/warp-ensure-connected

step "Removing Unbound fallback machinery"
rm -f /etc/systemd/system/unbound-dns-fallback.service
rm -f /etc/systemd/system/unbound-dns-fallback.timer
rm -f /usr/local/sbin/unbound-dns-fallback
rm -f /etc/unbound/conf.d/10-forward-dot.conf
rm -f /etc/unbound/conf.d/20-forward-plain.conf
rm -f /etc/unbound/conf.d/20-forward-plain.conf.disabled
rmdir /etc/unbound/conf.d 2>/dev/null || true

# Restore the newest unbound.conf backup that install.sh made.
ub_latest="$(ls -1t "$UNBOUND_CONF".bak.* 2>/dev/null | head -1 || true)"
if [ -n "$ub_latest" ]; then
    cp -a "$ub_latest" "$UNBOUND_CONF"
    echo "   restored $UNBOUND_CONF from $ub_latest"
else
    # No backup: undo the install.sh edit by hand. Uncomment the legacy
    # forward-zone block and drop the include line, otherwise Unbound would
    # be left with no upstream at all.
    sed -i 's|^# (disabled by dotfiles/system) ||' "$UNBOUND_CONF"
    sed -i '\|^include-toplevel: "/etc/unbound/conf.d/\*\.conf"$|d' "$UNBOUND_CONF"
    echo "   no backup found: uncommented legacy forward-zone, removed include"
fi

step "Restoring nftables.conf"
nft_latest="$(ls -1t /etc/nftables.conf.bak.* 2>/dev/null | head -1 || true)"
if [ -n "$nft_latest" ]; then
    cp -a "$nft_latest" /etc/nftables.conf
    echo "   restored /etc/nftables.conf from $nft_latest"
fi
systemctl disable --now nftables.service 2>/dev/null || true
nft flush ruleset 2>/dev/null || true

step "Reloading services"
systemctl daemon-reload
systemctl restart warp-svc.service 2>/dev/null || true

if [ -n "$ub_latest" ] || [ -e "$UNBOUND_CONF" ]; then
    if unbound-checkconf >/dev/null 2>&1; then
        systemctl reload-or-restart unbound 2>/dev/null || true
        echo "   unbound reloaded"
    else
        echo "   warn: unbound-checkconf still failing; check $UNBOUND_CONF" >&2
    fi
fi

step "Done"
echo "Current state:"
warp-cli --accept-tos status 2>/dev/null | head -2 || true
nft list tables 2>/dev/null || echo "   no nftables tables loaded"
