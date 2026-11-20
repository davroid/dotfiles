#!/usr/bin/env bash
# vpn-tray.sh - Waybar indicator and fuzzel menu for the active VPN.
#
#   vpn-tray              # Waybar JSON: icon, class, tooltip
#   vpn-tray text         # one-line plain-text state (debugging, scripts)
#   vpn-tray menu         # fuzzel menu: WARP / Proton / Tor / no VPN / status
#
# Waybar (dotfiles/.config/waybar/config.jsonc):
#   "custom/vpn": {
#     "exec": "vpn-tray status", "return-type": "json",
#     "interval": 5, "signal": 8, "on-click": "vpn-tray menu"
#   }
#
# The indicator only observes state as your normal user. Changing the VPN runs
# switch-vpn through pkexec (graphical password prompt via hyprpolkitagent) or
# sudo when credentials are already cached, so the switch itself still runs as
# root. Installed as /usr/local/bin/vpn-tray by install.sh.
#
# Classes emitted to Waybar: warp, proton, tor, direct, plus "warn" when a
# tunnel/proxy exists but traffic is not actually routed through it.
set -uo pipefail

SWITCH_BIN="${SWITCH_BIN:-/usr/local/sbin/switch-vpn}"
WARP_IF=CloudflareWARP
WARP_TABLE=65743
BAR_SIGNAL=8
ICON_TOR=$'\uf21b'   # fa-user-secret, present in CaskaydiaCove NF

MODE=direct
DEV=
ROUTED=0
NOTE=

# ---------------------------------------------------------------------------
# state detection (read-only, no root)
# ---------------------------------------------------------------------------

# Any active NetworkManager WireGuard connection, imported profile or the
# Proton CLI's proton0. Prints the device name.
active_wg_dev() {
    nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null |
        awk -F: '$2=="wireguard" && $3!="" {print $3; exit}'
}

# Stored (not necessarily active) Proton WireGuard profile, if any.
stored_wg_profile() {
    local name
    name="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null |
        awk -F: 'tolower($1) ~ /proton/ && $2=="wireguard" {print $1; exit}')"
    if [ -z "$name" ]; then
        name="$(nmcli -t -f NAME,TYPE connection show 2>/dev/null |
            awk -F: '$2=="wireguard" {print $1; exit}')"
    fi
    printf '%s' "$name"
}

detect() {
    MODE=direct DEV= ROUTED=0 NOTE=
    local wg profile

    # Tor is a proxy, not an interface, so it has to be detected from its
    # units. switch-vpn disables tor-transparent in the other modes, so an
    # enabled unit is a reliable signal even before the table exists.
    if systemctl is-enabled --quiet tor-transparent.service 2>/dev/null; then
        MODE=tor
        if systemctl is-active --quiet tor-transparent.service 2>/dev/null &&
            systemctl is-active --quiet tor.service 2>/dev/null; then
            ROUTED=1
        else
            NOTE="Tor routing is enabled but tor-transparent.service or tor.service is not running"
        fi
        return 0
    fi

    if ip link show "$WARP_IF" >/dev/null 2>&1; then
        MODE=warp
        DEV=$WARP_IF
        if ip rule show 2>/dev/null | grep -q "lookup $WARP_TABLE"; then
            ROUTED=1
        else
            NOTE="interface is up but routing rule $WARP_TABLE is missing"
        fi
        return 0
    fi

    # Ask the kernel, not the main table: WireGuard configs imported from
    # Proton use policy routing (fwmark + their own table), so the default
    # route in `main` still points at Wi-Fi even when the tunnel carries all
    # traffic.
    wg="$(active_wg_dev)"
    if [ -n "$wg" ]; then
        MODE=proton
        DEV=$wg
        if ip route get 1.1.1.1 2>/dev/null | grep -q " dev $wg"; then
            ROUTED=1
        else
            NOTE="tunnel is up but traffic is not routed through it"
        fi
        return 0
    fi

    if systemctl is-enabled --quiet warp-connect.timer 2>/dev/null; then
        NOTE="WARP is enabled but not connected (the timer retries every 60s)"
    else
        profile="$(stored_wg_profile)"
        [ -n "$profile" ] &&
            NOTE="Proton profile '$profile' is imported but not connected"
    fi
}

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

print_json() {
    local icon label cls desc tooltip classes
    case "$MODE" in
        warp)   icon="" label="WARP"   cls=warp   desc="Cloudflare WARP";;
        proton) icon="" label="PROTON" cls=proton desc="Proton VPN";;
        tor)    icon="$ICON_TOR" label="TOR" cls=tor desc="Tor (transparent, fail-closed)";;
        *)      icon="" label="DIRECT" cls=direct desc="No VPN (direct via the ISP)";;
    esac

    if [ "$MODE" = direct ] || [ "$ROUTED" -eq 1 ]; then
        classes="\"$cls\""
    else
        classes="\"$cls\",\"warn\""
    fi

    tooltip="$desc"
    [ -n "$DEV" ] && tooltip+=$'\n'"Interface: $DEV"
    if [ "$MODE" = tor ]; then
        if [ "$ROUTED" -eq 1 ]; then
            tooltip+=$'\n'"Traffic: TCP + DNS via Tor, other UDP/IPv6 blocked"
        else
            tooltip+=$'\n'"Traffic: NOT routed through Tor"
        fi
    elif [ "$ROUTED" -eq 1 ]; then
        tooltip+=$'\n'"Traffic: routed through the tunnel"
    else
        tooltip+=$'\n'"Traffic: NOT routed through the tunnel"
    fi
    [ -n "$NOTE" ] && tooltip+=$'\n'"$NOTE"
    tooltip+=$'\n'"Click to switch VPN"

    printf '{"text":"%s","class":[%s],"alt":"%s","tooltip":"%s"}\n' \
        "$(json_escape "$icon $label")" "$classes" "$MODE" \
        "$(json_escape "$tooltip")"
}

