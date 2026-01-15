#!/usr/bin/env sh

# Define the variable that holds the last result
LAST=""
SPACE=" "

# Don't stop until the user hits escape or clicks off of fuzzel
while true; do
    # Format number with thousands separators for display
    LAST_DISPLAY="$(echo "$LAST" | sed ':a;s/\([0-9]\)\([0-9]\{3\}\)\([^0-9]\|$\)/\1,\2\3/;ta')"

    # Get user input
    NEXT="$(fuzzel --dmenu --prompt-only="󱖦 $LAST_DISPLAY$SPACE")"

    # Quit if empty
    [ -z "$NEXT" ] && exit 1

    # Copy and exit if y is entered
    [ "$NEXT" = "y" ] && wl-copy "$LAST" && exit 0
    [ "$NEXT" = "Y" ] && wl-copy "$LAST_DISPLAY" && exit 0

    # Pipe the expression into bc, truncate to 2 decimals, and strip trailing zeroes
    LAST="$(printf "%.2f" "$(echo "$LAST$NEXT" | bc -l)" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')"
done
