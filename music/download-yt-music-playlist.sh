#!/bin/bash

while getopts "u:" opt; do
    case $opt in
        u) playlist_url="$OPTARG" ;;
        *) echo "Usage: $0 -u <playlist_url>" >&2; exit 1 ;;
    esac
done

# 1. Quickly fetch the playlist title beforehand without downloading
echo "Fetching playlist metadata..."
playlist_title=$(yt-dlp --print "%(playlist_title)s" --playlist-items 1 "$playlist_url" 2>/dev/null)

if [ -z "$playlist_title" ]; then
    echo "Error: Could not retrieve playlist title. Check the URL or your network." >&2
    exit 1
fi

# 2. Create the playlist folder and set the local archive path inside it
mkdir -p "$playlist_title"
archive_file="$playlist_title/archive.txt"

> downloaded_tracks.txt

# Run yt-dlp delta download
yt-dlp -x --audio-format mp3 --audio-quality 0 \
    --embed-thumbnail --embed-metadata \
    --download-archive "$archive_file" \
    --cookies-from-browser brave --break-on-reject \
    --extractor-args "youtube:player_client=android" \
    --output-na-placeholder "Unknown Artist" \
    --print-to-file "%(playlist_index)02d - %(artist,uploader)s - %(title)s.%(ext)s" downloaded_tracks.txt \
    -o "%(playlist_title)s/%(playlist_index)02d - %(artist,uploader)s - %(title)s.%(ext)s" \
    "$playlist_url"
