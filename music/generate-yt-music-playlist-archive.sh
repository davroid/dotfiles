#!/bin/bash

while getopts "p:u:" opt; do
    case $opt in
        u) playlist_url="$OPTARG" ;;
        *) echo "Usage: $0 -u <playlist_url>" >&2; exit 1 ;;
    esac
done

yt-dlp --flat-playlist \
    --download-archive archive.txt \
    --force-write-archive \
    "$playlist_url"