text_line() {
    case "$MODE" in
        warp)   printf 'WARP (%s)\n' "$DEV";;
        proton) printf 'PROTON (%s)\n' "$DEV";;
        tor)    printf 'TOR (transparent proxy)\n';;
        *)      printf 'DIRECT (no VPN)\n';;
    esac
    [ "$MODE" = direct ] || [ "$ROUTED" -eq 1 ] ||
        printf 'warning: traffic is not routed through the tunnel\n'
    [ -n "$NOTE" ] && printf 'note: %s\n' "$NOTE"
    return 0
}

# ---------------------------------------------------------------------------
# menu
# ---------------------------------------------------------------------------
notify() {
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a VPN -i network-vpn "$1" "${2:-}" >/dev/null 2>&1 || true
}

refresh_bar() {
    pkill -SIGRTMIN+"$BAR_SIGNAL" -x waybar >/dev/null 2>&1 || true
}

show_status() {
    if command -v foot >/dev/null 2>&1; then
        foot --app-id=vpn-status -T "VPN status" -e bash -c \
            '"$0" status; printf "\nPress Enter to close"; read -r' \
            "$SWITCH_BIN"
    else
        notify "VPN status" "$(text_line)"
    fi
}

# Changing the VPN needs root: reuse cached sudo credentials when present,
# otherwise ask through the desktop polkit agent.
run_switch() {
    local mode=$1
    if sudo -n true 2>/dev/null; then
        sudo "$SWITCH_BIN" "$mode"
        return $?
    fi
    if command -v pkexec >/dev/null 2>&1 &&
        [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
        pkexec "$SWITCH_BIN" "$mode"
        return $?
    fi
    if command -v foot >/dev/null 2>&1; then
        foot --app-id=vpn-switch -T "VPN switch" -e \
            sudo "$SWITCH_BIN" "$mode"
        return $?
    fi
    notify "Cannot switch VPN" "Run manually: sudo $SWITCH_BIN $mode"
    return 1
}

menu() {
    detect

    local m_warp= m_proton= m_tor= m_none= choice want label
    case "$MODE" in
        warp)   m_warp=" (active)";;
        proton) m_proton=" (active)";;
        tor)    m_tor=" (active)";;
        *)      m_none=" (active)";;
    esac

    choice="$(
        printf '%s\n' \
            "  Cloudflare WARP$m_warp" \
            "  Proton VPN$m_proton" \
            "  Tor (transparent)$m_tor" \
            "  No VPN (direct)$m_none" \
            "  Show status in a terminal" |
            fuzzel --dmenu --prompt="VPN  " --lines=5 --width=36 2>/dev/null
    )" || exit 0
    [ -n "$choice" ] || exit 0

    case "$choice" in
        *"Cloudflare WARP"*) want=warp   label="Cloudflare WARP";;
        *"Proton VPN"*)      want=proton label="Proton VPN";;
        *"Tor (transparent)"*) want=tor  label="Tor (transparent)";;
        *"No VPN"*)          want=none   label="no VPN (direct)";;
        *"status"*)          show_status; exit 0;;
        *) exit 0;;
    esac

    if [ "$want" = "$MODE" ]; then
        notify "$label is already active" "Nothing to do."
        exit 0
    fi

    notify "Switching VPN" "→ $label"
    if run_switch "$want"; then
        detect
        if [ "$want" = none ]; then
            if [ "$MODE" = direct ]; then
                notify "VPN off" "Traffic now goes directly via the ISP."
            else
                notify "VPN switch failed" \
                    "Still on $MODE. Check: sudo $SWITCH_BIN status"
            fi
        elif [ "$MODE" = "$want" ]; then
            if [ "$want" = tor ]; then
                notify "Tor routing active" \
                    "TCP and DNS go through Tor; other UDP and external IPv6 are blocked."
            else
                notify "VPN connected: $label" "Interface: $DEV"
            fi
        else
            notify "VPN switch failed" \
                "Expected $want, still on $MODE. Check: sudo $SWITCH_BIN status"
        fi
    else
        notify "VPN switch cancelled" "No changes were made."
    fi
    refresh_bar
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
cmd="${1:-status}"
case "$cmd" in
    status|json) detect; print_json;;
    text)        detect; text_line;;
    menu)        menu;;
    -h|--help|help)
        sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        ;;
    *)
        printf 'usage: vpn-tray [status|text|menu]\n' >&2
        exit 2
        ;;
esac
