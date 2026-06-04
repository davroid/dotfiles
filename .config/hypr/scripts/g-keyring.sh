# Start gnome-keyring daemon and set SSH_AUTH_SOCK
eval $(/usr/bin/gnome-keyring-daemon --start --components=ssh)
export SSH_AUTH_SOCK
